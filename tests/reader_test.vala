using Singularity.Apps.Reader;

string sample_path;

void make_sample (string path) {
    var surface = new Cairo.PdfSurface (path, 595, 842);
    var cr = new Cairo.Context (surface);
    cr.select_font_face ("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.NORMAL);
    cr.set_font_size (18);
    cr.move_to (72, 100);
    cr.show_text ("The quick brown fox jumps");
    cr.move_to (72, 130);
    cr.show_text ("over the lazy dog today");
    cr.show_page ();
    cr.move_to (72, 100);
    cr.show_text ("Second page text");
    cr.show_page ();
    surface.finish ();
}

ReaderDocument open_sample () {
    try {
        return new ReaderDocument (File.new_for_path (sample_path), null);
    } catch (Error e) {
        error ("open: %s", e.message);
    }
}

void test_quad_directions () {
    Poppler.Rectangle[] ltr = { Geometry.rect (10, 10, 20, 30), Geometry.rect (20, 10, 30, 30) };
    var q = Geometry.quad_for (ltr, 0, 1, 100);
    assert (q.p1.x == 10 && q.p1.y == 90 && q.p2.x == 30 && q.p4.y == 70);
    Poppler.Rectangle[] down = { Geometry.rect (10, 10, 30, 20), Geometry.rect (10, 20, 30, 30) };
    q = Geometry.quad_for (down, 0, 1, 100);
    assert (q.p1.x == 30 && q.p1.y == 90 && q.p2.y == 70 && q.p3.x == 10);
    Poppler.Rectangle[] rtl = { Geometry.rect (20, 10, 30, 30), Geometry.rect (10, 10, 20, 30) };
    q = Geometry.quad_for (rtl, 0, 1, 100);
    assert (q.p1.x == 30 && q.p1.y == 70 && q.p2.x == 10);
}

void test_line_grouping () {
    Poppler.Rectangle[] glyphs = {
        Geometry.rect (10, 10, 20, 30), Geometry.rect (20, 10, 30, 30), Geometry.rect (30, 11, 40, 29),
        Geometry.rect (10, 40, 20, 60), Geometry.rect (20, 40, 30, 60)
    };
    var starts = Geometry.line_breaks (glyphs);
    assert (starts.size == 2 && starts[0] == 0 && starts[1] == 3);
    Poppler.Rectangle bounds;
    var quads = Geometry.quads (glyphs, 100, out bounds);
    assert (quads.length == 2);
    assert (bounds.x1 == 10 && bounds.x2 == 40 && bounds.y1 == 40 && bounds.y2 == 90);
}

void test_leading_space_lines () {
    Poppler.Rectangle[] glyphs = {
        Geometry.rect (154.728, 80.758, 159.408, 105.274),
        Geometry.rect (159.408, 80.758, 170.568, 105.274),
        Geometry.rect (170.568, 80.758, 178.218, 105.274),
        Geometry.rect (72, 110.758, 82.962, 135.274),
        Geometry.rect (82.962, 110.758, 92.43, 135.274)
    };
    var starts = Geometry.line_breaks (glyphs);
    assert (starts.size == 2 && starts[0] == 0 && starts[1] == 3);
    Poppler.Rectangle bounds;
    var quads = Geometry.quads (glyphs, 842, out bounds);
    assert (quads.length == 2);
    assert (quads.index (0).p1.x == 154.728 && quads.index (0).p2.x == 178.218);
    assert (quads.index (1).p1.x == 72 && quads.index (1).p2.x == 92.43);
}

void test_narrow_glyph_lines () {
    Poppler.Rectangle[] glyphs = {
        Geometry.rect (10, 10, 11, 30), Geometry.rect (11, 10, 21, 30),
        Geometry.rect (10, 40, 11, 60), Geometry.rect (11, 40, 21, 60)
    };
    var starts = Geometry.line_breaks (glyphs);
    assert (starts.size == 2 && starts[0] == 0 && starts[1] == 2);
    Poppler.Rectangle bounds;
    var quads = Geometry.quads (glyphs, 100, out bounds);
    assert (quads.length == 2);
    assert (bounds.x1 == 10 && bounds.x2 == 21 && bounds.y1 == 40 && bounds.y2 == 90);
}

void test_vertical_lines () {
    Poppler.Rectangle[] wide = {
        Geometry.rect (10, 10, 30, 14), Geometry.rect (10, 14, 30, 18),
        Geometry.rect (40, 10, 60, 14), Geometry.rect (40, 14, 60, 18)
    };
    var starts = Geometry.line_breaks (wide);
    assert (starts.size == 2 && starts[0] == 0 && starts[1] == 2);
    Poppler.Rectangle bounds;
    var quads = Geometry.quads (wide, 100, out bounds);
    assert (quads.length == 2);
    assert (quads.index (0).p1.x == 30 && quads.index (0).p1.y == 90 && quads.index (0).p2.y == 82);
    Poppler.Rectangle[] narrow = {
        Geometry.rect (10, 40, 12, 60), Geometry.rect (10, 20, 12, 40),
        Geometry.rect (40, 40, 42, 60), Geometry.rect (40, 20, 42, 40)
    };
    starts = Geometry.line_breaks (narrow);
    assert (starts.size == 2 && starts[0] == 0 && starts[1] == 2);
    quads = Geometry.quads (narrow, 100, out bounds);
    assert (quads.length == 2);
    assert (quads.index (0).p1.x == 10 && quads.index (0).p1.y == 40 && quads.index (0).p2.y == 80);
}

void test_singleton_and_vertical_save () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "reader-line-orientation.pdf");
    var surface = new Cairo.PdfSurface (path, 300, 300);
    var cr = new Cairo.Context (surface);
    cr.select_font_face ("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.NORMAL);
    cr.set_font_size (18);
    cr.move_to (72, 100); cr.show_text ("A");
    cr.move_to (72, 130); cr.show_text ("B");
    cr.show_page ();
    cr.save ();
    cr.translate (150, 72); cr.rotate (Math.PI / 2);
    cr.move_to (0, 0); cr.show_text ("AB");
    cr.restore ();
    cr.show_page ();
    surface.finish ();
    try {
        var doc = new ReaderDocument (File.new_for_path (path), null);
        var area = Geometry.rect (0, 0, 300, 300);
        assert (Annotations.selected_text (doc, 0, area, Poppler.SelectionStyle.GLYPH).strip () == "A\nB");
        var line_starts = new Gee.ArrayList<int> ();
        var glyphs = Annotations.selected_glyphs (doc, 0, area, Poppler.SelectionStyle.GLYPH, line_starts);
        assert (glyphs.length == 2);
        assert (line_starts.size == 2 && line_starts[0] == 0 && line_starts[1] == 1);
        var annot = Annotations.markup (doc, 0, glyphs, MarkupKind.UNDERLINE, "#e01b24", 1, "Tester", line_starts);
        assert (((Poppler.AnnotTextMarkup) annot).get_quadrilaterals ().length == 2);
        assert (Annotations.selected_text (doc, 1, area, Poppler.SelectionStyle.GLYPH).strip () == "AB");
        glyphs = Annotations.selected_glyphs (doc, 1, area, Poppler.SelectionStyle.GLYPH, line_starts);
        assert (glyphs.length == 2);
        assert (line_starts.size == 1 && line_starts[0] == 0);
        annot = Annotations.markup (doc, 1, glyphs, MarkupKind.UNDERLINE, "#e01b24", 1, "Tester", line_starts);
        var quads = ((Poppler.AnnotTextMarkup) annot).get_quadrilaterals ();
        assert (quads.length == 1);
        assert (quads.index (0).p1.x == quads.index (0).p2.x && quads.index (0).p1.y > quads.index (0).p2.y);
        doc.save (File.new_for_path (path));
        var reopened = new ReaderDocument (File.new_for_path (path), null);
        for (int page = 0; page < 2; page++) {
            int count = 0;
            foreach (var mapping in reopened.page (page).get_annot_mapping ()) {
                var underline = mapping.annot as Poppler.AnnotTextMarkup;
                if (underline == null) continue;
                assert (underline.get_quadrilaterals ().length == (page == 0 ? 2 : 1));
                count++;
            }
            assert (count == 1);
        }
    } catch (Error e) {
        error ("line orientation: %s", e.message);
    }
}

