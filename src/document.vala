namespace Singularity.Apps.Reader {

    public class ReaderDocument : Object {
        public Poppler.Document doc { get; private set; }
        public File file { get; private set; }
        public int n_pages { get; private set; }
        public bool modified { get; set; default = false; }
        public string? password { get; private set; default = null; }
        public uint8[]? engine_bytes = null;

        private Poppler.Page[] pages;
        private double[] widths;
        private double[] heights;
        private int[] rotations;
        private Gee.HashMap<int, string> texts = new Gee.HashMap<int, string> ();
        private Gee.HashSet<int> touched = new Gee.HashSet<int> ();

        public signal void page_changed (int index);
        public signal void reloaded ();
        public signal void saved ();

        public bool is_touched (int index) {
            return touched.contains (index);
        }

        public uint8[] render_source_bytes () throws Error {
            if (engine_bytes != null) return engine_bytes;
            uint8[] data;
            FileUtils.get_data (file.get_path (), out data);
            return data;
        }

        public ReaderDocument (File file, string? password) throws Error {
            this.file = file;
            this.password = password;
            doc = new Poppler.Document.from_file (file.get_uri (), password);
            setup_pages ();
        }

        public ReaderDocument.from_bytes (File file, uint8[] data) throws Error {
            this.file = file;
            doc = new Poppler.Document.from_bytes (new Bytes (data), null);
            engine_bytes = data;
            setup_pages ();
        }

        private void setup_pages () {
            n_pages = doc.get_n_pages ();
            pages = new Poppler.Page[n_pages];
            widths = new double[n_pages];
            heights = new double[n_pages];
            rotations = new int[n_pages];
            for (int i = 0; i < n_pages; i++) {
                pages[i] = doc.get_page (i);
                pages[i].get_size (out widths[i], out heights[i]);
                rotations[i] = -1;
            }
        }

        public Poppler.Page page (int index) {
            return pages[index];
        }

        private Poppler.Document? display_doc = null;
        private bool display_ready = false;

        public void render_page (int index, Cairo.Context cr) {
            if (!touched.contains (index)) {
                if (!display_ready) {
                    display_ready = true;
                    try {
                        uint8[]? fixed_data = HairlineFix.apply (render_source_bytes (), password);
                        if (fixed_data != null) display_doc = new Poppler.Document.from_bytes (new Bytes (fixed_data), password);
                    } catch (Error e) {
                        debug ("Reader: %s", e.message);
                    }
                }
                if (display_doc != null) {
                    var fixed_page = display_doc.get_page (index);
                    if (fixed_page != null) {
                        fixed_page.render (cr);
                        return;
                    }
                }
            }
            pages[index].render (cr);
        }

        public double width (int index) { return widths[index]; }
        public double height (int index) { return heights[index]; }

        public string title () {
            string? t = doc.get_title ();
            if (t != null && t.strip () != "") return t.strip ();
            return file.get_basename () ?? "";
        }

        public string text (int index) {
            if (!texts.has_key (index)) texts[index] = pages[index].get_text () ?? "";
            return texts[index];
        }

        public int rotation (int index) {
            if (rotations[index] >= 0) return rotations[index];
            var page = pages[index];
            var probe = new Poppler.AnnotSquare (doc, Geometry.rect (0, 0, 1, 2));
            page.add_annot (probe);
            var r = probe.get_rectangle ();
            page.remove_annot (probe);
            double w = widths[index], h = heights[index];
            bool tall = (r.y2 - r.y1) > (r.x2 - r.x1);
            double cx = (r.x1 + r.x2) / 2, cy = (r.y1 + r.y2) / 2;
            int result;
            if (tall) result = cx < w / 2 && cx < h / 2 && cy < 5 ? 0 : 180;
            else result = cx < 5 ? 270 : 90;
            rotations[index] = result;
            return result;
        }

        public void changed (int index) {
            touched.add (index);
            modified = true;
            page_changed (index);
        }

        public Gee.List<Poppler.AnnotMapping> annotations (int index) {
            var list = new Gee.ArrayList<Poppler.AnnotMapping> ();
            foreach (var mapping in pages[index].get_annot_mapping ()) {
                var type = mapping.annot.get_annot_type ();
                if (type == Poppler.AnnotType.LINK || type == Poppler.AnnotType.WIDGET || type == Poppler.AnnotType.POPUP) continue;
                var copy = mapping.copy ();
                copy.area = Geometry.to_view (copy.area, heights[index]);
                list.add (copy);
            }
            return list;
        }

        public bool can_overwrite () {
            try {
                var info = file.query_info (FileAttribute.ACCESS_CAN_WRITE, FileQueryInfoFlags.NONE);
                if (!info.get_attribute_boolean (FileAttribute.ACCESS_CAN_WRITE)) return false;
                var parent = file.get_parent ();
                if (parent == null) return false;
                var dir_info = parent.query_info (FileAttribute.ACCESS_CAN_WRITE, FileQueryInfoFlags.NONE);
                return dir_info.get_attribute_boolean (FileAttribute.ACCESS_CAN_WRITE);
            } catch (Error e) {
                return false;
            }
        }

        public uint8[] current_bytes () throws Error {
            if (touched.size == 0 && engine_bytes != null) return engine_bytes;
            if (touched.size == 0) {
                uint8[] data;
                FileUtils.get_data (file.get_path (), out data);
                return data;
            }
            flush_touched ();
            string path;
            int fd = FileUtils.open_tmp ("reader-XXXXXX.pdf", out path);
            FileUtils.close (fd);
            try {
                if (!doc.save (File.new_for_path (path).get_uri ())) throw new IOError.FAILED ("The document could not be written.");
                uint8[] data;
                FileUtils.get_data (path, out data);
                return data;
            } finally {
                FileUtils.unlink (path);
            }
        }

        public Singularity.Pdf.Document open_engine () throws Error {
            return Singularity.Pdf.Document.open_bytes (current_bytes (), password ?? "");
        }

        public void replace_bytes (uint8[] data, string? new_password = null) throws Error {
            if (new_password != null) password = new_password;
            var fresh = new Poppler.Document.from_bytes (new Bytes (data), password);
            doc = fresh;
            engine_bytes = data;
            texts.clear ();
            touched.clear ();
            display_doc = null;
            display_ready = false;
            setup_pages ();
            modified = true;
            reloaded ();
        }

        public void apply (Singularity.Pdf.Document engine, Singularity.Pdf.SaveOptions? options = null) throws Error {
            Singularity.Pdf.SaveOptions opts;
            if (options != null) {
                opts = options;
            } else {
                opts = new Singularity.Pdf.SaveOptions ();
                opts.mode = Singularity.Pdf.SaveMode.INCREMENTAL;
            }
            replace_bytes (engine.save (opts));
        }

        private void flush_touched () {
            foreach (int index in touched) {
                var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, 1, 1);
                var cr = new Cairo.Context (surface);
                cr.scale (1.0 / double.max (1, widths[index]), 1.0 / double.max (1, heights[index]));
                pages[index].render (cr);
            }
        }

        public void save (File target) throws Error {
            flush_touched ();
            var parent = target.get_parent ();
            string name = ".%s.%s.tmp".printf (target.get_basename () ?? "document", Uuid.string_random ().substring (0, 8));
            var tmp = parent != null ? parent.get_child (name) : File.new_for_path (name);
            try {
                if (touched.size == 0 && engine_bytes != null) FileUtils.set_data (tmp.get_path (), engine_bytes);
                else if (!doc.save (tmp.get_uri ())) throw new IOError.FAILED ("The document could not be written.");
                if (target.query_exists ()) {
                    try {
                        var info = target.query_info (FileAttribute.UNIX_MODE, FileQueryInfoFlags.NONE);
                        if (info.has_attribute (FileAttribute.UNIX_MODE)) {
                            tmp.set_attribute_uint32 (FileAttribute.UNIX_MODE, info.get_attribute_uint32 (FileAttribute.UNIX_MODE) & 07777, FileQueryInfoFlags.NONE);
                        }
                    } catch (Error ignored) {
                    }
                }
                if (FileUtils.rename (tmp.get_path (), target.get_path ()) != 0) {
                    throw new IOError.FAILED ("The document could not be replaced: %s".printf (strerror (errno)));
                }
            } catch (Error e) {
                try {
                    tmp.delete ();
                } catch (Error ignored) {
                }
                throw e;
            }
            file = target;
            if (touched.size > 0) engine_bytes = null;
            touched.clear ();
            modified = false;
            saved ();
        }
    }
}
