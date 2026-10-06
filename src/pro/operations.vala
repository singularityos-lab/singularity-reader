namespace Singularity.Apps.Reader {

    public class Operations : Object {
        public static async uint8[] ocr (uint8[] data, string password, bool skip_text, Cancellable? cancellable, out int words) throws Error {
            words = 0;
            var recognizer = Singularity.TextRecognition.Recognizer.get_default ();
            if (!recognizer.available) throw new IOError.NOT_SUPPORTED (recognizer.install_hint);
            var engine = Singularity.Pdf.Document.open_bytes (data, password);
            var poppler = new Poppler.Document.from_bytes (new Bytes (data), password);
            int count = 0;
            for (int p = 0; p < poppler.get_n_pages (); p++) {
                if (cancellable != null && cancellable.is_cancelled ()) break;
                if (skip_text && Singularity.Pdf.Scans.has_text_layer (engine, p) && !Singularity.Pdf.Scans.is_scanned (engine, p)) continue;
                var page = poppler.get_page (p);
                double w, h;
                page.get_size (out w, out h);
                double scale = 300.0 / 72;
                int pw = int.max (1, (int) (w * scale)), ph = int.max (1, (int) (h * scale));
                var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, pw, ph);
                var cr = new Cairo.Context (surface);
                cr.set_source_rgb (1, 1, 1);
                cr.paint ();
                cr.scale (scale, scale);
                page.render_for_printing (cr);
                surface.flush ();
                var bytes = new Bytes (surface.get_data ()[0 : surface.get_stride () * ph]);
                var texture = new Gdk.MemoryTexture (pw, ph, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, bytes, surface.get_stride ());
                var text = yield recognizer.recognize_texture (texture, cancellable);
                var list = new Gee.ArrayList<Singularity.Pdf.OcrWord> ();
                foreach (var word in text.words) {
                    if (word.text.strip () == "") continue;
                    var view = Geometry.rect (word.x / scale, word.y / scale, (word.x + word.width) / scale, (word.y + word.height) / scale);
                    list.add (new Singularity.Pdf.OcrWord (word.text, PageMap.to_pdf (engine, p, view)));
                }
                count += Singularity.Pdf.Scans.add_text_layer (engine, p, list);
            }
            words = count;
            var opts = new Singularity.Pdf.SaveOptions ();
            opts.mode = Singularity.Pdf.SaveMode.INCREMENTAL;
            return engine.save (opts);
        }

        public static uint8[] optimize (uint8[] data, string password, int dpi, int quality) throws Error {
            var engine = Singularity.Pdf.Document.open_bytes (data, password);
            var opts = new Singularity.Pdf.OptimizeOptions ();
            opts.color_dpi = dpi;
            opts.jpeg_quality = quality;
            var report = new Singularity.Pdf.OptimizeReport ();
            return Singularity.Pdf.Optimizer.run (engine, opts, report);
        }

        public static uint8[] pdfa (uint8[] data, string password, string level, out int remaining) throws Error {
            var engine = Singularity.Pdf.Document.open_bytes (data, password);
            Singularity.Pdf.SaveOptions opts;
            var issues = Singularity.Pdf.Standards.convert_pdfa (engine, level, out opts);
            remaining = issues.size;
            return engine.save (opts);
        }

        public static uint8[] watermark (uint8[] data, string password, string text) throws Error {
            var engine = Singularity.Pdf.Document.open_bytes (data, password);
            var w = new Singularity.Pdf.Watermark ();
            w.text = text;
            Singularity.Pdf.Stamps.apply_watermark (engine, w);
            return engine.save ();
        }

        public static uint8[] number_pages (uint8[] data, string password, string file_name) throws Error {
            var engine = Singularity.Pdf.Document.open_bytes (data, password);
            var h = new Singularity.Pdf.HeaderFooter ();
            h.bottom_center = "<<page>> / <<pages>>";
            h.file_name = file_name;
            Singularity.Pdf.Stamps.apply_header_footer (engine, h);
            return engine.save ();
        }

        public static uint8[] sanitize (uint8[] data, string password) throws Error {
            var engine = Singularity.Pdf.Document.open_bytes (data, password);
            Singularity.Pdf.Sanitizer.apply (engine, Singularity.Pdf.HiddenInfo.ALL);
            var opts = new Singularity.Pdf.SaveOptions ();
            opts.garbage_collect = true;
            return engine.save (opts);
        }

        public static uint8[] protect (uint8[] data, string password, string new_password) throws Error {
            var engine = Singularity.Pdf.Document.open_bytes (data, password);
            var opts = new Singularity.Pdf.SaveOptions ();
            opts.new_security = Singularity.Pdf.SecurityHandler.create_aes256 (new_password, new_password + Uuid.string_random (), Singularity.Pdf.Permissions.ALL);
            return engine.save (opts);
        }

        public static uint8[] unprotect (uint8[] data, string password) throws Error {
            var engine = Singularity.Pdf.Document.open_bytes (data, password);
            var opts = new Singularity.Pdf.SaveOptions ();
            opts.remove_security = true;
            return engine.save (opts);
        }

        public static uint8[] tag (uint8[] data, string password, string language) throws Error {
            var engine = Singularity.Pdf.Document.open_bytes (data, password);
            string title = engine.lookup (engine.info (), "Title").text_value ();
            Singularity.Pdf.Tags.auto_tag (engine, language, title);
            return engine.save ();
        }

        public static uint8[] linearize (uint8[] data, string password) throws Error {
            return Singularity.Pdf.Linearizer.write (Singularity.Pdf.Document.open_bytes (data, password));
        }

        public static uint8[] redact_pattern (uint8[] data, string password, string pattern, out int count) throws Error {
            var engine = Singularity.Pdf.Document.open_bytes (data, password);
            var re = new Regex (pattern);
            count = 0;
            for (int p = 0; p < engine.page_count (); p++) {
                Singularity.Pdf.Rect[] areas = {};
                foreach (var r in Singularity.Pdf.Redaction.find_text (engine, p, re)) areas += r;
                if (areas.length == 0) continue;
                count += areas.length;
                var report = Singularity.Pdf.Redaction.apply (engine, p, areas, null, "");
                if (!report.verified) throw new IOError.FAILED (_("Redaction on page %d could not be verified").printf (p + 1));
            }
            var opts = new Singularity.Pdf.SaveOptions ();
            opts.garbage_collect = true;
            return engine.save (opts);
        }
    }
}