void test_unrotate_and_color () {
    double x = 10, y = 20;
    Geometry.unrotate (90, 595, 842, ref x, ref y);
    assert (x == 822 && y == 10);
    x = 10; y = 20;
    Geometry.unrotate (270, 595, 842, ref x, ref y);
    assert (x == 20 && y == 585);
    var c = Geometry.color ("#f5c211");
    assert (Geometry.hex (c) == "#f5c211");
    assert (Geometry.hex (Geometry.color ("#abc")) == "#aabbcc");
    assert (Geometry.hex (Geometry.color ("garbage")) == "#f5c211");
}

void test_markup_and_save () {
    var doc = open_sample ();
    var line_starts = new Gee.ArrayList<int> ();
    var one_line = Annotations.selected_glyphs (doc, 0, Geometry.rect (70, 80, 200, 104), Poppler.SelectionStyle.GLYPH, line_starts);
    assert (one_line.length >= 5);
    var hl = Annotations.markup (doc, 0, one_line, MarkupKind.HIGHLIGHT, "#f5c211", 0.45, "Tester", line_starts);
    assert (hl != null);
    assert (((Poppler.AnnotTextMarkup) hl).get_quadrilaterals ().length == 1);
    var two_lines = Annotations.selected_glyphs (doc, 0, Geometry.rect (150, 85, 150, 125), Poppler.SelectionStyle.GLYPH, line_starts);
    var ul = Annotations.markup (doc, 0, two_lines, MarkupKind.UNDERLINE, "#e01b24", 1, "Tester", line_starts);
    assert (((Poppler.AnnotTextMarkup) ul).get_quadrilaterals ().length == 2);
    Annotations.note (doc, 0, 400, 200, "Remember this", "#f5c211", "Tester");
    Annotations.text_box (doc, 1, Geometry.rect (72, 200, 300, 230), "Typed text", "#241f31", 12, "Tester");
    var strokes = new Gee.ArrayList<Gee.List<double?>> ();
    var stroke = new Gee.ArrayList<double?> ();
    for (int i = 0; i < 20; i++) { stroke.add (100 + i * 5); stroke.add (300 + Math.sin (i / 3.0) * 20); }
    strokes.add (stroke);
    var ink = Annotations.ink (doc, 0, strokes, "#1c71d8", 2, 1, false, "Tester");
    assert ((ink != null) == Annotations.ink_supported ());
    var image = new Cairo.ImageSurface (Cairo.Format.ARGB32, 300, 120);
    var cr = new Cairo.Context (image);
    cr.set_source_rgba (0, 0, 0, 1);
    cr.set_line_width (6);
    cr.move_to (20, 90); cr.curve_to (80, 0, 160, 140, 280, 40);
    cr.stroke ();
    try {
        var st = Annotations.stamp (doc, 0, Geometry.rect (350, 600, 500, 660), image, "Tester");
        Annotations.move_stamp (doc, 0, st, image, Geometry.rect (360, 610, 510, 670));
    } catch (Error e) {
        error ("stamp: %s", e.message);
    }
    assert (doc.modified);
    try {
        doc.save (File.new_for_path (sample_path));
    } catch (Error e) {
        error ("save: %s", e.message);
    }
    assert (!doc.modified);

    uint8[] bytes;
    try {
        FileUtils.get_data (sample_path, out bytes);
    } catch (Error e) {
        error ("read: %s", e.message);
    }
    assert (bytes.length > 1000);
    var reopened = open_sample ();
    int highlight = 0, underline = 0, text = 0, free_text = 0, stamps = 0, inks = 0;
    for (int p = 0; p < reopened.n_pages; p++) {
        foreach (var m in reopened.annotations (p)) {
            switch (m.annot.get_annot_type ()) {
                case Poppler.AnnotType.HIGHLIGHT: highlight++; assert (Geometry.hex (m.annot.get_color ()) == "#f5c211"); break;
                case Poppler.AnnotType.UNDERLINE: underline++; break;
                case Poppler.AnnotType.TEXT: text++; assert (m.annot.get_contents () == "Remember this"); break;
                case Poppler.AnnotType.FREE_TEXT: free_text++; break;
                case Poppler.AnnotType.STAMP: stamps++; break;
                case Poppler.AnnotType.INK: inks++; break;
                default: break;
            }
        }
    }
    assert (highlight == 1 && underline == 1 && text == 1 && free_text == 1 && stamps == 1);
    assert (inks == (Annotations.ink_supported () ? 1 : 0));
    string raw = (string) bytes;
    int stamp_at = -1;
    for (int i = 0; i + 12 < bytes.length; i++) {
        if (Memory.cmp (&bytes[i], "/Subtype /Stamp".data, 15) == 0 || Memory.cmp (&bytes[i], "/Subtype/Stamp".data, 14) == 0) {
            stamp_at = i;
            break;
        }
    }
    assert (stamp_at >= 0);
    assert (raw != null);

    var again = open_sample ();
    Annotations.note (again, 1, 100, 100, "Second save", "#33d17a", "");
    try {
        again.save (File.new_for_path (sample_path));
    } catch (Error e) {
        error ("second save: %s", e.message);
    }
    var final_doc = open_sample ();
    assert (final_doc.annotations (1).size == 2);
}

