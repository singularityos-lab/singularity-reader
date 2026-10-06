namespace Singularity.Apps.Reader {

    public enum SignatureState {
        VALID_TRUSTED,
        VALID_UNTRUSTED,
        INVALID,
        MODIFIED_AFTER,
        ERROR
    }

    public enum RevocationState {
        NOT_CHECKED,
        GOOD,
        REVOKED,
        UNKNOWN
    }

    public class TokenCert : Object {
        public string label { get; construct; }
        public string url { get; construct; }

        public TokenCert (string label, string url) {
            Object (label: label, url: url);
        }
    }

    public class SignatureStatus : Object {
        public string field = "";
        public string signer = "";
        public string signer_dn = "";
        public string issuer = "";
        public string serial = "";
        public SignatureState status = SignatureState.ERROR;
        public string message = "";
        public DateTime? signing_time = null;
        public DateTime? valid_from = null;
        public DateTime? valid_until = null;
        public bool timestamped = false;
        public bool is_document_timestamp = false;
        public bool covers_whole_file = false;
        public int64 revision_end = 0;
        public bool certification = false;
        public bool only_annotations_after = false;
        public RevocationState revocation = RevocationState.NOT_CHECKED;
        public string reason = "";
        public string location = "";
        public int page = -1;

        public bool integrity_ok {
            get { return status == SignatureState.VALID_TRUSTED || status == SignatureState.VALID_UNTRUSTED || status == SignatureState.MODIFIED_AFTER; }
        }
    }

    public delegate uint8[] TimestampFetcher (uint8[] request) throws Error;

    public class DigitalSigner : Object {
        public static string trust_dir () {
            return Path.build_filename (Environment.get_user_data_dir (), "singularity-reader", "trust");
        }

        public static void trust_certificate (string path) throws Error {
            uint8[] data;
            FileUtils.get_data (path, out data);
            string text = (string) Singularity.Pdf.Standards.terminated (data);
            string pem;
            if (text.contains ("-----BEGIN CERTIFICATE-----")) {
                pem = text;
            } else {
                var b = new StringBuilder ("-----BEGIN CERTIFICATE-----\n");
                string encoded = Base64.encode (data);
                for (int i = 0; i < encoded.length; i += 64) b.append (encoded.substring (i, int.min (64, encoded.length - i)) + "\n");
                b.append ("-----END CERTIFICATE-----\n");
                pem = b.str;
            }
            DirUtils.create_with_parents (trust_dir (), 0700);
            string name = Checksum.compute_for_data (ChecksumType.SHA256, data).substring (0, 16) + ".pem";
            FileUtils.set_contents (Path.build_filename (trust_dir (), name), pem);
        }

        public static uint8[] http_post (string url, uint8[] body, string content_type) throws Error {
            var uri = Uri.parse (url, UriFlags.NONE);
            string scheme = uri.get_scheme ().down ();
            if (scheme != "http" && scheme != "https") throw new IOError.NOT_SUPPORTED ("Only http and https addresses are supported");
            int port = uri.get_port ();
            if (port <= 0) port = scheme == "https" ? 443 : 80;
            var client = new SocketClient ();
            client.tls = scheme == "https";
            client.timeout = 20;
            var conn = client.connect_to_host (uri.get_host (), (uint16) port);
            string path = uri.get_path ();
            if (path == "") path = "/";
            if (uri.get_query () != null) path += "?" + uri.get_query ();
            var head = "POST %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: Singularity-Reader\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n".printf (
                path, uri.get_host (), content_type, body.length);
            var output = conn.output_stream;
            size_t written;
            output.write_all (head.data, out written);
            output.write_all (body, out written);
            output.flush ();
            var buf = new ByteArray ();
            var chunk = new uint8[8192];
            ssize_t n;
            while ((n = conn.input_stream.read (chunk)) > 0) buf.append (chunk[0 : n]);
            conn.close ();
            uint8[] all = buf.steal ();
            int sep = Singularity.Pdf.Lexer.find (all, "\r\n\r\n", 0);
            if (sep < 0) throw new IOError.INVALID_DATA ("The server answer is not valid");
            string headers = (string) Singularity.Pdf.Standards.terminated (all[0 : sep]);
            string status_line = headers.split ("\r\n")[0];
            string[] parts = status_line.split (" ");
            if (parts.length < 2 || !parts[1].has_prefix ("2")) throw new IOError.FAILED ("The server answered %s", status_line);
            uint8[] payload = all[sep + 4 : all.length];
            if (headers.down ().contains ("transfer-encoding: chunked")) payload = dechunk (payload);
            return payload;
        }

        private static uint8[] dechunk (uint8[] data) {
            var out_buf = new ByteArray ();
            int pos = 0;
            while (pos < data.length) {
                int line_end = Singularity.Pdf.Lexer.find (data, "\r\n", pos);
                if (line_end < 0) break;
                string size_hex = ((string) Singularity.Pdf.Standards.terminated (data[pos : line_end])).split (";")[0].strip ();
                int64 size = 0;
                int64.try_parse (size_hex, out size, null, 16);
                if (size <= 0) break;
                int start = line_end + 2;
                int end = (int) int64.min (data.length, start + size);
                out_buf.append (data[start : end]);
                pos = end + 2;
            }
            return out_buf.steal ();
        }

        public static uint8[] sign_with (Singularity.Pdf.Document doc, Singularity.Pdf.SignatureRequest req, SigningNative.SignKey key,
                                         TimestampFetcher? fetch) throws Error {
            if (req.signer == "") req.signer = key.subject ();
            if (req.appearance_lines.length == 0 && req.rect.width () > 1) {
                var now = new DateTime.now_local ();
                string[] lines = { _("Digitally signed by %s").printf (req.signer), _("Date: %s").printf (now.format ("%Y-%m-%d %H:%M:%S %z")) };
                if (req.reason != "") lines += _("Reason: %s").printf (req.reason);
                if (req.location != "") lines += _("Location: %s").printf (req.location);
                req.appearance_lines = lines;
            }
            var prep = Singularity.Pdf.Signing.prepare (doc, req);
            var cms = SigningNative.Cms.create (key, prep.signed_bytes ());
            if (fetch != null) {
                var request = cms.timestamp_request ();
                var response = fetch (request.get_data ());
                cms.add_timestamp_response (response);
            }
            return prep.finish (cms.encode ().get_data ());
        }

        private static TimestampFetcher? http_fetcher (string? tsa_url) {
            if (tsa_url == null || tsa_url.strip () == "") return null;
            string url = tsa_url.strip ();
            return (request) => {
                return http_post (url, request, "application/timestamp-query");
            };
        }

        public static uint8[] sign_file_pkcs12 (Singularity.Pdf.Document doc, Singularity.Pdf.SignatureRequest req, string p12_path, string password,
                                                string? tsa_url) throws Error {
            var key = SigningNative.SignKey.pkcs12 (p12_path, password);
            return sign_with (doc, req, key, http_fetcher (tsa_url));
        }

        public static uint8[] sign_pkcs11 (Singularity.Pdf.Document doc, Singularity.Pdf.SignatureRequest req, string url, string pin,
                                           string? tsa_url) throws Error {
            var key = SigningNative.SignKey.pkcs11 (url, pin);
            return sign_with (doc, req, key, http_fetcher (tsa_url));
        }

        public static uint8[] timestamp_document (Singularity.Pdf.Document doc, TimestampFetcher fetch) throws Error {
            var req = new Singularity.Pdf.SignatureRequest ();
            req.timestamp_only = true;
            req.field_name = "Timestamp1";
            var prep = Singularity.Pdf.Signing.prepare (doc, req);
            var request = SigningNative.timestamp_request_for_data (prep.signed_bytes ());
            var response = fetch (request.get_data ());
            var token = SigningNative.timestamp_token_from_response (response);
            return prep.finish (token.get_data ());
        }

        public static uint8[] timestamp_document_online (Singularity.Pdf.Document doc, string tsa_url) throws Error {
            return timestamp_document (doc, http_fetcher (tsa_url));
        }

        public static Gee.List<TokenCert> list_tokens () {
            var result = new Gee.ArrayList<TokenCert> ();
            foreach (var entry in SigningNative.pkcs11_list ()) {
                string[] parts = entry.split ("\t", 2);
                if (parts.length == 2) result.add (new TokenCert (parts[0], parts[1]));
            }
            return result;
        }

        private static DateTime? from_unix (int64 t) {
            return t > 0 ? new DateTime.from_unix_local (t) : null;
        }

        private static bool same_pages (Singularity.Pdf.Document a, Singularity.Pdf.Document b) {
            if (a.page_count () != b.page_count ()) return false;
            for (int i = 0; i < a.page_count (); i++) {
                var ca = a.page_content (i);
                var cb = b.page_content (i);
                if (ca.length != cb.length) return false;
                if (Checksum.compute_for_data (ChecksumType.SHA256, ca) != Checksum.compute_for_data (ChecksumType.SHA256, cb)) return false;
            }
            return true;
        }

        public static Gee.List<SignatureStatus> verify (Singularity.Pdf.Document doc, bool check_revocation) {
            var result = new Gee.ArrayList<SignatureStatus> ();
            foreach (var info in Singularity.Pdf.Signing.list (doc)) {
                var st = new SignatureStatus ();
                st.field = info.field;
                st.reason = info.reason;
                st.location = info.location;
                st.page = info.page;
                st.covers_whole_file = info.covers_whole_file;
                st.revision_end = info.revision_end;
                st.certification = info.certification;
                st.is_document_timestamp = info.is_timestamp;
                if (info.byte_range.length != 4 || info.contents.length == 0) {
                    st.status = SignatureState.ERROR;
                    st.message = _("The signature is incomplete");
                    result.add (st);
                    continue;
                }
                var signed = Singularity.Pdf.Signing.signed_bytes (doc.data, info.byte_range);
                bool range_ok = info.byte_range[0] == 0 && info.byte_range[1] < info.byte_range[2]
                    && info.byte_range[2] + info.byte_range[3] <= doc.data.length;
                var r = SigningNative.verify (info.contents, signed, trust_dir (), info.is_timestamp);
                st.signer = r.signer ?? info.signer;
                if (st.signer == "") st.signer = info.signer;
                st.signer_dn = r.signer_dn ?? "";
                st.issuer = r.issuer ?? "";
                st.serial = r.serial ?? "";
                st.valid_from = from_unix (r.not_before);
                st.valid_until = from_unix (r.not_after);
                st.timestamped = r.timestamped;
                if (r.timestamp_time > 0) st.signing_time = from_unix (r.timestamp_time);
                else if (info.date != "") st.signing_time = Singularity.Pdf.Annotations.parse_date (info.date);
                else st.signing_time = from_unix (r.signing_time);
                switch (r.status) {
                    case 0:
                        st.status = SignatureState.VALID_TRUSTED;
                        st.message = _("The signature is valid and the signer is trusted");
                        break;
                    case 1:
                        st.status = SignatureState.VALID_UNTRUSTED;
                        st.message = _("The document has not changed, but the signer's certificate is not trusted");
                        break;
                    case 2:
                        st.status = SignatureState.INVALID;
                        st.message = _("The signature is not valid: the signed content was changed");
                        break;
                    default:
                        st.status = SignatureState.ERROR;
                        st.message = r.message ?? _("The signature cannot be checked");
                        break;
                }
                if (!range_ok && st.integrity_ok) {
                    st.status = SignatureState.INVALID;
                    st.message = _("The signed byte range is not valid");
                }
                if (st.integrity_ok && !info.covers_whole_file) {
                    st.status = SignatureState.MODIFIED_AFTER;
                    try {
                        var before = Singularity.Pdf.Document.open_bytes (Singularity.Pdf.Signing.revision (doc.data, info.revision_end));
                        st.only_annotations_after = same_pages (before, doc);
                    } catch (Error e) {
                        st.only_annotations_after = false;
                    }
                    st.message = st.only_annotations_after
                        ? _("The signed version is intact; comments or form fields were added later")
                        : _("The signed version is intact, but the document was changed after signing");
                }
                if (check_revocation && st.integrity_ok && !info.is_timestamp) st.revocation = check_ocsp (info.contents);
                result.add (st);
            }
            return result;
        }

        public static RevocationState check_ocsp (uint8[] cms) {
            string? url;
            var request = SigningNative.ocsp_request (cms, trust_dir (), out url);
            if (request == null || url == null) return RevocationState.UNKNOWN;
            try {
                var response = http_post (url, request.get_data (), "application/ocsp-request");
                int s = SigningNative.ocsp_status (response);
                if (s == 0) return RevocationState.GOOD;
                if (s == 1) return RevocationState.REVOKED;
            } catch (Error e) {
            }
            return RevocationState.UNKNOWN;
        }
    }
}
