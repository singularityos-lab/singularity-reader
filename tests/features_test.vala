using Singularity.Apps.Reader;

string tmpdir;
int failures = 0;

void check (bool condition, string what) {
    if (!condition) {
        printerr ("FAIL: %s\n", what);
        failures++;
        return;
    }
    print ("ok %s\n", what);
}

string sample (string name, int pages = 3) {
    string path = Path.build_filename (tmpdir, name);
    var surface = new Cairo.PdfSurface (path, 595, 842);
    for (int p = 0; p < pages; p++) {
        var cr = new Cairo.Context (surface);
        cr.select_font_face ("sans-serif", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
        cr.set_font_size (22);
        cr.move_to (60, 90);
        cr.show_text ("Chapter %d".printf (p + 1));
        cr.select_font_face ("serif", Cairo.FontSlant.NORMAL, Cairo.FontWeight.NORMAL);
        cr.set_font_size (11);
        cr.move_to (60, 130);
        cr.show_text ("The parties agree to the terms below.");
        if (p == 0) {
            var img = new Cairo.ImageSurface (Cairo.Format.RGB24, 120, 80);
            var ic = new Cairo.Context (img);
            ic.set_source_rgb (0.2, 0.4, 0.8);
            ic.paint ();
            cr.set_source_surface (img, 60, 200);
            cr.paint ();
            cr.set_source_rgb (0, 0, 0);
            cr.set_line_width (1);
            cr.move_to (60, 500);
            cr.show_text ("Name");
            cr.move_to (110, 502);
            cr.line_to (330, 502);
            cr.stroke ();
            cr.rectangle (60, 540, 12, 12);
            cr.stroke ();
            cr.move_to (80, 551);
            cr.show_text ("I agree");
        }
        cr.show_page ();
    }
    surface.finish ();
    return path;
}

string scan_image (string name, double angle) {
    string path = Path.build_filename (tmpdir, name);
    var img = new Cairo.ImageSurface (Cairo.Format.RGB24, 1000, 1300);
    var cr = new Cairo.Context (img);
    cr.set_source_rgb (1, 1, 1);
    cr.paint ();
    cr.translate (500, 650);
    cr.rotate (angle * Math.PI / 180);
    cr.translate (-500, -650);
    cr.set_source_rgb (0, 0, 0);
    cr.select_font_face ("sans-serif", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
    cr.set_font_size (40);
    for (int i = 0; i < 12; i++) {
        cr.move_to (120, 180 + i * 80);
        cr.show_text ("SCANNED LINE OF TEXT NUMBER %d".printf (i + 1));
    }
    img.write_to_png (path);
    return path;
}

Poppler.Document poppler (uint8[] data, string? password = null) throws Error {
    return new Poppler.Document.from_bytes (new Bytes (data), password);
}

string page_text (Poppler.Document d, int i) {
    return d.get_page (i).get_text () ?? "";
}

void test_comments (string path) throws Error {
    var e = Singularity.Pdf.Document.open_file (path);
    Singularity.Pdf.Rect[] line = { Singularity.Pdf.Rect.of (60, 705, 260, 718) };
    Singularity.Pdf.Annotations.markup (e, 0, "Highlight", line, { 1, 1, 0 }, 1, "Anna", "Check this");
    Singularity.Pdf.Annotations.markup (e, 0, "Underline", line, { 0, 0, 1 }, 1, "Anna", "");
    Singularity.Pdf.Annotations.markup (e, 0, "StrikeOut", line, { 1, 0, 0 }, 1, "Anna", "");
    var note = Singularity.Pdf.Annotations.note (e, 0, 400, 700, "Is the date right?", { 1, 0.8, 0 }, "Anna");
    Singularity.Pdf.Annotations.reply (e, 0, note, "Yes, it is.", "Luca");
    var pd = poppler (e.save ());
    int hl = 0, ul = 0, so = 0, text = 0;
    foreach (var m in pd.get_page (0).get_annot_mapping ()) {
        var t = m.annot.get_annot_type ();
        if (t == Poppler.AnnotType.HIGHLIGHT) hl++;
        if (t == Poppler.AnnotType.UNDERLINE) ul++;
        if (t == Poppler.AnnotType.STRIKE_OUT) so++;
        if (t == Poppler.AnnotType.TEXT) text++;
    }
    check (hl == 1 && ul == 1 && so == 1 && text == 2, "poppler sees highlight, underline, strike-out, note and reply");
    int replies = 0;
    foreach (var a in Singularity.Pdf.Annotations.list (e, 0)) if (a.reply_to > 0 && a.contents == "Yes, it is.") replies++;
    check (replies == 1, "reply is threaded to its note");

    string xfdf = Singularity.Pdf.Annotations.export_xfdf (e, "sample.pdf");
    uint8[] fdf = Singularity.Pdf.Annotations.export_fdf (e, "sample.pdf");
    var fresh = Singularity.Pdf.Document.open_file (path);
    int imported = Singularity.Pdf.Annotations.import_xfdf (fresh, xfdf);
    var fresh2 = Singularity.Pdf.Document.open_file (path);
    int imported2 = Singularity.Pdf.Annotations.import_fdf (fresh2, fdf);
    check (imported == 5 && imported2 == 5 && Singularity.Pdf.Annotations.list (fresh, 0).size == 5,
        "comments exported to XFDF and FDF and imported back (%d, %d)".printf (imported, imported2));
}

void test_text_and_links (string path) throws Error {
    var e = Singularity.Pdf.Document.open_file (path);
    int annots_before = Singularity.Pdf.Annotations.list (e, 1).size;
    Singularity.Pdf.Editor.add_text (e, 1, 60, 300, "Added paragraph on page two", "sans-serif", 14, { 0, 0, 0 });
    Singularity.Pdf.Annotations.link (e, 1, Singularity.Pdf.Rect.of (60, 400, 200, 420), "https://example.com/", -1, 0);
    Singularity.Pdf.Annotations.link (e, 1, Singularity.Pdf.Rect.of (60, 440, 200, 460), null, 2, 800);
    var pd = poppler (e.save ());
    check (page_text (pd, 1).contains ("Added paragraph on page two"), "added text is page content visible to poppler");
    int uri = 0, dest = 0;
    foreach (var m in pd.get_page (1).get_link_mapping ()) {
        if (m.action.type == Poppler.ActionType.URI) uri++;
        if (m.action.type == Poppler.ActionType.GOTO_DEST) dest++;
    }
    check (uri == 1 && dest == 1, "links to a URL and to page three");
    check (Singularity.Pdf.Annotations.list (e, 1).size == annots_before + 2, "only the two links are annotations, the text is not");
}

void test_font_substitution (string path) throws Error {
    var e = Singularity.Pdf.Document.open_file (path);
    var blocks = Singularity.Pdf.Editor.blocks (e, 0);
    Singularity.Pdf.TextBlock? target = null;
    foreach (var b in blocks) if (b.text ().contains ("parties")) target = b;
    check (target != null, "text block found for substitution");
    if (target == null) return;
    var r = Singularity.Pdf.Editor.replace_block (e, 0, target, "Prices in € with Ünïcödé glyphs.");
    var pd = poppler (e.save ());
    check (page_text (pd, 0).contains ("€") && page_text (pd, 0).contains ("Ünïcödé"),
        "glyphs missing from the subset are drawn with a substitute (%s, substituted %s)".printf (r.font_family, r.substituted.to_string ()));
}

void test_images (string path) throws Error {
    var e = Singularity.Pdf.Document.open_file (path);
    var list = Singularity.Pdf.Images.list (e, 0);
    check (list.size == 1, "one image on page one");
    if (list.size == 0) return;
    bool moved = Singularity.Pdf.Editor.move_image (e, 0, list[0], Singularity.Pdf.Rect.of (300, 300, 500, 450));
    var pd = poppler (e.save ());
    var area = pd.get_page (0).get_image_mapping ().data.area;
    check (moved && area.x1 > 290 && area.x1 < 310, "image moved to the new box (x %.0f)".printf (area.x1));
    var pixbuf = new Gdk.Pixbuf (Gdk.Colorspace.RGB, false, 8, 40, 40);
    pixbuf.fill ((uint32) 0xff0000ffU);
    var replacement = Singularity.Pdf.Images.pixbuf_xobject (e, pixbuf);
    var again = Singularity.Pdf.Images.list (e, 0);
    bool replaced = Singularity.Pdf.Editor.replace_image (e, 0, again[0], replacement);
    var pd2 = poppler (e.save ());
    var surface = (Cairo.ImageSurface) pd2.get_page (0).get_image (pd2.get_page (0).get_image_mapping ().data.image_id);
    check (replaced && surface.get_width () == 40, "image replaced (width %d)".printf (surface.get_width ()));
}

void test_header_footer (string path) throws Error {
    var e = Singularity.Pdf.Document.open_file (path);
    var hf = new Singularity.Pdf.HeaderFooter ();
    hf.top_left = "Contract <<file>>";
    hf.bottom_right = "<<bates>>";
    hf.bottom_center = "<<page>>/<<pages>>";
    hf.bates_prefix = "ACME";
    hf.bates_digits = 6;
    hf.bates_start = 41;
    hf.file_name = "contract.pdf";
    int stamped = Singularity.Pdf.Stamps.apply_header_footer (e, hf);
    var pd = poppler (e.save ());
    string t3 = page_text (pd, 2).replace (" ", "");
    check (stamped == 3 && page_text (pd, 0).contains ("ACME000041") && t3.contains ("ACME000043") && t3.contains ("3/3") && page_text (pd, 1).contains ("contract"),
        "header, page numbers and Bates numbers ACME000041 to ACME000043");
}

void test_background (string path) throws Error {
    var e = Singularity.Pdf.Document.open_file (path);
    var wm = new Singularity.Pdf.Watermark ();
    wm.text = "DRAFT";
    wm.behind = true;
    wm.opacity = 0.3;
    wm.rotation = 45;
    wm.size = 80;
    wm.color = { 1, 0, 0 };
    int n = Singularity.Pdf.Stamps.apply_watermark (e, wm);
    var data = e.save ();
    var pd = poppler (data);
    string content = (string) Singularity.Pdf.Document.open_bytes (data).page_content (0);
    int mark = content.index_of ("/Watermark");
    int text = content.index_of ("BT");
    int red = 0;
    for (int i = 0; i < 3; i++) {
        var img = new Cairo.ImageSurface (Cairo.Format.RGB24, 298, 421);
        var cr = new Cairo.Context (img);
        cr.set_source_rgb (1, 1, 1);
        cr.paint ();
        cr.scale (0.5, 0.5);
        pd.get_page (i).render (cr);
        img.flush ();
        unowned uint8[] px = img.get_data ();
        int count = 0;
        for (int k = 0; k + 3 < 298 * 421 * 4; k += 4) if (px[k + 2] > 200 && px[k + 1] < 200 && px[k] < 200) count++;
        if (count > 200) red++;
    }
    check (n == 3 && red == 3, "translucent red watermark drawn on %d of 3 pages".printf (red));
    check (mark >= 0 && mark < text, "watermark drawn before the page text, so it sits behind it");
}

void test_pages (string path) throws Error {
    var e = Singularity.Pdf.Document.open_file (path);
    Singularity.Pdf.Pages.move (e, 2, 0);
    Singularity.Pdf.Pages.duplicate (e, 0);
    Singularity.Pdf.Pages.insert_blank (e, 4, 595, 842);
    Singularity.Pdf.Pages.crop (e, { 3 }, 50, 100, 50, 100);
    var pd = poppler (e.save ());
    double w, h;
    pd.get_page (3).get_size (out w, out h);
    check (pd.get_n_pages () == 5 && page_text (pd, 0).contains ("Chapter 3") && page_text (pd, 1).contains ("Chapter 3")
        && page_text (pd, 2).contains ("Chapter 1") && page_text (pd, 4).strip () == "",
        "pages moved, duplicated and a blank page inserted (%d: %s | %s | %s | %s)".printf (pd.get_n_pages (), page_text (pd, 0).split ("\n")[0], page_text (pd, 1).split ("\n")[0], page_text (pd, 2).split ("\n")[0], page_text (pd, 4).strip ()));
    check ((int) w == 495 && (int) h == 642, "page cropped to %.0fx%.0f".printf (w, h));
}

void test_scans () throws Error {
    string tilted = scan_image ("tilted.png", 3.0);
    string straight = scan_image ("straight.png", 0);
    var pb = new Gdk.Pixbuf.from_file (tilted);
    double angle = Singularity.Pdf.Scans.skew_angle (pb);
    check (angle.abs () > 2.0 && angle.abs () < 4.0, "skew of a 3 degree scan measured as %.2f".printf (angle));
    var doc = Singularity.Pdf.Scans.from_images ({ tilted, straight });
    check (doc.page_count () == 2 && Singularity.Pdf.Scans.is_scanned (doc, 0), "PDF created from two images");
    var opts = new Singularity.Pdf.ScanOptions ();
    opts.deskew = true;
    opts.whiten = true;
    opts.remove_borders = true;
    double fixed_angle = Singularity.Pdf.Scans.clean_page (doc, 0, opts);
    var info = Singularity.Pdf.Scans.main_image (doc, 0);
    var cleaned = Singularity.Pdf.Images.decode (doc, info.xobject);
    double after = Singularity.Pdf.Scans.skew_angle (cleaned);
    check (after.abs () < 0.6, "page straightened by %.2f degrees, remaining skew %.2f".printf (fixed_angle, after));
}

void test_forms (string path) throws Error {
    var e = Singularity.Pdf.Document.open_file (path);
    var detected = Singularity.Pdf.Forms.detect (e, 0);
    int text_fields = 0, boxes = 0;
    foreach (var d in detected) {
        if (d.type == Singularity.Pdf.FieldType.TEXT) text_fields++;
        if (d.type == Singularity.Pdf.FieldType.CHECKBOX) boxes++;
    }
    check (text_fields >= 1 && boxes >= 1, "detected %d text line and %d check box on the page".printf (text_fields, boxes));

    var a = Singularity.Pdf.Forms.create_field (e, 0, Singularity.Pdf.FieldType.TEXT, "Price", Singularity.Pdf.Rect.of (60, 600, 160, 620));
    var b = Singularity.Pdf.Forms.create_field (e, 0, Singularity.Pdf.FieldType.TEXT, "Shipping", Singularity.Pdf.Rect.of (60, 630, 160, 650));
    var total = Singularity.Pdf.Forms.create_field (e, 0, Singularity.Pdf.FieldType.TEXT, "Total", Singularity.Pdf.Rect.of (60, 660, 160, 680));
    Singularity.Pdf.Forms.set_script (e, total, "C", "AFSimple_Calculate(\"SUM\", new Array (\"Price\", \"Shipping\"));");
    Singularity.Pdf.Forms.set_script (e, total, "F", "AFNumber_Format(2, 0, 0, 0, \"€ \", true);");
    var values = new Gee.HashMap<string, string> ();
    values["Price"] = "120.5";
    values["Shipping"] = "9.5";
    Singularity.Pdf.Forms.import_values (e, values);
    Singularity.Pdf.Forms.recalculate (e);
    var found = Singularity.Pdf.Forms.find (e, "Total");
    string shown = Singularity.Pdf.Forms.display_value (found, found.value);
    check (found.value == "130" || found.value == "130.00", "calculation script sums the fields (%s)".printf (found.value));
    check (shown.contains ("130") && shown.contains ("€"), "format script shows %s".printf (shown));
    string message;
    Singularity.Pdf.Forms.set_script (e, a, "V", "AFRange_Validate(true, 0, true, 1000);");
    var price = Singularity.Pdf.Forms.find (e, "Price");
    bool valid = Singularity.Pdf.Forms.validate (price, "5000", out message);
    check (!valid, "validation script rejects 5000 (%s)".printf (message));

    string csv = Singularity.Pdf.Forms.export_csv (e);
    var other = Singularity.Pdf.Document.open_file (path);
    Singularity.Pdf.Forms.create_field (other, 0, Singularity.Pdf.FieldType.TEXT, "Price", Singularity.Pdf.Rect.of (60, 600, 160, 620));
    Singularity.Pdf.Forms.create_field (other, 0, Singularity.Pdf.FieldType.TEXT, "Shipping", Singularity.Pdf.Rect.of (60, 630, 160, 650));
    int imported = Singularity.Pdf.Forms.import_csv (other, csv);
    string xfdf = Singularity.Pdf.Forms.xfdf_fields (e);
    var fdf = Singularity.Pdf.Forms.fdf_fields (e);
    check (imported >= 2 && Singularity.Pdf.Forms.find (other, "Price").value == "120.5" && xfdf.contains ("Price") && fdf != null,
        "form data exported to CSV, XFDF and FDF and imported from CSV");
    var pd = poppler (e.save ());
    string total_seen = "";
    foreach (var m in pd.get_page (0).get_form_field_mapping ()) if (m.field.get_name () == "Total") total_seen = m.field.text_get_text () ?? "";
    check (total_seen.contains ("130"), "poppler reads the calculated total %s".printf (total_seen));
}


void test_xfa (string path) throws Error {
    var e = Singularity.Pdf.Document.open_file (path);
    Singularity.Pdf.Forms.create_field (e, 0, Singularity.Pdf.FieldType.TEXT, "Company", Singularity.Pdf.Rect.of (60, 600, 260, 620));
    var af = Singularity.Pdf.Forms.ensure_acroform (e);
    string xml = "<xdp:xdp xmlns:xdp=\"http://ns.adobe.com/xdp/\"><xfa:datasets xmlns:xfa=\"http://www.xfa.org/schema/xfa-data/1.0/\"><xfa:data><form><Company>Rossi S.p.A.</Company></form></xfa:data></xfa:datasets></xdp:xdp>";
    var stream = e.make_stream (xml.data, false);
    af.set ("XFA", e.add_ref (stream));
    check (Singularity.Pdf.Forms.has_xfa (e), "static XFA form recognised");
    int applied = Singularity.Pdf.Forms.apply_xfa_to_acroform (e);
    check (applied == 1 && Singularity.Pdf.Forms.find (e, "Company").value == "Rossi S.p.A.", "XFA data shown in the AcroForm field");
}

void test_outline (string path) throws Error {
    var e = Singularity.Pdf.Document.open_file (path);
    var items = new Gee.ArrayList<Singularity.Pdf.OutlineItem> ();
    for (int i = 0; i < 3; i++) {
        var item = new Singularity.Pdf.OutlineItem ();
        item.title = "Chapter %d".printf (i + 1);
        item.page = i;
        item.top = 800;
        item.children = new Gee.ArrayList<Singularity.Pdf.OutlineItem> ();
        items.add (item);
    }
    Singularity.Pdf.Outline.write (e, items);
    var data = e.save ();
    var back = Singularity.Pdf.Outline.read (Singularity.Pdf.Document.open_bytes (data));
    var iter = new Poppler.IndexIter (poppler (data));
    int seen = 0;
    if (iter != null) do { seen++; } while (iter.next ());
    check (back.size == 3 && back[2].title == "Chapter 3" && back[2].page == 2 && seen == 3, "bookmarks written and read back, poppler lists %d".printf (seen));
}

void test_recovery (string path) throws Error {
    Environment.set_variable ("XDG_STATE_HOME", Path.build_filename (tmpdir, "state"), true);
    var doc = new ReaderDocument (File.new_for_path (path), null);
    doc.open_engine ();
    doc.modified = true;
    var recovery = new Recovery ();
    recovery.schedule (doc);
    var loop = new MainLoop ();
    Timeout.add_seconds (5, () => {
        loop.quit ();
        return Source.REMOVE;
    });
    loop.run ();
    string dir = Path.build_filename (tmpdir, "state", "singularity-reader", "recovery");
    int copies = 0;
    try {
        var d = Dir.open (dir);
        string? n;
        while ((n = d.read_name ()) != null) if (n.has_suffix (".pdf")) copies++;
    } catch (Error err) {
    }
    uint8[] original;
    FileUtils.get_data (path, out original);
    check (copies == 1, "unsaved changes copied to a separate recovery file");
    recovery.discard (doc.file);
    int left = 0;
    try {
        var d = Dir.open (dir);
        string? n;
        while ((n = d.read_name ()) != null) left++;
    } catch (Error err) {
    }
    check (left == 0 && poppler (original).get_n_pages () == 3, "recovery copy removed after saving, original untouched");
}

void test_split (string path) throws Error {
    var e = Singularity.Pdf.Document.open_file (path);
    var items = new Gee.ArrayList<Singularity.Pdf.OutlineItem> ();
    foreach (int page in new int[] { 0, 2, 4 }) {
        var item = new Singularity.Pdf.OutlineItem ();
        item.title = "Part %d".printf (page / 2 + 1);
        item.page = page;
        item.top = 800;
        item.children = new Gee.ArrayList<Singularity.Pdf.OutlineItem> ();
        items.add (item);
    }
    Singularity.Pdf.Outline.write (e, items);
    var outlined = Singularity.Pdf.Document.open_bytes (e.save ());
    string[] titles;
    var parts = Singularity.Pdf.Pages.split_by_outline (outlined, out titles);
    int[] counts = {};
    foreach (var part in parts) counts += poppler (part.save ()).get_n_pages ();
    check (parts.size == 3 && titles[1] == "Part 2" && counts[0] == 2 && counts[1] == 2 && counts[2] == 2,
        "split at the bookmarks into %d files named after them".printf (parts.size));
    var opts = new Singularity.Pdf.SaveOptions ();
    opts.garbage_collect = true;
    int64 limit = Singularity.Pdf.Pages.extract (outlined, { 0, 1, 2 }).save (opts).length + 64;
    var sized = Singularity.Pdf.Pages.split_by_size (outlined, limit);
    bool under = true;
    int total = 0;
    foreach (var part in sized) {
        var data = part.save (opts);
        if (data.length > limit) under = false;
        total += poppler (data).get_n_pages ();
    }
    check (sized.size >= 2 && under && total == 6, "split by size into %d files under %lld bytes, 6 pages kept".printf (sized.size, limit));
}

void test_resize (string path) throws Error {
    var e = Singularity.Pdf.Document.open_file (path);
    Singularity.Pdf.Pages.resize (e, { 0 }, 420, 595, true);
    var pd = poppler (e.save ());
    double w, h;
    pd.get_page (0).get_size (out w, out h);
    var page = pd.get_page (0);
    var found = page.find_text ("Chapter 1");
    bool inside = found.length () == 1 && found.data.x2 < 420 && found.data.y2 < 595;
    double w2, h2;
    pd.get_page (1).get_size (out w2, out h2);
    check ((int) w == 420 && (int) h == 595 && inside && (int) w2 == 595, "page fitted to A5 with its content scaled inside, other pages untouched");
}

void test_batch () throws Error {
    string input = Path.build_filename (tmpdir, "batch-in");
    string output = Path.build_filename (tmpdir, "batch-out");
    DirUtils.create_with_parents (input, 0755);
    DirUtils.create_with_parents (output, 0755);
    foreach (string name in new string[] { "a.pdf", "b.pdf" }) {
        string src = sample ("batch-" + name, 2);
        FileUtils.rename (src, Path.build_filename (input, name));
    }
    int done = 0;
    var dir = Dir.open (input);
    string? name;
    while ((name = dir.read_name ()) != null) {
        uint8[] data;
        FileUtils.get_data (Path.build_filename (input, name), out data);
        data = Operations.sanitize (data, "");
        data = Operations.number_pages (data, "", name);
        data = Operations.watermark (data, "", "DRAFT");
        data = Operations.tag (data, "", "en");
        int remaining;
        data = Operations.pdfa (data, "", "2b", out remaining);
        data = Operations.optimize (data, "", 150, 75);
        data = Operations.protect (data, "", "secret");
        FileUtils.set_data (Path.build_filename (output, name), data);
        done++;
    }
    int good = 0;
    foreach (string n in new string[] { "a.pdf", "b.pdf" }) {
        uint8[] data;
        FileUtils.get_data (Path.build_filename (output, n), out data);
        bool locked = false;
        try {
            poppler (data);
        } catch (Error err) {
            locked = true;
        }
        var pd = poppler (data, "secret");
        string t = page_text (pd, 1).replace ("\n", "");
        if (locked && pd.get_n_pages () == 2 && t.contains ("DRAFT") && t.contains ("2/2")) good++;
    }
    check (done == 2 && good == 2, "batch steps applied to both files of the folder: watermark, numbers, PDF/A, optimize, password");
}

void test_read_aloud (string path) throws Error {
    string synth = Path.build_filename (tmpdir, "espeak-ng");
    string spoken = Path.build_filename (tmpdir, "spoken.txt");
    FileUtils.set_contents (synth, "#!/bin/sh\ncat > '%s'\n".printf (spoken));
    FileUtils.chmod (synth, 0755);
    Environment.set_variable ("SINGULARITY_TTS", synth, true);
    var doc = new ReaderDocument (File.new_for_path (path), null);
    ReadAloud.speak (doc.text (1));
    var loop = new MainLoop ();
    Timeout.add (100, () => {
        if (!ReadAloud.speaking) {
            loop.quit ();
            return Source.REMOVE;
        }
        return Source.CONTINUE;
    });
    loop.run ();
    string heard;
    FileUtils.get_contents (spoken, out heard);
    check (heard.contains ("Chapter 2") && heard.contains ("The parties agree"), "page two text handed to the speech synthesizer");
}

int main (string[] args) {
    Intl.setlocale ();
    tmpdir = DirUtils.make_tmp ("reader-features-XXXXXX");
    try {
        test_comments (sample ("comments.pdf"));
        test_text_and_links (sample ("links.pdf"));
        test_font_substitution (sample ("font.pdf"));
        test_images (sample ("images.pdf"));
        test_header_footer (sample ("header.pdf"));
        test_background (sample ("background.pdf"));
        test_pages (sample ("pages.pdf"));
        test_scans ();
        test_forms (sample ("forms.pdf"));
        test_xfa (sample ("xfa.pdf"));
        test_outline (sample ("outline.pdf"));
        test_recovery (sample ("recovery.pdf"));
        test_split (sample ("split.pdf", 6));
        test_resize (sample ("resize.pdf"));
        test_batch ();
        test_read_aloud (sample ("aloud.pdf"));
    } catch (Error e) {
        printerr ("FAIL: %s\n", e.message);
        return 1;
    }
    return failures == 0 ? 0 : 1;
}
