using Singularity.Apps.Reader;

string dir;

void check (bool condition, string what) {
    if (!condition) {
        printerr ("FAIL: %s\n", what);
        Process.exit (1);
    }
    print ("ok %s\n", what);
}

string sh (string command) {
    string out_text, err_text;
    int status;
    try {
        Process.spawn_sync (dir, { "sh", "-c", command }, null, SpawnFlags.SEARCH_PATH, null, out out_text, out err_text, out status);
    } catch (Error e) {
        printerr ("FAIL: %s\n", e.message);
        Process.exit (1);
    }
    if (status != 0) printerr ("command %s: %s\n", command, err_text);
    return out_text + err_text;
}

string path (string name) {
    return Path.build_filename (dir, name);
}

void make_pki () throws FileError {
    sh ("openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 30 -subj '/CN=Test Root CA' -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign");
    sh ("openssl req -newkey rsa:2048 -nodes -keyout signer.key -out signer.csr -subj '/CN=Mario Rossi/O=Example'");
    FileUtils.set_contents (path ("signer.ext"), "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,nonRepudiation\n");
    sh ("openssl x509 -req -in signer.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out signer.crt -days 30 -extfile signer.ext");
    sh ("openssl pkcs12 -export -inkey signer.key -in signer.crt -certfile ca.crt -out signer.p12 -passout pass:secret");
    sh ("openssl req -newkey rsa:2048 -nodes -keyout tsa.key -out tsa.csr -subj '/CN=Test TSA'");
    FileUtils.set_contents (path ("tsa.ext"), "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,timeStamping\n");
    sh ("openssl x509 -req -in tsa.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out tsa.crt -days 30 -extfile tsa.ext");
    FileUtils.set_contents (path ("tsaserial"), "01\n");
    FileUtils.set_contents (path ("ts.cnf"), "[ tsa ]\ndefault_tsa = tsa_config1\n[ tsa_config1 ]\nserial = %s\ndefault_policy = 1.2.3.4.1\ndigests = sha256\naccuracy = secs:1\nordering = yes\ntsa_name = no\ness_cert_id_chain = no\ness_cert_id_alg = sha256\nsigner_digest = sha256\n".printf (path ("tsaserial")));
}

string sample () {
    string p = path ("sample.pdf");
    var surface = new Cairo.PdfSurface (p, 595, 842);
    var cr = new Cairo.Context (surface);
    cr.select_font_face ("sans-serif", Cairo.FontSlant.NORMAL, Cairo.FontWeight.NORMAL);
    cr.set_font_size (14);
    cr.move_to (60, 90);
    cr.show_text ("Contract to be signed");
    cr.show_page ();
    surface.finish ();
    return p;
}

uint8[] local_tsa (uint8[] request) throws Error {
    FileUtils.set_data (path ("req.tsq"), request);
    FileUtils.remove (path ("resp.tsr"));
    sh ("openssl ts -reply -queryfile req.tsq -config ts.cnf -inkey tsa.key -signer tsa.crt -out resp.tsr");
    uint8[] data;
    FileUtils.get_data (path ("resp.tsr"), out data);
    return data;
}

Singularity.Pdf.SignatureRequest request () {
    var req = new Singularity.Pdf.SignatureRequest ();
    req.page = 0;
    req.rect = Singularity.Pdf.Rect.of (300, 60, 540, 130);
    req.reason = "Approval";
    req.location = "Milano";
    return req;
}

