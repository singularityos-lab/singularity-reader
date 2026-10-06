#include <stdio.h>
#include <string.h>
#include <gnutls/gnutls.h>
#include <gnutls/x509.h>
#include <gnutls/abstract.h>
#include <gnutls/pkcs12.h>
#include <gnutls/pkcs7.h>
#include <gnutls/pkcs11.h>
#include <gnutls/crypto.h>
#include <gnutls/ocsp.h>

#include "signing.h"

#define SIGNING_ERROR g_quark_from_static_string ("reader-signing-error")

struct _ReaderSignKey {
    gnutls_privkey_t key;
    gnutls_x509_crt_t *certs;
    unsigned int n_certs;
};

struct _ReaderCms {
    ReaderSignKey *key;
    GByteArray *signed_attrs;
    GByteArray *signature;
    GByteArray *token;
};

static const guint8 OID_DATA[] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01 };
static const guint8 OID_SIGNED_DATA[] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02 };
static const guint8 OID_SHA256[] = { 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01 };
static const guint8 OID_CONTENT_TYPE[] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x03 };
static const guint8 OID_MESSAGE_DIGEST[] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x04 };
static const guint8 OID_SIGNING_CERT_V2[] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x10, 0x02, 0x2f };
static const guint8 OID_TIMESTAMP_TOKEN[] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x10, 0x02, 0x0e };
static const guint8 OID_RSA[] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };
static const guint8 OID_ECDSA_SHA256[] = { 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02 };

static void
der_len (GByteArray *out, gsize len)
{
    if (len < 128) {
        guint8 b = (guint8) len;
        g_byte_array_append (out, &b, 1);
        return;
    }
    guint8 tmp[8];
    int n = 0;
    while (len > 0) {
        tmp[n++] = (guint8) (len & 0xff);
        len >>= 8;
    }
    guint8 first = 0x80 | n;
    g_byte_array_append (out, &first, 1);
    for (int i = n - 1; i >= 0; i--)
        g_byte_array_append (out, &tmp[i], 1);
}

static void
der_tlv (GByteArray *out, guint8 tag, const guint8 *data, gsize len)
{
    g_byte_array_append (out, &tag, 1);
    der_len (out, len);
    if (len > 0)
        g_byte_array_append (out, data, len);
}

static void
der_wrap (GByteArray *out, guint8 tag, GByteArray *inner)
{
    der_tlv (out, tag, inner->data, inner->len);
    g_byte_array_unref (inner);
}

static void
der_oid (GByteArray *out, const guint8 *oid, gsize len)
{
    der_tlv (out, 0x06, oid, len);
}

static void
der_int_bytes (GByteArray *out, const guint8 *data, gsize len)
{
    while (len > 1 && data[0] == 0 && !(data[1] & 0x80)) {
        data++;
        len--;
    }
    GByteArray *v = g_byte_array_new ();
    if (len == 0 || (data[0] & 0x80)) {
        guint8 z = 0;
        g_byte_array_append (v, &z, 1);
    }
    if (len > 0)
        g_byte_array_append (v, data, len);
    der_wrap (out, 0x02, v);
}

static void
der_small_int (GByteArray *out, int value)
{
    guint8 b = (guint8) value;
    der_tlv (out, 0x02, &b, 1);
}

static void
der_algorithm (GByteArray *out, const guint8 *oid, gsize len, gboolean null_params)
{
    GByteArray *s = g_byte_array_new ();
    der_oid (s, oid, len);
    if (null_params)
        der_tlv (s, 0x05, NULL, 0);
    der_wrap (out, 0x30, s);
}

static gboolean
der_read (const guint8 *d, gsize total, gsize pos, guint8 *tag, gsize *header, gsize *len)
{
    if (pos + 2 > total)
        return FALSE;
    *tag = d[pos];
    guint8 l = d[pos + 1];
    if (l < 128) {
        *header = 2;
        *len = l;
    } else {
        int n = l & 0x7f;
        if (n == 0 || n > 4 || pos + 2 + n > total)
            return FALSE;
        gsize v = 0;
        for (int i = 0; i < n; i++)
            v = (v << 8) | d[pos + 2 + i];
        *header = 2 + n;
        *len = v;
    }
    return pos + *header + *len <= total;
}

static void
set_error (GError **error, const char *what, int code)
{
    g_set_error (error, SIGNING_ERROR, 1, "%s: %s", what, code != 0 ? gnutls_strerror (code) : "failed");
}

static ReaderSignKey *
key_from_parts (gnutls_privkey_t key, gnutls_x509_crt_t *certs, unsigned int n)
{
    ReaderSignKey *k = g_new0 (ReaderSignKey, 1);
    k->key = key;
    k->certs = certs;
    k->n_certs = n;
    return k;
}

ReaderSignKey *
reader_sign_key_pkcs12 (const char *path, const char *password, GError **error)
{
    gnutls_global_init ();
    gchar *contents = NULL;
    gsize length = 0;
    if (!g_file_get_contents (path, &contents, &length, error))
        return NULL;
    gnutls_datum_t datum = { (unsigned char *) contents, (unsigned int) length };
    gnutls_pkcs12_t p12;
    gnutls_pkcs12_init (&p12);
    int r = gnutls_pkcs12_import (p12, &datum, GNUTLS_X509_FMT_DER, 0);
    if (r < 0)
        r = gnutls_pkcs12_import (p12, &datum, GNUTLS_X509_FMT_PEM, 0);
    if (r < 0) {
        gnutls_pkcs12_deinit (p12);
        g_free (contents);
        set_error (error, "The certificate file could not be read", r);
        return NULL;
    }
    gnutls_x509_privkey_t xkey = NULL;
    gnutls_x509_crt_t *chain = NULL;
    unsigned int chain_len = 0;
    gnutls_x509_crt_t *extra = NULL;
    unsigned int extra_len = 0;
    r = gnutls_pkcs12_simple_parse (p12, password, &xkey, &chain, &chain_len, &extra, &extra_len, NULL, 0);
    gnutls_pkcs12_deinit (p12);
    g_free (contents);
    if (r < 0) {
        set_error (error, r == GNUTLS_E_MAC_VERIFY_FAILED || r == GNUTLS_E_DECRYPTION_FAILED ? "The password is not correct" : "The certificate file could not be opened", r);
        return NULL;
    }
    gnutls_privkey_t key;
    gnutls_privkey_init (&key);
    r = gnutls_privkey_import_x509 (key, xkey, GNUTLS_PRIVKEY_IMPORT_AUTO_RELEASE);
    if (r < 0) {
        gnutls_privkey_deinit (key);
        set_error (error, "The private key could not be used", r);
        return NULL;
    }
    unsigned int n = chain_len + extra_len;
    gnutls_x509_crt_t *all = g_new0 (gnutls_x509_crt_t, n > 0 ? n : 1);
    for (unsigned int i = 0; i < chain_len; i++)
        all[i] = chain[i];
    for (unsigned int i = 0; i < extra_len; i++)
        all[chain_len + i] = extra[i];
    gnutls_free (chain);
    gnutls_free (extra);
    if (n == 0) {
        gnutls_privkey_deinit (key);
        g_free (all);
        set_error (error, "The file contains no certificate", 0);
        return NULL;
    }
    return key_from_parts (key, all, n);
}