void test_overwrite_keeps_mode () {
    string path = sample_path + ".mode.pdf";
    make_sample (path);
    FileUtils.chmod (path, 0640);
    ReaderDocument doc;
    try {
        doc = new ReaderDocument (File.new_for_path (path), null);
    } catch (Error e) {
        error ("open: %s", e.message);
    }
    assert (doc.can_overwrite ());
    Annotations.note (doc, 0, 100, 100, "Mode", "#f5c211", "");
    try {
        doc.save (doc.file);
    } catch (Error e) {
        error ("save: %s", e.message);
    }
    Posix.Stat st;
    assert (Posix.stat (path, out st) == 0);
    assert ((st.st_mode & 0777) == 0640);
    FileUtils.chmod (path, 0440);
    assert (!doc.can_overwrite ());
    FileUtils.chmod (path, 0640);
    FileUtils.remove (path);
}

void test_stamp_keeps_appearance () {
    var doc = open_sample ();
    var image = new Cairo.ImageSurface (Cairo.Format.ARGB32, 200, 80);
    var cr = new Cairo.Context (image);
    cr.set_source_rgba (0, 0, 0, 1);
    cr.rectangle (10, 10, 180, 60);
    cr.fill ();
    try {
        Annotations.stamp (doc, 0, Geometry.rect (100, 700, 250, 760), image, "");
        doc.save (File.new_for_path (sample_path));
    } catch (Error e) {
        error ("stamp save: %s", e.message);
    }
    var reopened = open_sample ();
    var render = new Cairo.ImageSurface (Cairo.Format.ARGB32, 595, 842);
    var rcr = new Cairo.Context (render);
    rcr.set_source_rgb (1, 1, 1);
    rcr.paint ();
    reopened.page (0).render (rcr);
    render.flush ();
    unowned uchar[] data = render.get_data ();
    int stride = render.get_stride ();
    int dark = 0;
    for (int y = 710; y < 750; y++) {
        for (int x = 110; x < 240; x++) {
            uchar b = data[y * stride + x * 4];
            if (b < 60) dark++;
        }
    }
    assert (dark > 2000);
}

int main (string[] args) {
    Test.init (ref args);
    sample_path = Path.build_filename (Environment.get_tmp_dir (), "reader-test-%s.pdf".printf (Uuid.string_random ().substring (0, 8)));
    make_sample (sample_path);
    Test.add_func ("/reader/quads", test_quad_directions);
    Test.add_func ("/reader/lines", test_line_grouping);
    Test.add_func ("/reader/leading-space-lines", test_leading_space_lines);
    Test.add_func ("/reader/narrow-glyph-lines", test_narrow_glyph_lines);
    Test.add_func ("/reader/vertical-lines", test_vertical_lines);
    Test.add_func ("/reader/singleton-vertical-save", test_singleton_and_vertical_save);
    Test.add_func ("/reader/unrotate-color", test_unrotate_and_color);
    Test.add_func ("/reader/markup-save", test_markup_and_save);
    Test.add_func ("/reader/stamp-appearance", test_stamp_keeps_appearance);
    Test.add_func ("/reader/overwrite-mode", test_overwrite_keeps_mode);
    int result = Test.run ();
    FileUtils.remove (sample_path);
    return result;
}
