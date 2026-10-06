namespace Singularity.Apps.Reader {

    public class CertEncryption : Object {
        private static string? unlock_path = null;
        private static string? unlock_password = null;

        public static uint8[] encrypt_for (Singularity.Pdf.Document doc, string[] cert_paths, int permissions) throws Error {
            if (cert_paths.length == 0) throw new IOError.INVALID_ARGUMENT (_("Add at least one certificate"));
            var content = new uint8[24];
            var seed = Singularity.Pdf.Crypto.random_bytes (20);
            for (int i = 0; i < 20; i++) content[i] = seed[i];
            uint32 p = (uint32) Singularity.Pdf.Permissions.to_p (permissions);
            content[20] = (uint8) (p >> 24);
            content[21] = (uint8) (p >> 16);
            content[22] = (uint8) (p >> 8);
            content[23] = (uint8) p;
            var envelopes = new Gee.ArrayList<Bytes> ();
            foreach (var path in cert_paths) {
                var env = SigningNative.envelope_encrypt (path, content);
                if (env == null) throw new IOError.FAILED (_("The certificate %s could not be used").printf (Path.get_basename (path)));
                envelopes.add (env);
            }
            var opts = new Singularity.Pdf.SaveOptions ();
            opts.mode = Singularity.Pdf.SaveMode.FULL;
            opts.new_security = Singularity.Pdf.SecurityHandler.create_pubsec (seed, envelopes, permissions);
            return doc.save (opts);
        }

        public static void install_unlocker (string p12_path, string password) {
            unlock_path = p12_path;
            unlock_password = password;
            Singularity.Pdf.SecurityHandler.pubsec_unlocker = (recipients) => {
                if (unlock_path == null) throw new IOError.PERMISSION_DENIED (_("No certificate was chosen"));
                var key = SigningNative.SignKey.pkcs12 (unlock_path, unlock_password ?? "");
                Error? last = null;
                foreach (var r in recipients) {
                    try {
                        var content = SigningNative.envelope_decrypt (key, r.get_data ());
                        if (content != null) return content.get_data ();
                    } catch (Error e) {
                        last = e;
                    }
                }
                throw new IOError.PERMISSION_DENIED (last != null ? last.message : _("This certificate cannot open the document"));
            };
        }

        public static void remove_unlocker () {
            unlock_path = null;
            unlock_password = null;
            Singularity.Pdf.SecurityHandler.pubsec_unlocker = null;
        }

        public static bool needs_certificate (uint8[] data) {
            int tail = int.max (0, data.length - 65536);
            if (Singularity.Pdf.Lexer.find (data, "Adobe.PubSec", tail) >= 0) return true;
            return Singularity.Pdf.Lexer.find (data, "Adobe.PubSec", 0) >= 0;
        }
    }
}