static char *pin_value = NULL;

static int
pin_callback (void *userdata, int attempt, const char *token_url, const char *token_label, unsigned int flags, char *pin, size_t pin_max)
{
    if (pin_value == NULL || attempt > 0)
        return -1;
    g_strlcpy (pin, pin_value, pin_max);
    return 0;
}

ReaderSignKey *
reader_sign_key_pkcs11 (const char *url, const char *pin, GError **error)
{
    gnutls_global_init ();
    g_free (pin_value);
    pin_value = g_strdup (pin);
    gnutls_pkcs11_set_pin_function (pin_callback, NULL);
    gnutls_privkey_t key;
    gnutls_privkey_init (&key);
    int r = gnutls_privkey_import_url (key, url, 0);
    if (r < 0) {
        gnutls_privkey_deinit (key);
        set_error (error, "The key on the card could not be opened", r);
        return NULL;
    }
    gnutls_x509_crt_t crt;
    gnutls_x509_crt_init (&crt);
    char *cert_url = g_strdup (url);
    char *type = strstr (cert_url, "type=private");
    if (type != NULL)
        memcpy (type, "type=cert   ", 12);
    GString *clean = g_string_new (NULL);
    for (char *p = cert_url; *p; p++)
        if (*p != ' ')
            g_string_append_c (clean, *p);
    g_free (cert_url);
    r = gnutls_x509_crt_import_url (crt, clean->str, 0);
    g_string_free (clean, TRUE);
    if (r < 0) {
        gnutls_x509_crt_deinit (crt);
        gnutls_privkey_deinit (key);
        set_error (error, "The certificate on the card could not be read", r);
        return NULL;
    }
    gnutls_x509_crt_t *all = g_new0 (gnutls_x509_crt_t, 1);
    all[0] = crt;
    return key_from_parts (key, all, 1);
}

void
reader_sign_key_free (ReaderSignKey *key)
{
    if (key == NULL)
        return;
    for (unsigned int i = 0; i < key->n_certs; i++)
        gnutls_x509_crt_deinit (key->certs[i]);
    g_free (key->certs);
    gnutls_privkey_deinit (key->key);
    g_free (key);
}

static char *
common_name (gnutls_x509_crt_t crt, gboolean issuer)
{
    char buf[512];
    size_t size = sizeof (buf);
    int r = issuer ? gnutls_x509_crt_get_issuer_dn_by_oid (crt, GNUTLS_OID_X520_COMMON_NAME, 0, 0, buf, &size)
                   : gnutls_x509_crt_get_dn_by_oid (crt, GNUTLS_OID_X520_COMMON_NAME, 0, 0, buf, &size);
    if (r >= 0)
        return g_strndup (buf, size);
    gnutls_datum_t dn = { NULL, 0 };
    r = issuer ? gnutls_x509_crt_get_issuer_dn3 (crt, &dn, 0) : gnutls_x509_crt_get_dn3 (crt, &dn, 0);
    if (r < 0)
        return g_strdup ("");
    char *s = g_strndup ((const char *) dn.data, dn.size);
    gnutls_free (dn.data);
    return s;
}

char *
reader_sign_key_subject (ReaderSignKey *key)
{
    return common_name (key->certs[0], FALSE);
}

static GByteArray *
build_signed_attrs (ReaderSignKey *key, const guint8 *digest, gsize digest_len)
{
    GPtrArray *attrs = g_ptr_array_new ();
    GByteArray *a1 = g_byte_array_new ();
    {
        GByteArray *s = g_byte_array_new ();
        der_oid (s, OID_CONTENT_TYPE, sizeof (OID_CONTENT_TYPE));
        GByteArray *set = g_byte_array_new ();
        der_oid (set, OID_DATA, sizeof (OID_DATA));
        der_wrap (s, 0x31, set);
        der_wrap (a1, 0x30, s);
    }
    g_ptr_array_add (attrs, a1);
    GByteArray *a2 = g_byte_array_new ();
    {
        GByteArray *s = g_byte_array_new ();
        der_oid (s, OID_MESSAGE_DIGEST, sizeof (OID_MESSAGE_DIGEST));
        GByteArray *set = g_byte_array_new ();
        der_tlv (set, 0x04, digest, digest_len);
        der_wrap (s, 0x31, set);
        der_wrap (a2, 0x30, s);
    }
    g_ptr_array_add (attrs, a2);
    GByteArray *a3 = g_byte_array_new ();
    {
        gnutls_datum_t der = { NULL, 0 };
        gnutls_x509_crt_export2 (key->certs[0], GNUTLS_X509_FMT_DER, &der);
        guint8 hash[32];
        gnutls_hash_fast (GNUTLS_DIG_SHA256, der.data, der.size, hash);
        gnutls_free (der.data);
        gnutls_datum_t issuer = { NULL, 0 };
        gnutls_x509_crt_get_raw_issuer_dn (key->certs[0], &issuer);
        guint8 serial[64];
        size_t serial_len = sizeof (serial);
        gnutls_x509_crt_get_serial (key->certs[0], serial, &serial_len);
        GByteArray *certid = g_byte_array_new ();
        der_tlv (certid, 0x04, hash, 32);
        GByteArray *issuer_serial = g_byte_array_new ();
        GByteArray *names = g_byte_array_new ();
        der_tlv (names, 0xa4, issuer.data, issuer.size);
        der_wrap (issuer_serial, 0x30, names);
        der_int_bytes (issuer_serial, serial, serial_len);
        der_wrap (certid, 0x30, issuer_serial);
        gnutls_free (issuer.data);
        GByteArray *certid_seq = g_byte_array_new ();
        der_wrap (certid_seq, 0x30, certid);
        GByteArray *certs = g_byte_array_new ();
        der_wrap (certs, 0x30, certid_seq);
        GByteArray *signing_cert = g_byte_array_new ();
        der_wrap (signing_cert, 0x30, certs);
        GByteArray *s = g_byte_array_new ();
        der_oid (s, OID_SIGNING_CERT_V2, sizeof (OID_SIGNING_CERT_V2));
        der_wrap (s, 0x31, signing_cert);
        der_wrap (a3, 0x30, s);
    }
    g_ptr_array_add (attrs, a3);
    for (guint i = 0; i < attrs->len; i++) {
        for (guint j = i + 1; j < attrs->len; j++) {
            GByteArray *x = attrs->pdata[i], *y = attrs->pdata[j];
            gsize m = MIN (x->len, y->len);
            int c = memcmp (x->data, y->data, m);
            if (c > 0 || (c == 0 && x->len > y->len)) {
                attrs->pdata[i] = y;
                attrs->pdata[j] = x;
            }
        }
    }
    GByteArray *content = g_byte_array_new ();
    for (guint i = 0; i < attrs->len; i++) {
        GByteArray *x = attrs->pdata[i];
        g_byte_array_append (content, x->data, x->len);
        g_byte_array_unref (x);
    }
    g_ptr_array_free (attrs, TRUE);
    GByteArray *set = g_byte_array_new ();
    der_wrap (set, 0x31, content);
    return set;
}

