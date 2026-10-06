using Singularity.Apps.Reader;

string dir;

void check (bool condition, string what) {
    if (!condition) {
        printerr ("FAIL: %s\n", what);
        Process.exit (1);
    }
    print ("ok %s\n", what);
}

void run (string cmd) throws Error {
    int status;
    string output, errors;
    Process.spawn_command_line_sync (cmd, out output, out errors, out status);
    if (status != 0) throw new IOError.FAILED ("%s: %s", cmd, errors);
}

void make_identity (string name) throws Error {
    string b = Path.build_filename (dir, name);
    run ("openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=%s -keyout %s.key -out %s.pem".printf (name, b, b));
    run ("openssl pkcs12 -export -inkey %s.key -in %s.pem -out %s.p12 -passout pass:pw -certpbe AES-256-CBC -keypbe AES-256-CBC -macalg sha256".printf (b, b, b));
}

string sample () {
    string path = Path.build_filename (dir, "doc.pdf");
    var surface = new Cairo.PdfSurface (path, 595, 842);
    var cr = new Cairo.Context (surface);
    cr.select_font_face ("sans-serif", Cairo.FontSlant.NORMAL, Cairo.FontWeight.NORMAL);
    cr.set_font_size (16);
    cr.move_to (60, 100);
    cr.show_text ("Secret quarterly figures");
    cr.show_page ();
    surface.finish ();
    return path;
}

int main (string[] args) {
    dir = DirUtils.make_tmp ("cert-enc-XXXXXX");
    try {
        make_identity ("alice");
        make_identity ("bob");
        var doc = Singularity.Pdf.Document.open_file (sample ());
        var bytes = CertEncryption.encrypt_for (doc, { Path.build_filename (dir, "alice.pem") }, Singularity.Pdf.Permissions.PRINT | Singularity.Pdf.Permissions.COPY);
        string out_path = Path.build_filename (dir, "enc.pdf");
        FileUtils.set_data (out_path, bytes);
        check (CertEncryption.needs_certificate (bytes), "detects certificate encryption");
        CertEncryption.remove_unlocker ();
        bool refused = false;
        try {
            Singularity.Pdf.Document.open_bytes (bytes);
        } catch (Singularity.Pdf.PdfError e) {
            refused = e is Singularity.Pdf.PdfError.PASSWORD;
        }
        check (refused, "cannot open without a certificate");
        CertEncryption.install_unlocker (Path.build_filename (dir, "bob.p12"), "pw");
        refused = false;
        try {
            Singularity.Pdf.Document.open_bytes (bytes);
        } catch (Singularity.Pdf.PdfError e) {
            refused = e is Singularity.Pdf.PdfError.PASSWORD;
        }
        check (refused, "an unrelated certificate cannot open it");
        CertEncryption.install_unlocker (Path.build_filename (dir, "alice.p12"), "pw");
        var opened = Singularity.Pdf.Document.open_bytes (bytes);
        var it = new Singularity.Pdf.Interpreter (opened);
        it.run_page (0);
        check (it.page_text ().contains ("Secret quarterly figures"), "recipient reads the text");
        var opts = new Singularity.Pdf.SaveOptions ();
        opts.remove_security = true;
        var plain = Singularity.Pdf.Document.open_bytes (opened.save (opts));
        check (plain.security == null && plain.page_count () == 1, "decrypted copy is plain");
        var reopened = Singularity.Pdf.Document.open_bytes (bytes);
        var encrypt = reopened.resolve (reopened.trailer.get ("Encrypt"));
        var recipients = reopened.lookup (reopened.lookup (reopened.lookup (encrypt, "CF"), "DefaultCryptFilter"), "Recipients");
        string env_path = Path.build_filename (dir, "env.der");
        FileUtils.set_data (env_path, recipients.at (0).bytes);
        string out_content = Path.build_filename (dir, "content.bin");
        run ("openssl cms -decrypt -inform DER -in %s -recip %s/alice.pem -inkey %s/alice.key -out %s".printf (env_path, dir, dir, out_content));
        var key = SigningNative.SignKey.pkcs12 (Path.build_filename (dir, "alice.p12"), "pw");
        var content = SigningNative.envelope_decrypt (key, recipients.at (0).bytes).get_data ();
        uint8[] oracle;
        FileUtils.get_data (out_content, out oracle);
        bool same = oracle.length == 24 && content.length == 24;
        for (int i = 0; same && i < 24; i++) if (oracle[i] != content[i]) same = false;
        check (same, "openssl cms decrypts the same 24 bytes");
    } catch (Error e) {
        printerr ("FAIL: %s\n", e.message);
        return 1;
    }
    return 0;
}
