#pragma once

#include <glib.h>

typedef struct _ReaderSignKey ReaderSignKey;
typedef struct _ReaderCms ReaderCms;

typedef struct {
    int status;
    char *signer;
    char *signer_dn;
    char *issuer;
    char *serial;
    gint64 not_before;
    gint64 not_after;
    gint64 signing_time;
    gint64 timestamp_time;
    gboolean timestamped;
    char *message;
    char *ocsp_url;
} ReaderVerifyResult;

ReaderSignKey *reader_sign_key_pkcs12 (const char *path, const char *password, GError **error);
ReaderSignKey *reader_sign_key_pkcs11 (const char *url, const char *pin, GError **error);
void reader_sign_key_free (ReaderSignKey *key);
char *reader_sign_key_subject (ReaderSignKey *key);

ReaderCms *reader_cms_new (ReaderSignKey *key, const guint8 *data, gsize length, GError **error);
void reader_cms_free (ReaderCms *cms);
GBytes *reader_cms_signature (ReaderCms *cms);
GBytes *reader_cms_timestamp_request (ReaderCms *cms);
gboolean reader_cms_add_timestamp_response (ReaderCms *cms, const guint8 *data, gsize length, GError **error);
GBytes *reader_cms_encode (ReaderCms *cms);

GBytes *reader_timestamp_request_for_data (const guint8 *data, gsize length);
GBytes *reader_timestamp_token_from_response (const guint8 *data, gsize length, GError **error);

ReaderVerifyResult *reader_cms_verify (const guint8 *cms, gsize cms_length, const guint8 *data, gsize length,
                                       const char *trust_dir, gboolean timestamp_token);
void reader_verify_result_free (ReaderVerifyResult *result);

GBytes *reader_ocsp_request (const guint8 *cms, gsize cms_length, const char *trust_dir, char **url);
int reader_ocsp_status (const guint8 *response, gsize length);

char **reader_pkcs11_list (int *count);

GBytes *reader_envelope_encrypt (const char *cert_path, const guint8 *content, gsize length, GError **error);
GBytes *reader_envelope_decrypt (ReaderSignKey *key, const guint8 *data, gsize length, GError **error);
