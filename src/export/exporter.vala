namespace Singularity.Apps.Reader {

    public class Exporter : Object {
        private const string[] FORMATS = { "docx", "odt", "xlsx", "ods", "pptx", "odp", "png", "jpeg", "tiff", "txt", "html" };

        public static string[] formats () {
            return FORMATS;
        }

        public static string extension (string format) {
            return format == "jpeg" ? "jpg" : format;
        }

        public static string label (string format) {
            switch (format) {
                case "docx": return _("Word Document");
                case "odt": return _("OpenDocument Text");
                case "xlsx": return _("Excel Workbook");
                case "ods": return _("OpenDocument Spreadsheet");
                case "pptx": return _("PowerPoint Presentation");
                case "odp": return _("OpenDocument Presentation");
                case "png": return _("PNG Images");
                case "jpeg": return _("JPEG Images");
                case "tiff": return _("TIFF Images");
                case "txt": return _("Plain Text");
                case "html": return _("Web Page");
                default: return format;
            }
        }

        public static void export (Poppler.Document doc, string format, File target, int first_page = 0, int last_page = -1, double image_dpi = 150) throws Error {
            int n = doc.get_n_pages ();
            int first = first_page.clamp (0, int.max (0, n - 1));
            int last = last_page < 0 ? n - 1 : int.min (last_page, n - 1);
            if (n == 0 || last < first) throw new IOError.INVALID_ARGUMENT (_("There are no pages to export"));
            switch (format) {
                case "docx":
                case "odt":
                    var layouts = layouts_for (doc, first, last, true);
                    uint8[] data = format == "docx" ? TextExport.docx (layouts) : TextExport.odt (layouts);
                    write (target, data);
                    break;
                case "xlsx":
                case "ods":
                    var sheets = SheetExport.tables (layouts_for (doc, first, last, false));
                    write (target, format == "xlsx" ? SheetExport.xlsx (sheets) : SheetExport.ods (sheets));
                    break;
                case "pptx":
                case "odp":
                    write (target, SlideExport.build (doc, first, last, image_dpi, format == "pptx"));
                    break;
                case "png":
                case "jpeg":
                case "tiff":
                    export_images (doc, format, target, first, last, image_dpi);
                    break;
                case "txt":
                    var b = new StringBuilder ();
                    for (int i = first; i <= last; i++) {
                        if (i > first) b.append_c ('\f');
                        string? page_text = doc.get_page (i).get_text ();
                        b.append (page_text != null ? page_text : "");
                        b.append_c ('\n');
                    }
                    write (target, b.str.data);
                    break;
                case "html":
                    string? doc_title = doc.get_title ();
                    write (target, TextExport.html (layouts_for (doc, first, last, true), doc_title != null ? doc_title : "").data);
                    break;
                default:
                    throw new IOError.NOT_SUPPORTED (_("The format %s is not supported").printf (format));
            }
        }

        public static Gee.ArrayList<PageLayout> layouts_for (Poppler.Document doc, int first, int last, bool images) {
            var list = new Gee.ArrayList<PageLayout> ();
            for (int i = first; i <= last; i++) list.add (PageLayout.build (doc.get_page (i), images));
            PageLayout.classify (list);
            return list;
        }

        private static void write (File target, uint8[] data) throws Error {
            target.replace_contents (data, null, false, FileCreateFlags.REPLACE_DESTINATION, null, null);
        }

        public static Gdk.Pixbuf render (Poppler.Page page, double dpi) {
            double w, h;
            page.get_size (out w, out h);
            double scale = dpi / 72.0;
            int pw = int.max (1, (int) Math.ceil (w * scale)), ph = int.max (1, (int) Math.ceil (h * scale));
            var surface = new Cairo.ImageSurface (Cairo.Format.RGB24, pw, ph);
            var cr = new Cairo.Context (surface);
            cr.set_source_rgb (1, 1, 1);
            cr.paint ();
            cr.scale (scale, scale);
            page.render_for_printing (cr);
            surface.flush ();
            var pb = new Gdk.Pixbuf (Gdk.Colorspace.RGB, false, 8, pw, ph);
            unowned uint8[] dst = pb.get_pixels_with_length ();
            unowned uint8[] src = surface.get_data ();
            int ss = surface.get_stride (), ds = pb.rowstride;
            for (int y = 0; y < ph; y++) {
                for (int x = 0; x < pw; x++) {
                    int s = y * ss + x * 4, d = y * ds + x * 3;
                    dst[d] = src[s + 2];
                    dst[d + 1] = src[s + 1];
                    dst[d + 2] = src[s];
                }
            }
            return pb;
        }

        public static uint8[] render_png (Poppler.Page page, double dpi) throws Error {
            uint8[] data;
            render (page, dpi).save_to_buffer (out data, "png");
            return data;
        }

        public static File numbered (File target, int number) {
            string name = target.get_basename () ?? "page";
            int dot = name.last_index_of_char ('.');
            string stem = dot > 0 ? name.substring (0, dot) : name;
            string ext = dot > 0 ? name.substring (dot) : "";
            var parent = target.get_parent ();
            string child = "%s-%d%s".printf (stem, number, ext);
            return parent != null ? parent.get_child (child) : File.new_for_path (child);
        }

        private static bool saver_available (string type) {
            foreach (var f in Gdk.Pixbuf.get_formats ()) {
                if (f.get_name () == type && f.is_writable ()) return true;
            }
            return false;
        }

        private static void export_images (Poppler.Document doc, string format, File target, int first, int last, double dpi) throws Error {
            if (!saver_available (format)) throw new IOError.NOT_SUPPORTED (_("This system cannot write %s images").printf (format.up ()));
            for (int i = first; i <= last; i++) {
                var pb = render (doc.get_page (i), dpi);
                var file = last > first ? numbered (target, i - first + 1) : target;
                uint8[] data;
                if (format == "jpeg") pb.save_to_buffer (out data, "jpeg", "quality", "90");
                else if (format == "tiff") pb.save_to_buffer (out data, "tiff");
                else pb.save_to_buffer (out data, "png");
                write (file, data);
            }
        }
    }
}