ReaderCms *
reader_cms_new (ReaderSignKey *key, const guint8 *data, gsize length, GError **error)
{
    guint8 digest[32];
    gnutls_hash_fast (GNUTLS_DIG_SHA256, data, length, digest);
    GByteArray *attrs = build_signed_attrs (key, digest, 32);
    gnutls_datum_t tbs = { attrs->data, attrs->len };
    gnutls_datum_t sig = { NULL, 0 };
    int r = gnutls_privkey_sign_data (key->key, GNUTLS_DIG_SHA256, 0, &tbs, &sig);
    if (r < 0) {
        g_byte_array_unref (attrs);
        set_error (error, "The document could not be signed", r);
        return NULL;
    }
    ReaderCms *cms = g_new0 (ReaderCms, 1);
    cms->key = key;
    cms->signed_attrs = attrs;
    cms->signature = g_byte_array_new ();
    g_byte_array_append (cms->signature, sig.data, sig.size);
    gnutls_free (sig.data);
    return cms;
}

void
reader_cms_free (ReaderCms *cms)
{
    if (cms == NULL)
        return;
    g_byte_array_unref (cms->signed_attrs);
    g_byte_array_unref (cms->signature);
    if (cms->token != NULL)
        g_byte_array_unref (cms->token);
    g_free (cms);
}

GBytes *
reader_cms_signature (ReaderCms *cms)
{
    return g_bytes_new (cms->signature->data, cms->signature->len);
}

GBytes *
reader_timestamp_request_for_data (const guint8 *data, gsize length)
{
    guint8 hash[32];
    gnutls_hash_fast (GNUTLS_DIG_SHA256, data, length, hash);
    GByteArray *req = g_byte_array_new ();
    der_small_int (req, 1);
    GByteArray *imprint = g_byte_array_new ();
    der_algorithm (imprint, OID_SHA256, sizeof (OID_SHA256), TRUE);
    der_tlv (imprint, 0x04, hash, 32);
    der_wrap (req, 0x30, imprint);
    guint8 nonce[8];
    gnutls_rnd (GNUTLS_RND_NONCE, nonce, sizeof (nonce));
    nonce[0] &= 0x7f;
    nonce[0] |= 0x01;
    der_int_bytes (req, nonce, sizeof (nonce));
    guint8 yes = 0xff;
    der_tlv (req, 0x01, &yes, 1);
    GByteArray *out = g_byte_array_new ();
    der_wrap (out, 0x30, req);
    return g_byte_array_free_to_bytes (out);
}

GBytes *
reader_cms_timestamp_request (ReaderCms *cms)
{
    return reader_timestamp_request_for_data (cms->signature->data, cms->signature->len);
}

GBytes *
reader_timestamp_token_from_response (const guint8 *data, gsize length, GError **error)
{
    guint8 tag;
    gsize header, len;
    if (!der_read (data, length, 0, &tag, &header, &len) || tag != 0x30) {
        g_set_error (error, SIGNING_ERROR, 2, "The timestamp response is not valid");
        return NULL;
    }
    gsize pos = header;
    gsize end = header + len;
    guint8 st_tag;
    gsize st_header, st_len;
    if (!der_read (data, length, pos, &st_tag, &st_header, &st_len) || st_tag != 0x30) {
        g_set_error (error, SIGNING_ERROR, 2, "The timestamp response has no status");
        return NULL;
    }
    guint8 it;
    gsize ih, il;
    if (!der_read (data, length, pos + st_header, &it, &ih, &il) || it != 0x02 || il < 1) {
        g_set_error (error, SIGNING_ERROR, 2, "The timestamp response has no status");
        return NULL;
    }
    int status = data[pos + st_header + ih + il - 1];
    if (status > 1) {
        g_set_error (error, SIGNING_ERROR, 3, "The timestamp service refused the request (status %d)", status);
        return NULL;
    }
    pos += st_header + st_len;
    guint8 tt;
    gsize th, tl;
    if (pos >= end || !der_read (data, length, pos, &tt, &th, &tl) || tt != 0x30) {
        g_set_error (error, SIGNING_ERROR, 2, "The timestamp response has no token");
        return NULL;
    }
    return g_bytes_new (data + pos, th + tl);
}

gboolean
reader_cms_add_timestamp_response (ReaderCms *cms, const guint8 *data, gsize length, GError **error)
{
    GBytes *token = reader_timestamp_token_from_response (data, length, error);
    if (token == NULL)
        return FALSE;
    gsize size;
    const guint8 *t = g_bytes_get_data (token, &size);
    if (cms->token != NULL)
        g_byte_array_unref (cms->token);
    cms->token = g_byte_array_new ();
    g_byte_array_append (cms->token, t, size);
    g_bytes_unref (token);
    return TRUE;
}

