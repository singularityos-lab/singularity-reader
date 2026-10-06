using Singularity.Apps.Reader;

string tmpdir;

void check (bool condition, string what) {
    if (!condition) {
        printerr ("FAIL: %s\n", what);
        Process.exit (1);
    }
    print ("ok %s\n", what);
}

string sample (string name) {
    string path = Path.build_filename (tmpdir, name);
    var surface = new Cairo.PdfSurface (path, 595, 842);
    for (int p = 0; p < 2; p++) {
        var cr = new Cairo.Context (surface);
        cr.select_font_face ("sans-serif", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
        cr.set_font_size (22);
        cr.move_to (60, 90);
        cr.show_text ("Contract page %d".printf (p + 1));
        cr.select_font_face ("serif", Cairo.FontSlant.NORMAL, Cairo.FontWeight.NORMAL);
        cr.set_font_size (11);
        cr.move_to (60, 130);
        cr.show_text ("Customer email mario.rossi@example.com, card 4417 1234 5678 9113.");
        cr.move_to (60, 150);
        cr.show_text ("The parties agree to the terms below.");
        cr.move_to (60, 400);
        cr.line_to (300, 400);
        cr.set_line_width (0.8);
        cr.stroke ();
        cr.show_page ();
    }
    surface.finish ();
    return path;
}

Poppler.Document poppler (uint8[] data, string? password = null) throws Error {
    return new Poppler.Document.from_bytes (new Bytes (data), password);
}

string all_text (Poppler.Document d) {
    var s = new StringBuilder ();
    for (int i = 0; i < d.get_n_pages (); i++) s.append (d.get_page (i).get_text () ?? "");
    return s.str;
}

void test_annotations (string path) throws Error {
    var e = Singularity.Pdf.Document.open_file (path);
    Singularity.Pdf.Annotations.shape (e, 0, Singularity.Pdf.ShapeKind.RECTANGLE, { 100, 100, 200, 160 }, { 1, 0, 0 }, null, 2, 1, "Tester", "Look");
    Singularity.Pdf.Annotations.shape (e, 0, Singularity.Pdf.ShapeKind.CLOUD, { 300, 300, 400, 300, 400, 380 }, { 0, 0, 1 }, null, 1, 1, "Tester", "");
    Singularity.Pdf.Annotations.stamp (e, 0, Singularity.Pdf.Rect.of (350, 700, 500, 750), "Approved", { 0, 0.5, 0 }, "Tester");
    var opts = new Singularity.Pdf.SaveOptions ();
    opts.mode = Singularity.Pdf.SaveMode.INCREMENTAL;
    var pd = poppler (e.save (opts));
    int squares = 0, polygons = 0, stamps = 0;
    foreach (var m in pd.get_page (0).get_annot_mapping ()) {
        var t = m.annot.get_annot_type ();
        if (t == Poppler.AnnotType.SQUARE) squares++;
        if (t == Poppler.AnnotType.POLYGON) polygons++;
        if (t == Poppler.AnnotType.STAMP) stamps++;
    }
    check (squares == 1 && polygons == 1 && stamps == 1, "poppler sees shapes and stamp");
}

void test_forms (string path) throws Error {
    var e = Singularity.Pdf.Document.open_file (path);
    Singularity.Pdf.Forms.create_field (e, 0, Singularity.Pdf.FieldType.TEXT, "Name", Singularity.Pdf.Rect.of (60, 600, 260, 620));
    Singularity.Pdf.Forms.create_field (e, 0, Singularity.Pdf.FieldType.CHECKBOX, "Agree", Singularity.Pdf.Rect.of (300, 600, 314, 614));
    var values = new Gee.HashMap<string, string> ();
    values["Name"] = "Anna Bianchi";
    values["Agree"] = "true";
    Singularity.Pdf.Forms.import_values (e, values);
    var pd = poppler (e.save ());
    string name = "";
    bool agree = false;
    foreach (var m in pd.get_page (0).get_form_field_mapping ()) {
        var f = m.field;
        if (f.get_field_type () == Poppler.FormFieldType.TEXT) name = f.text_get_text () ?? "";
        if (f.get_field_type () == Poppler.FormFieldType.BUTTON) agree = f.button_get_state ();
    }
    check (name == "Anna Bianchi" && agree, "poppler reads filled fields");
}

void test_redaction (string path) throws Error {
    int count;
    uint8[] data;
    FileUtils.get_data (path, out data);
    var out_data = Operations.redact_pattern (data, "", "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", out count);
    string text = all_text (poppler (out_data));
    check (count == 2 && !text.contains ("mario.rossi") && text.contains ("The parties agree"), "poppler confirms redaction");
}

void test_security (string path) throws Error {
    uint8[] data;
    FileUtils.get_data (path, out data);
    var enc = Operations.protect (data, "", "secret");
    bool refused = false;
    try {
        poppler (enc);
    } catch (Error e) {
        refused = true;
    }
    var pd = poppler (enc, "secret");
    check (refused && all_text (pd).contains ("Contract page 2"), "poppler opens AES-256 only with the password");
    var plain = Operations.unprotect (enc, "secret");
    check (all_text (poppler (plain)).contains ("Contract"), "protection removed");
}

void test_structure (string path) throws Error {
    uint8[] data;
    FileUtils.get_data (path, out data);
    var tagged = Operations.tag (data, "", "it-IT");
    var pd = poppler (tagged);
    var iter = new Poppler.StructureElementIter (pd);
    check (iter != null, "poppler reads the structure tree");
    var lin = Operations.linearize (tagged, "");
    check (poppler (lin).is_linearized (), "poppler reports linearized");
    int remaining;
    var pdfa = Operations.pdfa (data, "", "2b", out remaining);
    check (remaining == 0 && poppler (pdfa).get_n_pages () == 2, "pdf/a-2b conversion opens");
    var wm = Operations.watermark (data, "", "BOZZA");
    var wpage = poppler (wm).get_page (0);
    var wdoc = Singularity.Pdf.Document.open_bytes (wm);
    var it = new Singularity.Pdf.Interpreter (wdoc);
    it.run_page (0);
    bool found = false;
    foreach (var item in it.items) if (item.text () == "BOZZA") found = true;
    check (found && wpage.get_text ().replace ("\n", "").contains ("BO"), "watermark text present with its unicode map");
    var numbered = Operations.number_pages (data, "", "contract.pdf");
    check (poppler (numbered).get_page (1).get_text ().replace (" ", "").contains ("2/2"), "page numbers present");
}

void test_edit (string path) throws Error {
    var e = Singularity.Pdf.Document.open_file (path);
    var blocks = Singularity.Pdf.Editor.blocks (e, 0);
    Singularity.Pdf.TextBlock? target = null;
    foreach (var b in blocks) if (b.text ().contains ("parties")) target = b;
    check (target != null, "text block found");
    var r = Singularity.Pdf.Editor.replace_block (e, 0, target, "Both parties accept the revised terms.");
    var pd = poppler (e.save ());
    string text = pd.get_page (0).get_text ();
    check (text.contains ("Both parties accept the revised terms.") && !text.contains ("agree to the terms"), "edited text visible in poppler (%s)".printf (r.font_family));
    int w, h;
    string png = Path.build_filename (tmpdir, "pic.png");
    var pb = new Gdk.Pixbuf (Gdk.Colorspace.RGB, false, 8, 40, 30);
    pb.fill (0x3366ccff);
    pb.savev (png, "png", {}, {});
    var img = Singularity.Pdf.Images.from_file (e, png, out w, out h);
    Singularity.Pdf.Editor.add_image (e, 0, img, Singularity.Pdf.Rect.of (400, 500, 480, 560));
    var pd2 = poppler (e.save ());
    check (pd2.get_page (0).get_image_mapping ().length () >= 1, "added image visible in poppler");
}

async void test_ocr (string path, MainLoop loop) {
    try {
        string script = Path.build_filename (tmpdir, "fake-ocr.sh");
        FileUtils.set_contents (script, "#!/bin/sh\nprintf 'level\\tpage_num\\tblock_num\\tpar_num\\tline_num\\tword_num\\tleft\\ttop\\twidth\\theight\\tconf\\ttext\\n1\\t1\\t0\\t0\\t0\\t0\\t0\\t0\\t2480\\t3508\\t-1\\t\\n5\\t1\\t1\\t1\\t1\\t1\\t400\\t1400\\t420\\t90\\t96\\tSCANNED\\n5\\t1\\t1\\t1\\t1\\t2\\t860\\t1400\\t300\\t90\\t95\\tWORDS\\n'\n");
        FileUtils.chmod (script, 0755);
        string conf_dir = Path.build_filename (tmpdir, "config", "singularity");
        DirUtils.create_with_parents (conf_dir, 0700);
        FileUtils.set_contents (Path.build_filename (conf_dir, "text-recognition.conf"), "[Text Recognition]\nEngine=command\nCommand=%s %%f\n".printf (script));
        Environment.set_variable ("XDG_CONFIG_HOME", Path.build_filename (tmpdir, "config"), true);
        uint8[] data;
        FileUtils.get_data (path, out data);
        int words;
        var out_data = yield Operations.ocr (data, "", false, null, out words);
        string text = all_text (poppler (out_data));
        check (words == 4 && text.contains ("SCANNED WORDS"), "text layer from the recognizer is searchable in poppler");
    } catch (Error e) {
        printerr ("FAIL: ocr %s\n", e.message);
        Process.exit (1);
    }
    loop.quit ();
}

int main (string[] args) {
    tmpdir = DirUtils.make_tmp ("reader-pro-XXXXXX");
    try {
        string path = sample ("contract.pdf");
        test_annotations (path);
        test_forms (path);
        test_redaction (path);
        test_security (path);
        test_structure (path);
        test_edit (path);
        var loop = new MainLoop ();
        test_ocr.begin (path, loop);
        loop.run ();
        var summary = Summarizer.summarize ("First sentence talks about the contract terms. Second sentence is filler text here. The contract terms define payment and contract duration. Unrelated closing remark about weather today.", 2);
        check (summary.length == 2, "summary picks two sentences");
    } catch (Error e) {
        printerr ("FAIL: %s\n", e.message);
        return 1;
    }
    return 0;
}
