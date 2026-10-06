using Singularity.Apps.Reader;

string dir;

void check (bool condition, string what) {
    if (!condition) {
        printerr ("FAIL: %s\n", what);
        Process.exit (1);
    }
    print ("ok %s\n", what);
}

string make_sample () {
    string path = Path.build_filename (dir, "sample.pdf");
    var surface = new Cairo.PdfSurface (path, 595, 842);
    var cr = new Cairo.Context (surface);
    cr.select_font_face ("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
    cr.set_font_size (24);
    cr.move_to (60, 80);
    cr.show_text ("Annual Summary");
    cr.select_font_face ("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.NORMAL);
    cr.set_font_size (11);
    string[] para = { "Our company reached many goals this year and the results", "exceeded the expectations of the whole board of directors." };
    double y = 120;
    foreach (var line in para) {
        cr.move_to (60, y);
        cr.show_text (line);
        y += 14;
    }
    cr.select_font_face ("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
    cr.move_to (60, y + 10);
    cr.show_text ("Important note");
    cr.select_font_face ("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.NORMAL);
    string[,] table = {
        { "Item", "Quantity", "Price" },
        { "Apples", "12", "1,234.50" },
        { "Pears", "7", "3.25" },
        { "Plums", "30", "0.99" }
    };
    for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 3; c++) {
            cr.move_to (60 + c * 140, 220 + r * 18);
            cr.show_text (table[r, c]);
        }
    }
    var img = new Cairo.ImageSurface (Cairo.Format.RGB24, 40, 30);
    var ic = new Cairo.Context (img);
    ic.set_source_rgb (0.9, 0.3, 0.1);
    ic.paint ();
    cr.set_source_surface (img, 60, 330);
    cr.paint ();
    cr.set_source_rgb (0, 0, 0);
    cr.move_to (60, 420);
    cr.show_text ("Text after the picture.");
    cr.show_page ();
    cr.move_to (60, 80);
    cr.show_text ("Second page paragraph.");
    cr.show_page ();
    surface.finish ();
    return path;
}

bool well_formed (string xml) {
    var parser = MarkupParser () {};
    var ctx = new MarkupParseContext (parser, 0, null, null);
    try {
        ctx.parse (xml, -1);
        ctx.end_parse ();
        return true;
    } catch (Error e) {
        printerr ("xml: %s\n", e.message);
        return false;
    }
}

ZipReader zip_of (string name) throws Error {
    uint8[] data;
    FileUtils.get_data (Path.build_filename (dir, name), out data);
    return new ZipReader (data);
}

bool unzip_ok (string name) {
    string? unzip = Environment.find_program_in_path ("unzip");
    if (unzip == null) return true;
    int status;
    try {
        Process.spawn_sync (null, { unzip, "-tq", Path.build_filename (dir, name) }, null, 0, null, null, null, out status);
    } catch (Error e) {
        return false;
    }
    return status == 0;
}

int main (string[] args) {
    dir = DirUtils.make_tmp ("reader-export-XXXXXX");
    try {
        string path = make_sample ();
        var doc = new Poppler.Document.from_file (File.new_for_path (path).get_uri (), null);
        foreach (var format in Exporter.formats ()) {
            string name = "out." + Exporter.extension (format);
            Exporter.export (doc, format, File.new_for_path (Path.build_filename (dir, name)));
            check (Exporter.label (format) != "", "label " + format);
        }
        var docx = zip_of ("out.docx");
        string d = docx.read_text ("word/document.xml");
        check (well_formed (d), "docx document.xml well formed");
        check (d.contains ("exceeded the expectations"), "docx paragraph text");
        check (d.contains ("<w:tbl>") && d.contains ("Apples") && d.contains ("1,234.50"), "docx table");
        check (d.contains ("Heading1"), "docx heading style");
        check (d.contains ("<w:b/>"), "docx bold run");
        check (d.contains ("w:type=\"page\""), "docx page break");
        check (docx.has ("word/media/image1.png") && d.contains ("r:embed=\"rIdImg1\""), "docx picture");
        check (d.index_of ("Apples") < d.index_of ("rIdImg1") && d.index_of ("rIdImg1") < d.index_of ("after the picture"), "docx reading order");
        check (well_formed (docx.read_text ("word/styles.xml")) && well_formed (docx.read_text ("[Content_Types].xml")), "docx parts well formed");
        var odt = zip_of ("out.odt");
        check (odt.names ()[0] == "mimetype", "odt mimetype first");
        string oc = odt.read_text ("content.xml");
        check (well_formed (oc) && oc.contains ("<table:table ") && oc.contains ("text:outline-level=\"1\"") && oc.contains ("Pictures/image1.png"), "odt content");
        check (well_formed (odt.read_text ("styles.xml")) && well_formed (odt.read_text ("META-INF/manifest.xml")), "odt parts well formed");
        var xlsx = zip_of ("out.xlsx");
        string s1 = xlsx.read_text ("xl/worksheets/sheet1.xml");
        check (well_formed (s1) && xlsx.has ("xl/worksheets/sheet2.xml"), "xlsx sheets");
        check (s1.contains ("<v>1234.5</v>") && s1.contains ("<v>12</v>") && s1.contains (">Apples<"), "xlsx numeric cells");
        var ods = zip_of ("out.ods");
        string sc = ods.read_text ("content.xml");
        check (well_formed (sc) && sc.contains ("office:value=\"1234.5\""), "ods numeric cells");
        var pptx = zip_of ("out.pptx");
        check (pptx.has ("ppt/slides/slide1.xml") && pptx.has ("ppt/slides/slide2.xml") && !pptx.has ("ppt/slides/slide3.xml"), "pptx slides");
        check (well_formed (pptx.read_text ("ppt/presentation.xml")) && well_formed (pptx.read_text ("ppt/slides/slide1.xml")) && well_formed (pptx.read_text ("ppt/theme/theme1.xml")), "pptx parts well formed");
        check (pptx.read_text ("ppt/presentation.xml").contains ("cx=\"7556500\" cy=\"10693400\""), "pptx slide size");
        var odp = zip_of ("out.odp");
        check (well_formed (odp.read_text ("content.xml")) && odp.has ("Pictures/page2.png"), "odp pages");
        var png = new Gdk.Pixbuf.from_file (Path.build_filename (dir, "out-1.png"));
        check (png.width == 1240 && png.height == 1755, "png size at 150 dpi (%dx%d)".printf (png.width, png.height));
        check (FileUtils.test (Path.build_filename (dir, "out-2.jpg"), FileTest.EXISTS), "jpeg pages");
        check (FileUtils.test (Path.build_filename (dir, "out-2.tiff"), FileTest.EXISTS), "tiff pages");
        string txt;
        FileUtils.get_contents (Path.build_filename (dir, "out.txt"), out txt);
        check (txt.contains ("Annual Summary") && txt.contains ("\f"), "text export");
        string html;
        FileUtils.get_contents (Path.build_filename (dir, "out.html"), out html);
        check (html.contains ("<h1>Annual Summary</h1>") && html.contains ("<table>"), "html export");
        foreach (var n in new string[] { "out.docx", "out.odt", "out.xlsx", "out.ods", "out.pptx", "out.odp" }) check (unzip_ok (n), "unzip -t " + n);
        Exporter.export (doc, "png", File.new_for_path (Path.build_filename (dir, "single.png")), 1, 1);
        check (FileUtils.test (Path.build_filename (dir, "single.png"), FileTest.EXISTS), "single page image name");
    } catch (Error e) {
        printerr ("FAIL: %s\n", e.message);
        return 1;
    }
    print ("export dir %s\n", dir);
    return 0;
}