GBytes *
reader_cms_encode (ReaderCms *cms)
{
    ReaderSignKey *key = cms->key;
    GByteArray *signer = g_byte_array_new ();
    der_small_int (signer, 1);
    {
        gnutls_datum_t issuer = { NULL, 0 };
        gnutls_x509_crt_get_raw_issuer_dn (key->certs[0], &issuer);
        guint8 serial[64];
        size_t serial_len = sizeof (serial);
        gnutls_x509_crt_get_serial (key->certs[0], serial, &serial_len);
        GByteArray *ias = g_byte_array_new ();
        g_byte_array_append (ias, issuer.data, issuer.size);
        der_int_bytes (ias, serial, serial_len);
        gnutls_free (issuer.data);
        der_wrap (signer, 0x30, ias);
    }
    der_algorithm (signer, OID_SHA256, sizeof (OID_SHA256), TRUE);
    {
        guint8 tag;
        gsize header, len;
        der_read (cms->signed_attrs->data, cms->signed_attrs->len, 0, &tag, &header, &len);
        der_tlv (signer, 0xa0, cms->signed_attrs->data + header, len);
    }
    int pk = gnutls_privkey_get_pk_algorithm (key->key, NULL);
    if (pk == GNUTLS_PK_EC)
        der_algorithm (signer, OID_ECDSA_SHA256, sizeof (OID_ECDSA_SHA256), FALSE);
    else
        der_algorithm (signer, OID_RSA, sizeof (OID_RSA), TRUE);
    der_tlv (signer, 0x04, cms->signature->data, cms->signature->len);
    if (cms->token != NULL) {
        GByteArray *attr = g_byte_array_new ();
        der_oid (attr, OID_TIMESTAMP_TOKEN, sizeof (OID_TIMESTAMP_TOKEN));
        GByteArray *set = g_byte_array_new ();
        g_byte_array_append (set, cms->token->data, cms->token->len);
        der_wrap (attr, 0x31, set);
        GByteArray *attr_seq = g_byte_array_new ();
        der_wrap (attr_seq, 0x30, attr);
        der_wrap (signer, 0xa1, attr_seq);
    }
    GByteArray *sd = g_byte_array_new ();
    der_small_int (sd, 1);
    GByteArray *algs = g_byte_array_new ();
    der_algorithm (algs, OID_SHA256, sizeof (OID_SHA256), TRUE);
    der_wrap (sd, 0x31, algs);
    GByteArray *eci = g_byte_array_new ();
    der_oid (eci, OID_DATA, sizeof (OID_DATA));
    der_wrap (sd, 0x30, eci);
    GByteArray *certs = g_byte_array_new ();
    for (unsigned int i = 0; i < key->n_certs; i++) {
        gnutls_datum_t der = { NULL, 0 };
        if (gnutls_x509_crt_export2 (key->certs[i], GNUTLS_X509_FMT_DER, &der) >= 0) {
            g_byte_array_append (certs, der.data, der.size);
            gnutls_free (der.data);
        }
    }
    der_wrap (sd, 0xa0, certs);
    GByteArray *signers = g_byte_array_new ();
    der_wrap (signers, 0x30, signer);
    der_wrap (sd, 0x31, signers);
    GByteArray *sd_seq = g_byte_array_new ();
    der_wrap (sd_seq, 0x30, sd);
    GByteArray *ci = g_byte_array_new ();
    der_oid (ci, OID_SIGNED_DATA, sizeof (OID_SIGNED_DATA));
    der_wrap (ci, 0xa0, sd_seq);
    GByteArray *out = g_byte_array_new ();
    der_wrap (out, 0x30, ci);
    return g_byte_array_free_to_bytes (out);
}

static gint64
parse_generalized_time (const guint8 *p, gsize len)
{
    if (len < 14)
        return 0;
    char buf[32] = { 0 };
    memcpy (buf, p, MIN (len, sizeof (buf) - 1));
    int y, mo, d, h, mi, s;
    if (sscanf (buf, "%4d%2d%2d%2d%2d%2d", &y, &mo, &d, &h, &mi, &s) != 6)
        return 0;
    GDateTime *dt = g_date_time_new_utc (y, mo, d, h, mi, s);
    if (dt == NULL)
        return 0;
    gint64 t = g_date_time_to_unix (dt);
    g_date_time_unref (dt);
    return t;
}

static gint64
find_gen_time (const guint8 *d, gsize len)
{
    for (gsize i = 0; i + 16 < len; i++) {
        if (d[i] == 0x18 && d[i + 1] >= 15 && d[i + 1] <= 24 && i + 2 + d[i + 1] <= len) {
            gboolean digits = TRUE;
            for (int k = 0; k < 14; k++)
                if (d[i + 2 + k] < '0' || d[i + 2 + k] > '9')
                    digits = FALSE;
            if (digits)
                return parse_generalized_time (d + i + 2, d[i + 1]);
        }
    }
    return 0;
}

static gboolean
contains_bytes (const guint8 *hay, gsize hay_len, const guint8 *needle, gsize len)
{
    if (len == 0 || hay_len < len)
        return FALSE;
    for (gsize i = 0; i + len <= hay_len; i++)
        if (memcmp (hay + i, needle, len) == 0)
            return TRUE;
    return FALSE;
}

static gnutls_x509_trust_list_t
make_trust (const char *trust_dir)
{
    gnutls_x509_trust_list_t tl;
    gnutls_x509_trust_list_init (&tl, 0);
    gnutls_x509_trust_list_add_system_trust (tl, 0, 0);
    if (trust_dir != NULL && g_file_test (trust_dir, G_FILE_TEST_IS_DIR))
        gnutls_x509_trust_list_add_trust_dir (tl, trust_dir, NULL, GNUTLS_X509_FMT_PEM, 0, 0);
    return tl;
}

