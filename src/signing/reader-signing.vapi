[CCode (cheader_filename = "src/signing/signing.h")]
namespace Singularity.Apps.Reader.SigningNative {
    [Compact]
    [CCode (cname = "ReaderSignKey", free_function = "reader_sign_key_free")]
    public class SignKey {
        [CCode (cname = "reader_sign_key_pkcs12")]
        public static SignKey? pkcs12 (string path, string password) throws GLib.Error;
        [CCode (cname = "reader_sign_key_pkcs11")]
        public static SignKey? pkcs11 (string url, string pin) throws GLib.Error;
        [CCode (cname = "reader_sign_key_subject")]
        public string subject ();
    }

    [Compact]
    [CCode (cname = "ReaderCms", free_function = "reader_cms_free")]
    public class Cms {
        [CCode (cname = "reader_cms_new")]
        public static Cms? create (SignKey key, [CCode (array_length_type = "gsize")] uint8[] data) throws GLib.Error;
        [CCode (cname = "reader_cms_signature")]
        public GLib.Bytes signature ();
        [CCode (cname = "reader_cms_timestamp_request")]
        public GLib.Bytes timestamp_request ();
        [CCode (cname = "reader_cms_add_timestamp_response")]
        public bool add_timestamp_response ([CCode (array_length_type = "gsize")] uint8[] data) throws GLib.Error;
        [CCode (cname = "reader_cms_encode")]
        public GLib.Bytes encode ();
    }

    [Compact]
    [CCode (cname = "ReaderVerifyResult", free_function = "reader_verify_result_free")]
    public class VerifyResult {
        public int status;
        public string? signer;
        public string? signer_dn;
        public string? issuer;
        public string? serial;
        public int64 not_before;
        public int64 not_after;
        public int64 signing_time;
        public int64 timestamp_time;
        public bool timestamped;
        public string? message;
        public string? ocsp_url;
    }

    [CCode (cname = "reader_cms_verify")]
    public VerifyResult verify ([CCode (array_length_type = "gsize")] uint8[] cms, [CCode (array_length_type = "gsize")] uint8[] data, string? trust_dir, bool timestamp_token);
    [CCode (cname = "reader_timestamp_request_for_data")]
    public GLib.Bytes timestamp_request_for_data ([CCode (array_length_type = "gsize")] uint8[] data);
    [CCode (cname = "reader_timestamp_token_from_response")]
    public GLib.Bytes? timestamp_token_from_response ([CCode (array_length_type = "gsize")] uint8[] data) throws GLib.Error;
    [CCode (cname = "reader_ocsp_request")]
    public GLib.Bytes? ocsp_request ([CCode (array_length_type = "gsize")] uint8[] cms, string? trust_dir, out string? url);
    [CCode (cname = "reader_ocsp_status")]
    public int ocsp_status ([CCode (array_length_type = "gsize")] uint8[] response);
    [CCode (cname = "reader_pkcs11_list", array_length_pos = 0.1)]
    public string[] pkcs11_list ();
    [CCode (cname = "reader_envelope_encrypt")]
    public GLib.Bytes? envelope_encrypt (string cert_path, [CCode (array_length_type = "gsize")] uint8[] content) throws GLib.Error;
    [CCode (cname = "reader_envelope_decrypt")]
    public GLib.Bytes? envelope_decrypt (SignKey key, [CCode (array_length_type = "gsize")] uint8[] data) throws GLib.Error;
}