int main (string[] args) {
    try {
        dir = DirUtils.make_tmp ("reader-signing-XXXXXX");
    } catch (Error e) {
        return 1;
    }
    Environment.set_variable ("XDG_DATA_HOME", path ("data"), true);
    string pdf = sample ();
    try {
        make_pki ();
        bool refused = false;
        try {
            SigningNative.SignKey.pkcs12 (path ("signer.p12"), "wrong");
        } catch (Error e) {
            refused = true;
        }
        check (refused, "wrong PKCS#12 password refused");
        var key = SigningNative.SignKey.pkcs12 (path ("signer.p12"), "secret");
        check (key.subject () == "Mario Rossi", "PKCS#12 key and certificate loaded");

        var signed = DigitalSigner.sign_with (Singularity.Pdf.Document.open_file (pdf), request (), key, null);
        FileUtils.set_data (path ("signed.pdf"), signed);
        var statuses = DigitalSigner.verify (Singularity.Pdf.Document.open_bytes (signed), false);
        check (statuses.size == 1 && statuses[0].status == SignatureState.VALID_UNTRUSTED, "B-B signature valid, signer not yet trusted");
        check (statuses[0].signer == "Mario Rossi" && statuses[0].issuer == "Test Root CA" && statuses[0].covers_whole_file, "signer details");
        string oracle = sh ("pdfsig signed.pdf");
        print ("%s", oracle);
        check (oracle.contains ("Signature is Valid") && oracle.contains ("ETSI.CAdES.detached"), "pdfsig (poppler/NSS) validates the B-B signature");
        DigitalSigner.trust_certificate (path ("ca.crt"));
        statuses = DigitalSigner.verify (Singularity.Pdf.Document.open_bytes (signed), false);
        check (statuses[0].status == SignatureState.VALID_TRUSTED, "valid and trusted after adding the CA");

        var tampered = signed[0 : signed.length];
        tampered[12] = tampered[12] ^ 0x01;
        statuses = DigitalSigner.verify (Singularity.Pdf.Document.open_bytes (tampered), false);
        check (statuses[0].status == SignatureState.INVALID, "tampered byte detected");

        var later = Singularity.Pdf.Document.open_bytes (signed);
        Singularity.Pdf.Annotations.note (later, 0, 100, 700, "Seen", { 1, 0.8, 0 }, "Reviewer");
        var incr = new Singularity.Pdf.SaveOptions ();
        incr.mode = Singularity.Pdf.SaveMode.INCREMENTAL;
        var annotated = later.save (incr);
        statuses = DigitalSigner.verify (Singularity.Pdf.Document.open_bytes (annotated), false);
        check (statuses[0].status == SignatureState.MODIFIED_AFTER && statuses[0].only_annotations_after, "later comment reported as change after signing");

        var changed = Singularity.Pdf.Document.open_bytes (signed);
        Singularity.Pdf.Pages.rotate (changed, { 0 }, 90);
        changed.set_page_content (0, "BT /F1 12 Tf ET".data);
        var altered = changed.save (incr);
        statuses = DigitalSigner.verify (Singularity.Pdf.Document.open_bytes (altered), false);
        check (statuses[0].status == SignatureState.MODIFIED_AFTER && !statuses[0].only_annotations_after, "later content change reported");

        var stamped = DigitalSigner.sign_with (Singularity.Pdf.Document.open_file (pdf), request (), key, local_tsa);
        FileUtils.set_data (path ("stamped.pdf"), stamped);
        statuses = DigitalSigner.verify (Singularity.Pdf.Document.open_bytes (stamped), false);
        check (statuses[0].status == SignatureState.VALID_TRUSTED && statuses[0].timestamped && statuses[0].signing_time != null, "B-T signature with RFC 3161 token");
        string oracle2 = sh ("pdfsig stamped.pdf");
        check (oracle2.contains ("Signature is Valid"), "pdfsig validates the B-T signature");
        string tsverify = sh ("openssl ts -reply -in resp.tsr -text");
        check (tsverify.contains ("Status: Granted"), "local TSA response granted");

        var second = DigitalSigner.sign_with (Singularity.Pdf.Document.open_bytes (signed), request (), key, null);
        statuses = DigitalSigner.verify (Singularity.Pdf.Document.open_bytes (second), false);
        check (statuses.size == 2 && statuses[0].status == SignatureState.MODIFIED_AFTER && statuses[1].status == SignatureState.VALID_TRUSTED, "second signature keeps the first one intact");

        var dts = DigitalSigner.timestamp_document (Singularity.Pdf.Document.open_bytes (signed), local_tsa);
        FileUtils.set_data (path ("dts.pdf"), dts);
        statuses = DigitalSigner.verify (Singularity.Pdf.Document.open_bytes (dts), false);
        check (statuses.size == 2 && statuses[1].is_document_timestamp && statuses[1].integrity_ok, "document timestamp (ETSI.RFC3161)");

        var rev = DigitalSigner.check_ocsp (Singularity.Pdf.Document.open_bytes (signed).data[0 : 0]);
        check (rev == RevocationState.UNKNOWN, "no OCSP address gives unknown revocation state");
    } catch (Error e) {
        printerr ("FAIL: %s\n", e.message);
        return 1;
    }
    return 0;
}