static gnutls_x509_crt_t
find_signer (gnutls_pkcs7_t p7, gnutls_pkcs7_signature_info_st *info)
{
    int count = gnutls_pkcs7_get_crt_count (p7);
    for (int i = 0; i < count; i++) {
        gnutls_datum_t raw = { NULL, 0 };
        if (gnutls_pkcs7_get_crt_raw2 (p7, i, &raw) < 0)
            continue;
        gnutls_x509_crt_t crt;
        gnutls_x509_crt_init (&crt);
        int r = gnutls_x509_crt_import (crt, &raw, GNUTLS_X509_FMT_DER);
        gnutls_free (raw.data);
        if (r < 0) {
            gnutls_x509_crt_deinit (crt);
            continue;
        }
        guint8 serial[64];
        size_t serial_len = sizeof (serial);
        gnutls_x509_crt_get_serial (crt, serial, &serial_len);
        gnutls_datum_t issuer = { NULL, 0 };
        gnutls_x509_crt_get_raw_issuer_dn (crt, &issuer);
        gboolean match = TRUE;
        if (info->signer_serial.size > 0) {
            const guint8 *a = info->signer_serial.data;
            gsize al = info->signer_serial.size;
            const guint8 *b = serial;
            gsize bl = serial_len;
            while (al > 1 && a[0] == 0) { a++; al--; }
            while (bl > 1 && b[0] == 0) { b++; bl--; }
            match = al == bl && memcmp (a, b, al) == 0;
        }
        if (match && info->issuer_dn.size > 0)
            match = issuer.size == info->issuer_dn.size && memcmp (issuer.data, info->issuer_dn.data, issuer.size) == 0;
        gnutls_free (issuer.data);
        if (match)
            return crt;
        gnutls_x509_crt_deinit (crt);
    }
    return NULL;
}

ReaderVerifyResult *
reader_cms_verify (const guint8 *cms, gsize cms_length, const guint8 *data, gsize length, const char *trust_dir, gboolean timestamp_token)
{
    gnutls_global_init ();
    ReaderVerifyResult *res = g_new0 (ReaderVerifyResult, 1);
    res->status = 3;
    gnutls_pkcs7_t p7;
    gnutls_pkcs7_init (&p7);
    gnutls_datum_t in = { (unsigned char *) cms, (unsigned int) cms_length };
    int r = gnutls_pkcs7_import (p7, &in, GNUTLS_X509_FMT_DER);
    if (r < 0) {
        res->message = g_strdup_printf ("The signature data cannot be read: %s", gnutls_strerror (r));
        gnutls_pkcs7_deinit (p7);
        return res;
    }
    gnutls_pkcs7_signature_info_st info;
    memset (&info, 0, sizeof (info));
    r = gnutls_pkcs7_get_signature_info (p7, 0, &info);
    if (r < 0) {
        res->message = g_strdup_printf ("The signature has no signer: %s", gnutls_strerror (r));
        gnutls_pkcs7_deinit (p7);
        return res;
    }
    if (info.signing_time > 0)
        res->signing_time = (gint64) info.signing_time;
    for (unsigned int i = 0;; i++) {
        char *oid = NULL;
        gnutls_datum_t v = { NULL, 0 };
        if (gnutls_pkcs7_get_attr (info.unsigned_attrs, i, &oid, &v, 0) < 0)
            break;
        if (oid != NULL && strcmp (oid, "1.2.840.113549.1.9.16.2.14") == 0) {
            res->timestamped = TRUE;
            res->timestamp_time = find_gen_time (v.data, v.size);
        }
        gnutls_free (v.data);
    }
    gnutls_x509_crt_t signer = find_signer (p7, &info);
    if (signer == NULL) {
        res->status = 2;
        res->message = g_strdup ("The signer certificate is missing");
        gnutls_pkcs7_signature_info_deinit (&info);
        gnutls_pkcs7_deinit (p7);
        return res;
    }
    res->signer = common_name (signer, FALSE);
    gnutls_datum_t dn = { NULL, 0 };
    if (gnutls_x509_crt_get_dn3 (signer, &dn, 0) >= 0) {
        res->signer_dn = g_strndup ((const char *) dn.data, dn.size);
        gnutls_free (dn.data);
    }
    res->issuer = common_name (signer, TRUE);
    guint8 serial[64];
    size_t serial_len = sizeof (serial);
    gnutls_x509_crt_get_serial (signer, serial, &serial_len);
    GString *hex = g_string_new (NULL);
    for (size_t i = 0; i < serial_len; i++)
        g_string_append_printf (hex, "%s%02X", i > 0 ? ":" : "", serial[i]);
    res->serial = g_string_free (hex, FALSE);
    res->not_before = (gint64) gnutls_x509_crt_get_activation_time (signer);
    res->not_after = (gint64) gnutls_x509_crt_get_expiration_time (signer);
    gnutls_datum_t aia = { NULL, 0 };
    for (int seq = 0; seq < 8; seq++) {
        unsigned int critical;
        if (gnutls_x509_crt_get_authority_info_access (signer, seq, GNUTLS_IA_OCSP_URI, &aia, &critical) >= 0) {
            res->ocsp_url = g_strndup ((const char *) aia.data, aia.size);
            gnutls_free (aia.data);
            break;
        }
    }
    gnutls_datum_t content = { (unsigned char *) data, (unsigned int) length };
    if (timestamp_token) {
        r = gnutls_pkcs7_verify_direct (p7, signer, 0, NULL, 0);
        guint8 hash[32];
        gnutls_hash_fast (GNUTLS_DIG_SHA256, data, length, hash);
        gnutls_datum_t embedded = { NULL, 0 };
        gboolean imprint = FALSE;
        if (gnutls_pkcs7_get_embedded_data (p7, 0, &embedded) >= 0) {
            imprint = contains_bytes (embedded.data, embedded.size, hash, 32);
            res->timestamp_time = find_gen_time (embedded.data, embedded.size);
            gnutls_free (embedded.data);
        }
        res->timestamped = TRUE;
        if (r < 0 || !imprint) {
            res->status = 2;
            res->message = g_strdup (r < 0 ? gnutls_strerror (r) : "The timestamp does not match the document");
        }
    } else {
        r = gnutls_pkcs7_verify_direct (p7, signer, 0, &content, 0);
        if (r < 0) {
            res->status = 2;
            res->message = g_strdup (gnutls_strerror (r));
        }
    }
    if (res->status != 2) {
        gnutls_x509_trust_list_t tl = make_trust (trust_dir);
        r = gnutls_pkcs7_verify (p7, tl, NULL, 0, 0, timestamp_token ? NULL : &content, 0);
        if (r >= 0) {
            res->status = 0;
        } else {
            res->status = 1;
            res->message = g_strdup (gnutls_strerror (r));
        }
        gnutls_x509_trust_list_deinit (tl, 1);
    }
    gnutls_x509_crt_deinit (signer);
    gnutls_pkcs7_signature_info_deinit (&info);
    gnutls_pkcs7_deinit (p7);
    return res;
}

