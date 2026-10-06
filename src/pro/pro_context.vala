using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public delegate void EngineOp (Singularity.Pdf.Document engine) throws Error;

    public class PageMap : Object {
        public static Singularity.Pdf.Rect to_pdf (Singularity.Pdf.Document engine, int page, Poppler.Rectangle view) {
            var r = Singularity.Pdf.Rect.empty ();
            double x, y;
            point_to_pdf (engine, page, view.x1, view.y1, out x, out y);
            r.add (x, y);
            point_to_pdf (engine, page, view.x2, view.y2, out x, out y);
            r.add (x, y);
            return r;
        }

        public static void point_to_pdf (Singularity.Pdf.Document engine, int page, double vx, double vy, out double px, out double py) {
            var b = engine.page_box (page, "CropBox");
            switch (engine.page_rotation (page)) {
                case 90: px = b[0] + vy; py = b[1] + vx; break;
                case 180: px = b[2] - vx; py = b[1] + vy; break;
                case 270: px = b[2] - vy; py = b[3] - vx; break;
                default: px = b[0] + vx; py = b[3] - vy; break;
            }
        }

        public static void point_to_view (Singularity.Pdf.Document engine, int page, double px, double py, out double vx, out double vy) {
            var b = engine.page_box (page, "CropBox");
            switch (engine.page_rotation (page)) {
                case 90: vy = px - b[0]; vx = py - b[1]; break;
                case 180: vx = b[2] - px; vy = py - b[1]; break;
                case 270: vy = b[2] - px; vx = b[3] - py; break;
                default: vx = px - b[0]; vy = b[3] - py; break;
            }
        }

        public static Poppler.Rectangle to_view (Singularity.Pdf.Document engine, int page, Singularity.Pdf.Rect r) {
            double x1, y1, x2, y2;
            point_to_view (engine, page, r.x1, r.y1, out x1, out y1);
            point_to_view (engine, page, r.x2, r.y2, out x2, out y2);
            return Geometry.rect (x1, y1, x2, y2);
        }
    }

    public class ProContext : Object {
        public ReaderWindow window;
        public ReaderApp app;
        public DocumentView view;
        public string author {
            owned get {
                string a = app.settings.get_string ("author");
                return a != "" ? a : Environment.get_real_name ();
            }
        }

        public ReaderDocument? document {
            get { return view.document; }
        }

        public ProContext (ReaderWindow window, ReaderApp app, DocumentView view) {
            this.window = window;
            this.app = app;
            this.view = view;
        }

        public Singularity.Pdf.Document? engine () {
            if (document == null) return null;
            try {
                return document.open_engine ();
            } catch (Error e) {
                error_dialog (_("The document could not be read"), e.message);
                return null;
            }
        }

        private bool busy = false;

        public bool run (string done_message, EngineOp op, Singularity.Pdf.SaveOptions? options = null) {
            if (busy) return false;
            busy = true;
            bool ok = run_now (done_message, op, options);
            busy = false;
            return ok;
        }

        private bool run_now (string done_message, EngineOp op, Singularity.Pdf.SaveOptions? options) {
            var engine = this.engine ();
            if (engine == null) return false;
            try {
                op (engine);
                document.apply (engine, options);
                if (done_message != "") toast (done_message);
                return true;
            } catch (Error e) {
                error_dialog (_("The operation could not be completed"), e.message);
                return false;
            }
        }

        public void toast (string message) {
            window.add_toast (new Toast (message));
        }

        public void error_dialog (string title, string detail) {
            var dlg = new ConfirmDialog.message (app, title, "dialog-error", detail, _("Close"));
            dlg.transient_for = window;
            dlg.present ();
        }

        public int current_page {
            get { return view.current_page; }
        }

        public string base_name () {
            if (document == null) return "document";
            string name = document.file.get_basename () ?? "document.pdf";
            if (name.down ().has_suffix (".pdf")) name = name.substring (0, name.length - 4);
            return name;
        }

        public async File? choose_save (string title, string suggested, string? mime = null, string? pattern = null) {
            var dialog = new FileDialog ();
            dialog.title = title;
            dialog.initial_name = suggested;
            if (document != null) {
                var folder = document.file.get_parent ();
                if (folder != null && folder.query_exists ()) dialog.initial_folder = folder;
            }
            if (mime != null || pattern != null) {
                var filter = new FileFilter ();
                if (mime != null) filter.add_mime_type (mime);
                if (pattern != null) filter.add_pattern (pattern);
                var filters = new GLib.ListStore (typeof (FileFilter));
                filters.append (filter);
                dialog.filters = filters;
            }
            try {
                return yield dialog.save (window, null);
            } catch (Error e) {
                return null;
            }
        }

        public async File? choose_open (string title, string? mime = null, string? pattern = null) {
            var dialog = new FileDialog ();
            dialog.title = title;
            if (mime != null || pattern != null) {
                var filter = new FileFilter ();
                if (mime != null) filter.add_mime_type (mime);
                if (pattern != null) filter.add_pattern (pattern);
                var filters = new GLib.ListStore (typeof (FileFilter));
                filters.append (filter);
                dialog.filters = filters;
            }
            try {
                return yield dialog.open (window, null);
            } catch (Error e) {
                return null;
            }
        }

        public async File[] choose_many (string title, string[] mimes) {
            var dialog = new FileDialog ();
            dialog.title = title;
            if (mimes.length > 0) {
                var filter = new FileFilter ();
                foreach (var m in mimes) filter.add_mime_type (m);
                var filters = new GLib.ListStore (typeof (FileFilter));
                filters.append (filter);
                dialog.filters = filters;
            }
            File[] result = {};
            try {
                var list = yield dialog.open_multiple (window, null);
                for (uint i = 0; i < list.get_n_items (); i++) result += (File) list.get_item (i);
            } catch (Error e) {
            }
            return result;
        }

        public async File? choose_folder (string title) {
            var dialog = new FileDialog ();
            dialog.title = title;
            try {
                return yield dialog.select_folder (window, null);
            } catch (Error e) {
                return null;
            }
        }

        public void write_file (File target, uint8[] data) throws Error {
            string path = target.get_path ();
            string tmp = path + ".part";
            FileUtils.set_data (tmp, data);
            if (FileUtils.rename (tmp, path) != 0) {
                FileUtils.unlink (tmp);
                throw new IOError.FAILED (_("The file could not be written"));
            }
        }

        public void open_result (File file) {
            app.open_file (file, null);
        }

        public int[] parse_pages (string text, int total) {
            int[] result = {};
            string t = text.strip ();
            if (t == "" || t.down () == _("all").down ()) {
                for (int i = 0; i < total; i++) result += i;
                return result;
            }
            foreach (var part in t.split (",")) {
                string p = part.strip ();
                if (p == "") continue;
                int dash = p.index_of_char ('-');
                if (dash >= 0) {
                    int a = dash == 0 ? 1 : int.parse (p.substring (0, dash));
                    string rest = p.substring (dash + 1).strip ();
                    int b = rest == "" ? total : int.parse (rest);
                    for (int i = int.max (1, a); i <= int.min (total, b); i++) result += i - 1;
                } else {
                    int n = int.parse (p);
                    if (n >= 1 && n <= total) result += n - 1;
                }
            }
            return result;
        }
    }

    public class HintEntryRow : EntryRow {
        public HintEntryRow (string title, string hint) {
            base (title);
            entry.placeholder_text = hint;
        }
    }

    public abstract class ToolPage : Box {
        public string title { get; construct; }
        public string icon { get; construct; }
        public ProContext ctx;
        public Box footer { get; private set; }
        private Gee.ArrayList<ActionRow> mode_rows = new Gee.ArrayList<ActionRow> ();

        protected ToolPage (string title, string icon) {
            Object (orientation: Orientation.VERTICAL, spacing: 18, title: title, icon: icon);
            margin_top = 6;
            margin_bottom = 24;
            margin_start = 14;
            margin_end = 14;
            footer = new Box (Orientation.HORIZONTAL, 8);
            footer.halign = Align.END;
        }

        public abstract void build ();

        public virtual void enter () {
        }

        public virtual void leave () {
        }

        public virtual void document_changed () {
        }

        protected PreferencesGroup add_group (string title, string? description = null) {
            var g = new PreferencesGroup (title, description);
            append (g);
            return g;
        }

        protected Button header_button (PreferencesGroup group, string label, bool suggested = false) {
            var b = new Button.with_label (label);
            b.valign = Align.CENTER;
            if (suggested) b.add_css_class ("suggested-action");
            group.add_header_suffix (b);
            return b;
        }

        protected Button footer_button (string label, bool suggested = false) {
            var b = new Button.with_label (label);
            b.add_css_class ("pill");
            if (suggested) b.add_css_class ("suggested-action");
            footer.append (b);
            return b;
        }

        protected Label text_row (PreferencesGroup group, string text = "") {
            var label = new Label (text);
            label.wrap = true;
            label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            label.xalign = 0;
            label.selectable = true;
            label.margin_top = 12;
            label.margin_bottom = 12;
            label.margin_start = 12;
            label.margin_end = 12;
            var row = new PreferencesRow ();
            row.activatable = false;
            row.child = label;
            group.add_row (row);
            return label;
        }

        protected ActionRow mode_row (string title, string? subtitle, string icon) {
            var row = new ActionRow (title, subtitle, icon);
            var check = new Image.from_icon_name ("object-select-symbolic");
            check.add_css_class ("reader-mode-check");
            check.visible = false;
            row.add_suffix (check);
            row.set_data<Image> ("mode-check", check);
            mode_rows.add (row);
            return row;
        }

        protected void set_active_mode (ActionRow? active) {
            foreach (var row in mode_rows) {
                bool on = row == active;
                row.get_data<Image> ("mode-check").visible = on;
                if (on) row.add_css_class ("reader-mode-active");
                else row.remove_css_class ("reader-mode-active");
            }
        }

        public void clear_modes () {
            set_active_mode (null);
        }
    }
}
