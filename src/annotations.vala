namespace Singularity.Apps.Reader {

    public enum MarkupKind {
        HIGHLIGHT,
        UNDERLINE,
        STRIKEOUT,
        SQUIGGLY
    }

    public class Annotations : Object {
        public static void finish (Poppler.Annot annot, string author) {
            annot.set_flags (annot.get_flags () | Poppler.AnnotFlag.PRINT);
            var markup = annot as Poppler.AnnotMarkup;
            if (markup != null && author != "") markup.set_label (author);
        }

        public static Poppler.Rectangle[] selected_glyphs (ReaderDocument document, int index, Poppler.Rectangle selection,
                                                          Poppler.SelectionStyle style, Gee.List<int>? line_starts = null) {
            if (line_starts != null) line_starts.clear ();
            var page = document.page (index);
            Poppler.Rectangle[] result = {};
            Poppler.Rectangle[] layout;
            if (!page.get_text_layout (out layout)) return result;
            const double SCALE = 4.0;
            var region = page.get_selected_region (SCALE, style, selection);
            string text = document.text (index);
            int char_index = 0;
            unichar c;
            int byte_index = 0;
            bool new_line = true;
            while (text.get_next_char (ref byte_index, out c) && char_index < layout.length) {
                var g = layout[char_index++];
                if (c == '\n' || c == '\r') {
                    new_line = true;
                    continue;
                }
                if (g.x2 - g.x1 <= 0.01 || g.y2 - g.y1 <= 0.01) continue;
                double cx = (g.x1 + g.x2) / 2 * SCALE, cy = (g.y1 + g.y2) / 2 * SCALE;
                if (region.contains_point ((int) cx, (int) cy)) {
                    if (new_line && line_starts != null) line_starts.add (result.length);
                    result += g;
                    new_line = false;
                }
            }
            return result;
        }

        public static string selected_text (ReaderDocument document, int index, Poppler.Rectangle selection, Poppler.SelectionStyle style) {
            return document.page (index).get_selected_text (style, selection) ?? "";
        }

        public static Poppler.Annot? markup (ReaderDocument document, int index, Poppler.Rectangle[] glyphs,
                                             MarkupKind kind, string hex, double opacity, string author, Gee.List<int>? line_starts = null) {
            if (glyphs.length == 0) return null;
            Poppler.Rectangle bounds;
            var quads = Geometry.quads (glyphs, document.height (index), out bounds, line_starts);
            Poppler.Annot annot;
            switch (kind) {
                case MarkupKind.UNDERLINE: annot = new Poppler.AnnotTextMarkup.underline (document.doc, bounds, quads); break;
                case MarkupKind.STRIKEOUT: annot = new Poppler.AnnotTextMarkup.strikeout (document.doc, bounds, quads); break;
                case MarkupKind.SQUIGGLY: annot = new Poppler.AnnotTextMarkup.squiggly (document.doc, bounds, quads); break;
                default: annot = new Poppler.AnnotTextMarkup.highlight (document.doc, bounds, quads); break;
            }
            annot.set_color (Geometry.color (hex));
            if (kind == MarkupKind.HIGHLIGHT) ((Poppler.AnnotMarkup) annot).set_opacity (opacity);
            finish (annot, author);
            document.page (index).add_annot (annot);
            document.changed (index);
            return annot;
        }

        public static Poppler.Annot note (ReaderDocument document, int index, double x, double y, string text,
                                          string hex, string author) {
            double h = document.height (index);
            var view = Geometry.rect (x - 12, y - 12, x + 12, y + 12);
            var pdf = Geometry.to_pdf (view, h);
            var annot = new Poppler.AnnotText (document.doc, pdf);
            annot.set_icon (Poppler.AnnotTextIcon.NOTE);
            annot.set_color (Geometry.color (hex));
            annot.set_contents (text);
            finish (annot, author);
            document.page (index).add_annot (annot);
            document.changed (index);
            return annot;
        }

        public static Poppler.Annot text_box (ReaderDocument document, int index, Poppler.Rectangle view, string text,
                                              string hex, double size, string author) {
            double h = document.height (index);
            var annot = new Poppler.AnnotFreeText (document.doc, Geometry.to_pdf (view, h));
#if POPPLER_TEXT_STYLE
            if (available ("poppler_annot_free_text_set_font_desc")) {
                var font = new Poppler.FontDescription ("Sans");
                font.size_pt = size;
                annot.set_font_desc (font);
                annot.set_font_color (Geometry.color (hex));
                annot.set_border_width (0);
            } else {
                annot.set_color (Geometry.color (hex));
            }
#else
            annot.set_color (Geometry.color (hex));
#endif
            annot.set_contents (text);
            finish (annot, author);
            document.page (index).add_annot (annot);
            document.changed (index);
            return annot;
        }

        private static Module? self_module = null;

        public static bool available (string symbol) {
            if (self_module == null) self_module = Module.open (null, ModuleFlags.LAZY);
            void* address = null;
            return self_module != null && self_module.symbol (symbol, out address) && address != null;
        }

        public static bool ink_supported () {
#if POPPLER_INK
            return available ("poppler_annot_ink_new") && available ("poppler_annot_ink_set_ink_list") && available ("poppler_path_new_from_array");
#else
            return false;
#endif
        }

        public static Poppler.Annot? ink (ReaderDocument document, int index, Gee.List<Gee.List<double?>> strokes,
                                          string hex, double width, double opacity, bool highlighter, string author) {
#if POPPLER_INK
            if (!ink_supported ()) return null;
            double h = document.height (index);
            double x1 = double.MAX, y1 = double.MAX, x2 = -double.MAX, y2 = -double.MAX;
            Poppler.Path[] paths = {};
            foreach (var stroke in strokes) {
                if (stroke.size < 2) continue;
                Poppler.Point[] points = new Poppler.Point[stroke.size / 2];
                for (int i = 0; i + 1 < stroke.size; i += 2) {
                    double x = stroke[i], y = stroke[i + 1];
                    x1 = double.min (x1, x); x2 = double.max (x2, x);
                    y1 = double.min (y1, y); y2 = double.max (y2, y);
                    var p = Poppler.Point ();
                    p.x = x;
                    p.y = h - y;
                    points[i / 2] = p;
                }
                if (points.length == 1) {
                    var p = points[0];
                    p.x += 0.5;
                    points += p;
                }
                paths += new Poppler.Path.from_array ((owned) points);
            }
            if (paths.length == 0) return null;
            var view = Geometry.rect (x1 - width, y1 - width, x2 + width, y2 + width);
            var annot = new Poppler.AnnotInk (document.doc, Geometry.to_pdf (view, h));
            annot.set_color (Geometry.color (hex));
            annot.set_border_width (width);
            annot.set_opacity (opacity);
#if POPPLER_DRAW_BELOW
            if (highlighter && available ("poppler_annot_ink_set_draw_below")) annot.set_draw_below (true);
#endif
            finish (annot, author);
            document.page (index).add_annot (annot);
            annot.set_ink_list (paths);
            document.changed (index);
            return annot;
#else
            return null;
#endif
        }

        public static Cairo.ImageSurface oriented (Cairo.ImageSurface image, int rotation) {
            int iw = image.get_width (), ih = image.get_height ();
            if (rotation == 0) return image;
            bool swap = rotation == 90 || rotation == 270;
            var result = new Cairo.ImageSurface (Cairo.Format.ARGB32, swap ? ih : iw, swap ? iw : ih);
            var cr = new Cairo.Context (result);
            if (rotation == 90) { cr.translate (0, iw); cr.rotate (-Math.PI / 2); }
            else if (rotation == 180) { cr.translate (iw, ih); cr.rotate (Math.PI); }
            else if (rotation == 270) { cr.translate (ih, 0); cr.rotate (Math.PI / 2); }
            cr.set_source_surface (image, 0, 0);
            cr.paint ();
            return result;
        }

        public static Cairo.ImageSurface fit_image (Cairo.ImageSurface image, double width_pt, double height_pt) {
            int target_w = (int) Math.ceil (width_pt * 2), target_h = (int) Math.ceil (height_pt * 2);
            if (image.get_width () <= target_w && image.get_height () <= target_h) return image;
            var result = new Cairo.ImageSurface (Cairo.Format.ARGB32, int.max (1, target_w), int.max (1, target_h));
            var cr = new Cairo.Context (result);
            cr.scale ((double) target_w / image.get_width (), (double) target_h / image.get_height ());
            cr.set_source_surface (image, 0, 0);
            cr.get_source ().set_filter (Cairo.Filter.GOOD);
            cr.paint ();
            return result;
        }

        public static Poppler.AnnotStamp stamp (ReaderDocument document, int index, Poppler.Rectangle view,
                                               Cairo.ImageSurface image, string author) throws Error {
            double h = document.height (index);
            var annot = new Poppler.AnnotStamp (document.doc, Geometry.to_pdf (view, h));
            finish (annot, author);
            document.page (index).add_annot (annot);
            place_image (document, index, annot, image, view);
            document.changed (index);
            return annot;
        }

        public static void place_image (ReaderDocument document, int index, Poppler.AnnotStamp annot,
                                        Cairo.ImageSurface image, Poppler.Rectangle view) throws Error {
            var fitted = fit_image (image, view.x2 - view.x1, view.y2 - view.y1);
            annot.set_custom_image (oriented (fitted, document.rotation (index)));
        }

        public static void move_stamp (ReaderDocument document, int index, Poppler.AnnotStamp annot,
                                       Cairo.ImageSurface image, Poppler.Rectangle view) throws Error {
            annot.set_rectangle (Geometry.to_pdf (view, document.height (index)));
            place_image (document, index, annot, image, view);
            document.changed (index);
        }

        public static void remove (ReaderDocument document, int index, Poppler.Annot annot) {
            document.page (index).remove_annot (annot);
            document.changed (index);
        }

        public static void recolor (ReaderDocument document, int index, Poppler.Annot annot, string hex) {
            var free_text = annot as Poppler.AnnotFreeText;
            if (free_text != null) {
#if POPPLER_TEXT_STYLE
                if (available ("poppler_annot_free_text_set_font_color")) free_text.set_font_color (Geometry.color (hex));
                else annot.set_color (Geometry.color (hex));
#else
                annot.set_color (Geometry.color (hex));
#endif
            } else {
                annot.set_color (Geometry.color (hex));
            }
            document.changed (index);
        }

        public static void set_text (ReaderDocument document, int index, Poppler.Annot annot, string text) {
            annot.set_contents (text);
            document.changed (index);
        }

        public static string describe (Poppler.Annot annot) {
            switch (annot.get_annot_type ()) {
                case Poppler.AnnotType.HIGHLIGHT: return _("Highlight");
                case Poppler.AnnotType.UNDERLINE: return _("Underline");
                case Poppler.AnnotType.STRIKE_OUT: return _("Strikeout");
                case Poppler.AnnotType.SQUIGGLY: return _("Squiggly");
                case Poppler.AnnotType.TEXT: return _("Note");
                case Poppler.AnnotType.FREE_TEXT: return _("Text");
                case Poppler.AnnotType.INK: return _("Drawing");
                case Poppler.AnnotType.STAMP: return _("Signature or Stamp");
                case Poppler.AnnotType.SQUARE: return _("Rectangle");
                case Poppler.AnnotType.CIRCLE: return _("Ellipse");
                case Poppler.AnnotType.LINE: return _("Line");
                default: return _("Annotation");
            }
        }
    }
}