void
reader_verify_result_free (ReaderVerifyResult *r)
{
    if (r == NULL)
        return;
    g_free (r->signer);
    g_free (r->signer_dn);
    g_free (r->issuer);
    g_free (r->serial);
    g_free (r->message);
    g_free (r->ocsp_url);
    g_free (r);
}

GBytes *
reader_ocsp_request (const guint8 *cms, gsize cms_length, const char *trust_dir, char **url)
{
    *url = NULL;
    gnutls_global_init ();
    gnutls_pkcs7_t p7;
    gnutls_pkcs7_init (&p7);
    gnutls_datum_t in = { (unsigned char *) cms, (unsigned int) cms_length };
    if (gnutls_pkcs7_import (p7, &in, GNUTLS_X509_FMT_DER) < 0) {
        gnutls_pkcs7_deinit (p7);
        return NULL;
    }
    gnutls_pkcs7_signature_info_st info;
    memset (&info, 0, sizeof (info));
    if (gnutls_pkcs7_get_signature_info (p7, 0, &info) < 0) {
        gnutls_pkcs7_deinit (p7);
        return NULL;
    }
    gnutls_x509_crt_t signer = find_signer (p7, &info);
    GBytes *result = NULL;
    if (signer != NULL) {
        gnutls_datum_t aia = { NULL, 0 };
        unsigned int critical;
        if (gnutls_x509_crt_get_authority_info_access (signer, 0, GNUTLS_IA_OCSP_URI, &aia, &critical) >= 0) {
            *url = g_strndup ((const char *) aia.data, aia.size);
            gnutls_free (aia.data);
        }
        gnutls_x509_crt_t issuer = NULL;
        int count = gnutls_pkcs7_get_crt_count (p7);
        for (int i = 0; i < count && issuer == NULL; i++) {
            gnutls_datum_t raw = { NULL, 0 };
            if (gnutls_pkcs7_get_crt_raw2 (p7, i, &raw) < 0)
                continue;
            gnutls_x509_crt_t c;
            gnutls_x509_crt_init (&c);
            if (gnutls_x509_crt_import (c, &raw, GNUTLS_X509_FMT_DER) >= 0 && gnutls_x509_crt_check_issuer (signer, c) && !gnutls_x509_crt_equals (signer, c))
                issuer = c;
            else
                gnutls_x509_crt_deinit (c);
            gnutls_free (raw.data);
        }
        if (issuer == NULL) {
            gnutls_x509_trust_list_t tl = make_trust (trust_dir);
            gnutls_x509_crt_t found = NULL;
            if (gnutls_x509_trust_list_get_issuer (tl, signer, &found, GNUTLS_TL_GET_COPY) >= 0)
                issuer = found;
            gnutls_x509_trust_list_deinit (tl, 1);
        }
        if (issuer != NULL && *url != NULL) {
            gnutls_ocsp_req_t req;
            gnutls_ocsp_req_init (&req);
            if (gnutls_ocsp_req_add_cert (req, GNUTLS_DIG_SHA1, issuer, signer) >= 0) {
                gnutls_datum_t der = { NULL, 0 };
                if (gnutls_ocsp_req_export (req, &der) >= 0) {
                    result = g_bytes_new (der.data, der.size);
                    gnutls_free (der.data);
                }
            }
            gnutls_ocsp_req_deinit (req);
        }
        if (issuer != NULL)
            gnutls_x509_crt_deinit (issuer);
        gnutls_x509_crt_deinit (signer);
    }
    gnutls_pkcs7_signature_info_deinit (&info);
    gnutls_pkcs7_deinit (p7);
    return result;
}

int
reader_ocsp_status (const guint8 *response, gsize length)
{
    gnutls_ocsp_resp_t resp;
    gnutls_ocsp_resp_init (&resp);
    gnutls_datum_t in = { (unsigned char *) response, (unsigned int) length };
    int status = -1;
    if (gnutls_ocsp_resp_import (resp, &in) >= 0 && gnutls_ocsp_resp_get_status (resp) == GNUTLS_OCSP_RESP_SUCCESSFUL) {
        unsigned int cert_status = 0;
        if (gnutls_ocsp_resp_get_single (resp, 0, NULL, NULL, NULL, NULL, &cert_status, NULL, NULL, NULL, NULL) >= 0)
            status = (int) cert_status;
    }
    gnutls_ocsp_resp_deinit (resp);
    return status;
}

char **
reader_pkcs11_list (int *count)
{
    gnutls_global_init ();
    *count = 0;
    GPtrArray *list = g_ptr_array_new ();
    gnutls_pkcs11_obj_t *objs = NULL;
    unsigned int n = 0;
    if (gnutls_pkcs11_obj_list_import_url4 (&objs, &n, "pkcs11:", GNUTLS_PKCS11_OBJ_FLAG_CRT | GNUTLS_PKCS11_OBJ_FLAG_WITH_PRIVKEY) >= 0) {
        for (unsigned int i = 0; i < n; i++) {
            char *url = NULL;
            char label[256] = { 0 };
            size_t size = sizeof (label) - 1;
            gnutls_pkcs11_obj_get_info (objs[i], GNUTLS_PKCS11_OBJ_LABEL, label, &size);
            if (gnutls_pkcs11_obj_export_url (objs[i], GNUTLS_PKCS11_URL_GENERIC, &url) >= 0) {
                GString *key_url = g_string_new (url);
                char *type = strstr (key_url->str, "type=cert");
                if (type != NULL) {
                    gsize off = type - key_url->str;
                    g_string_erase (key_url, off, 9);
                    g_string_insert (key_url, off, "type=private");
                }
                g_ptr_array_add (list, g_strdup_printf ("%s\t%s", label, key_url->str));
                g_string_free (key_url, TRUE);
                gnutls_free (url);
            }
            gnutls_pkcs11_obj_deinit (objs[i]);
        }
        gnutls_free (objs);
    }
    *count = (int) list->len;
    g_ptr_array_add (list, NULL);
    return (char **) g_ptr_array_free (list, FALSE);
}

static const guint8 OID_ENVELOPED_DATA[] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x03 };
static const guint8 OID_AES256_CBC[] = { 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2a };
static const guint8 OID_AES128_CBC[] = { 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x02 };
static const guint8 OID_DES_EDE3_CBC[] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x03, 0x07 };

static gnutls_x509_crt_t
load_certificate (const char *path, GError **error)
{
    gchar *contents = NULL;
    gsize length = 0;
    if (!g_file_get_contents (path, &contents, &length, error))
        return NULL;
    gnutls_datum_t datum = { (unsigned char *) contents, (unsigned int) length };
    gnutls_x509_crt_t crt;
    gnutls_x509_crt_init (&crt);
    int r = gnutls_x509_crt_import (crt, &datum, GNUTLS_X509_FMT_PEM);
    if (r < 0)
        r = gnutls_x509_crt_import (crt, &datum, GNUTLS_X509_FMT_DER);
    g_free (contents);
    if (r < 0) {
        gnutls_x509_crt_deinit (crt);
        set_error (error, "The certificate could not be read", r);
        return NULL;
    }
    return crt;
}

GBytes *
reader_envelope_encrypt (const char *cert_path, const guint8 *content, gsize length, GError **error)
{
    gnutls_global_init ();
    gnutls_x509_crt_t crt = load_certificate (cert_path, error);
    if (crt == NULL)
        return NULL;
    gnutls_pubkey_t pub;
    gnutls_pubkey_init (&pub);
    int r = gnutls_pubkey_import_x509 (pub, crt, 0);
    if (r < 0 || gnutls_pubkey_get_pk_algorithm (pub, NULL) != GNUTLS_PK_RSA) {
        gnutls_pubkey_deinit (pub);
        gnutls_x509_crt_deinit (crt);
        set_error (error, "Only RSA certificates can be used for encryption", r < 0 ? r : 0);
        return NULL;
    }
    guint8 cek[32], iv[16];
    gnutls_rnd (GNUTLS_RND_KEY, cek, sizeof (cek));
    gnutls_rnd (GNUTLS_RND_NONCE, iv, sizeof (iv));
    gnutls_datum_t plain_key = { cek, sizeof (cek) };
    gnutls_datum_t enc_key = { NULL, 0 };
    r = gnutls_pubkey_encrypt_data (pub, 0, &plain_key, &enc_key);
    gnutls_pubkey_deinit (pub);
    if (r < 0) {
        gnutls_x509_crt_deinit (crt);
        set_error (error, "The key could not be encrypted", r);
        return NULL;
    }
    gsize padded_len = (length / 16 + 1) * 16;
    guint8 *padded = g_malloc (padded_len);
    memcpy (padded, content, length);
    memset (padded + length, (int) (padded_len - length), padded_len - length);
    gnutls_cipher_hd_t cipher;
    gnutls_datum_t k = { cek, sizeof (cek) };
    gnutls_datum_t v = { iv, sizeof (iv) };
    r = gnutls_cipher_init (&cipher, GNUTLS_CIPHER_AES_256_CBC, &k, &v);
    if (r == 0) {
        r = gnutls_cipher_encrypt (cipher, padded, padded_len);
        gnutls_cipher_deinit (cipher);
    }
    if (r < 0) {
        g_free (padded);
        gnutls_free (enc_key.data);
        gnutls_x509_crt_deinit (crt);
        set_error (error, "The content could not be encrypted", r);
        return NULL;
    }
    gnutls_datum_t issuer = { NULL, 0 };
    gnutls_x509_crt_get_raw_issuer_dn (crt, &issuer);
    guint8 serial[64];
    size_t serial_len = sizeof (serial);
    gnutls_x509_crt_get_serial (crt, serial, &serial_len);

    GByteArray *ias = g_byte_array_new ();
    g_byte_array_append (ias, issuer.data, issuer.size);
    der_int_bytes (ias, serial, serial_len);
    GByteArray *ktri = g_byte_array_new ();
    der_small_int (ktri, 0);
    der_wrap (ktri, 0x30, ias);
    der_algorithm (ktri, OID_RSA, sizeof (OID_RSA), TRUE);
    der_tlv (ktri, 0x04, enc_key.data, enc_key.size);
    GByteArray *recipients = g_byte_array_new ();
    der_wrap (recipients, 0x30, ktri);

    GByteArray *alg = g_byte_array_new ();
    der_oid (alg, OID_AES256_CBC, sizeof (OID_AES256_CBC));
    der_tlv (alg, 0x04, iv, sizeof (iv));
    GByteArray *eci = g_byte_array_new ();
    der_oid (eci, OID_DATA, sizeof (OID_DATA));
    der_wrap (eci, 0x30, alg);
    der_tlv (eci, 0x80, padded, padded_len);

    GByteArray *env = g_byte_array_new ();
    der_small_int (env, 0);
    der_wrap (env, 0x31, recipients);
    der_wrap (env, 0x30, eci);
    GByteArray *env_seq = g_byte_array_new ();
    der_wrap (env_seq, 0x30, env);
    GByteArray *ci = g_byte_array_new ();
    der_oid (ci, OID_ENVELOPED_DATA, sizeof (OID_ENVELOPED_DATA));
    der_wrap (ci, 0xa0, env_seq);
    GByteArray *out = g_byte_array_new ();
    der_wrap (out, 0x30, ci);

    g_free (padded);
    gnutls_free (enc_key.data);
    gnutls_free (issuer.data);
    gnutls_x509_crt_deinit (crt);
    return g_byte_array_free_to_bytes (out);
}

static gboolean
enter (const guint8 *d, gsize total, gsize *pos, guint8 expect, gsize *end)
{
    guint8 tag;
    gsize header, len;
    if (!der_read (d, total, *pos, &tag, &header, &len) || tag != expect)
        return FALSE;
    *pos += header;
    if (end != NULL)
        *end = *pos + len;
    return TRUE;
}

static gboolean
skip (const guint8 *d, gsize total, gsize *pos)
{
    guint8 tag;
    gsize header, len;
    if (!der_read (d, total, *pos, &tag, &header, &len))
        return FALSE;
    *pos += header + len;
    return TRUE;
}

static gboolean
int_equal (const guint8 *a, gsize alen, const guint8 *b, gsize blen)
{
    while (alen > 1 && a[0] == 0) {
        a++;
        alen--;
    }
    while (blen > 1 && b[0] == 0) {
        b++;
        blen--;
    }
    return alen == blen && memcmp (a, b, alen) == 0;
}

GBytes *
reader_envelope_decrypt (ReaderSignKey *key, const guint8 *d, gsize total, GError **error)
{
    gnutls_global_init ();
    gsize pos = 0, end;
    if (!enter (d, total, &pos, 0x30, NULL) || !skip (d, total, &pos) || !enter (d, total, &pos, 0xa0, NULL)
        || !enter (d, total, &pos, 0x30, NULL) || !skip (d, total, &pos)) {
        g_set_error (error, SIGNING_ERROR, 2, "The recipient data is not valid");
        return NULL;
    }
    guint8 tag;
    gsize header, len;
    if (der_read (d, total, pos, &tag, &header, &len) && tag == 0xa0)
        pos += header + len;
    gsize set_end;
    if (!enter (d, total, &pos, 0x31, &set_end)) {
        g_set_error (error, SIGNING_ERROR, 2, "The recipient data is not valid");
        return NULL;
    }
    gnutls_datum_t issuer = { NULL, 0 };
    gnutls_x509_crt_get_raw_issuer_dn (key->certs[0], &issuer);
    guint8 serial[64];
    size_t serial_len = sizeof (serial);
    gnutls_x509_crt_get_serial (key->certs[0], serial, &serial_len);
    const guint8 *enc_key = NULL;
    gsize enc_key_len = 0;
    while (pos < set_end) {
        gsize ri_end;
        if (!enter (d, total, &pos, 0x30, &ri_end))
            break;
        gsize p = pos;
        skip (d, total, &p);
        gsize ias_end;
        gboolean match = FALSE;
        if (enter (d, total, &p, 0x30, &ias_end)) {
            gsize name_start = p;
            skip (d, total, &p);
            gsize name_len = p - name_start;
            gsize sp = p;
            if (der_read (d, total, sp, &tag, &header, &len) && tag == 0x02) {
                match = name_len == issuer.size && memcmp (d + name_start, issuer.data, name_len) == 0
                    && int_equal (d + sp + header, len, serial, serial_len);
            }
            p = ias_end;
            skip (d, total, &p);
            if (match && der_read (d, total, p, &tag, &header, &len) && tag == 0x04) {
                enc_key = d + p + header;
                enc_key_len = len;
            }
        }
        pos = ri_end;
        if (enc_key != NULL)
            break;
    }
    gnutls_free (issuer.data);
    if (enc_key == NULL) {
        g_set_error (error, SIGNING_ERROR, 3, "This certificate is not a recipient of the document");
        return NULL;
    }
    pos = set_end;
    gsize eci_end;
    if (!enter (d, total, &pos, 0x30, &eci_end) || !skip (d, total, &pos)) {
        g_set_error (error, SIGNING_ERROR, 2, "The recipient data is not valid");
        return NULL;
    }
    gsize alg_end;
    if (!enter (d, total, &pos, 0x30, &alg_end) || !der_read (d, total, pos, &tag, &header, &len) || tag != 0x06) {
        g_set_error (error, SIGNING_ERROR, 2, "The recipient data is not valid");
        return NULL;
    }
    const guint8 *oid = d + pos + header;
    gsize oid_len = len;
    pos += header + len;
    const guint8 *iv = NULL;
    gsize iv_len = 0;
    if (der_read (d, total, pos, &tag, &header, &len) && tag == 0x04) {
        iv = d + pos + header;
        iv_len = len;
    }
    pos = alg_end;
    GByteArray *content = g_byte_array_new ();
    if (der_read (d, total, pos, &tag, &header, &len) && tag == 0x80) {
        g_byte_array_append (content, d + pos + header, len);
    } else if (tag == 0xa0) {
        gsize p = pos + header, e = pos + header + len;
        while (p < e && der_read (d, total, p, &tag, &header, &len)) {
            g_byte_array_append (content, d + p + header, len);
            p += header + len;
        }
    }
    gnutls_cipher_algorithm_t algo;
    gsize key_len;
    if (oid_len == sizeof (OID_AES256_CBC) && memcmp (oid, OID_AES256_CBC, oid_len) == 0) {
        algo = GNUTLS_CIPHER_AES_256_CBC;
        key_len = 32;
    } else if (oid_len == sizeof (OID_AES128_CBC) && memcmp (oid, OID_AES128_CBC, oid_len) == 0) {
        algo = GNUTLS_CIPHER_AES_128_CBC;
        key_len = 16;
    } else if (oid_len == sizeof (OID_DES_EDE3_CBC) && memcmp (oid, OID_DES_EDE3_CBC, oid_len) == 0) {
        algo = GNUTLS_CIPHER_3DES_CBC;
        key_len = 24;
    } else {
        g_byte_array_unref (content);
        g_set_error (error, SIGNING_ERROR, 4, "The document uses an unsupported cipher");
        return NULL;
    }
    gnutls_datum_t cipher_key = { (unsigned char *) enc_key, (unsigned int) enc_key_len };
    gnutls_datum_t cek = { NULL, 0 };
    int r = gnutls_privkey_decrypt_data (key->key, 0, &cipher_key, &cek);
    if (r < 0 || cek.size != key_len || iv == NULL || content->len == 0 || content->len % (algo == GNUTLS_CIPHER_3DES_CBC ? 8 : 16) != 0) {
        if (cek.data != NULL)
            gnutls_free (cek.data);
        g_byte_array_unref (content);
        set_error (error, "The document key could not be decrypted", r < 0 ? r : 0);
        return NULL;
    }
    gnutls_cipher_hd_t hd;
    gnutls_datum_t v = { (unsigned char *) iv, (unsigned int) iv_len };
    r = gnutls_cipher_init (&hd, algo, &cek, &v);
    if (r == 0) {
        r = gnutls_cipher_decrypt (hd, content->data, content->len);
        gnutls_cipher_deinit (hd);
    }
    gnutls_free (cek.data);
    if (r < 0) {
        g_byte_array_unref (content);
        set_error (error, "The document content could not be decrypted", r);
        return NULL;
    }
    guint8 pad = content->data[content->len - 1];
    if (pad >= 1 && pad <= 16 && pad <= content->len)
        g_byte_array_set_size (content, content->len - pad);
    return g_byte_array_free_to_bytes (content);
}
