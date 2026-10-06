using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class ReflowView : Box {
        private TextView text;
        private double size = 13;
        private CssProvider provider = new CssProvider ();

        public signal void closed ();

        public ReflowView () {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            text = new TextView ();
            text.editable = false;
            text.cursor_visible = false;
            text.wrap_mode = WrapMode.WORD_CHAR;
            text.pixels_below_lines = 6;
            text.top_margin = 32;
            text.bottom_margin = 64;
            text.left_margin = 24;
            text.right_margin = 24;
            text.add_css_class ("reader-reflow");
            text.get_style_context ().add_provider (provider, STYLE_PROVIDER_PRIORITY_USER + 10);
            var clamp = new Clamp (text, 760);
            var scroll = new ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = clamp;
            Singularity.Widgets.apply_titlebar_inset (clamp);
            var bar = new Box (Orientation.HORIZONTAL, 6);
            bar.halign = Align.CENTER;
            bar.margin_top = 6;
            bar.margin_bottom = 6;
            var smaller = new Button.from_icon_name ("zoom-out-symbolic");
            smaller.tooltip_text = _("Smaller Text");
            smaller.clicked.connect (() => set_size (size - 1));
            var larger = new Button.from_icon_name ("zoom-in-symbolic");
            larger.tooltip_text = _("Larger Text");
            larger.clicked.connect (() => set_size (size + 1));
            var back = new Button.with_label (_("Back to Pages"));
            back.clicked.connect (() => closed ());
            bar.append (smaller);
            bar.append (larger);
            bar.append (back);
            append (bar);
            append (scroll);
            set_size (size);
        }

        private void set_size (double s) {
            size = s.clamp (9, 40);
            provider.load_from_string ("textview.reader-reflow { font-size: %gpt; }".printf (size));
        }

        public void load (ReaderDocument doc, int from_page) {
            var buffer = text.buffer;
            buffer.text = "";
            TextIter end;
            var heading = buffer.create_tag (null, "weight", Pango.Weight.BOLD, "scale", 1.3);
            var page_tag = buffer.create_tag (null, "foreground", "#888888", "scale", 0.8);
            for (int p = 0; p < doc.n_pages; p++) {
                buffer.get_end_iter (out end);
                if (p == from_page) {
                    buffer.create_mark ("start", end, true);
                }
                buffer.insert_with_tags (ref end, _("Page %d").printf (p + 1) + "\n", -1, page_tag);
                foreach (var para in paragraphs (doc, p)) {
                    buffer.get_end_iter (out end);
                    if (para.heading) buffer.insert_with_tags (ref end, para.text + "\n", -1, heading);
                    else buffer.insert (ref end, para.text + "\n", -1);
                }
            }
            var mark = buffer.get_mark ("start");
            if (mark != null) Idle.add (() => {
                text.scroll_to_mark (mark, 0, true, 0, 0);
                return Source.REMOVE;
            });
        }

        private class Para {
            public string text;
            public bool heading;
        }

        private Gee.ArrayList<Para> paragraphs (ReaderDocument doc, int index) {
            var result = new Gee.ArrayList<Para> ();
            string raw = doc.text (index);
            var cur = new StringBuilder ();
            foreach (var line in raw.split ("\n")) {
                string l = line.strip ();
                if (l == "") {
                    if (cur.len > 0) {
                        result.add (make (cur.str));
                        cur.truncate ();
                    }
                    continue;
                }
                if (cur.len > 0) {
                    if (cur.str.has_suffix ("-")) cur.truncate (cur.len - 1);
                    else cur.append_c (' ');
                }
                cur.append (l);
                if (l.has_suffix (".") || l.has_suffix (":") || l.char_count () < 45) {
                    result.add (make (cur.str));
                    cur.truncate ();
                }
            }
            if (cur.len > 0) result.add (make (cur.str));
            return result;
        }

        private Para make (string text) {
            var p = new Para ();
            p.text = text;
            p.heading = text.char_count () < 60 && !text.has_suffix (".") && text.get_char (0).isupper () && !text.contains (",");
            return p;
        }
    }

    public class Recovery : Object {
        private uint source = 0;
        private string dir;

        public Recovery () {
            dir = Path.build_filename (Environment.get_user_state_dir (), "singularity-reader", "recovery");
        }

        private string path_for (File file) {
            return Path.build_filename (dir, Checksum.compute_for_string (ChecksumType.SHA256, file.get_uri ()) + ".pdf");
        }

        public void schedule (ReaderDocument doc) {
            if (source != 0) Source.remove (source);
            source = Timeout.add_seconds (4, () => {
                source = 0;
                if (!doc.modified) return Source.REMOVE;
                try {
                    DirUtils.create_with_parents (dir, 0700);
                    var bytes = doc.current_bytes ();
                    string path = path_for (doc.file);
                    FileUtils.set_data (path + ".part", bytes);
                    FileUtils.rename (path + ".part", path);
                    var kf = new KeyFile ();
                    kf.set_string ("Recovery", "Uri", doc.file.get_uri ());
                    kf.set_int64 ("Recovery", "Time", new DateTime.now_utc ().to_unix ());
                    kf.save_to_file (path + ".ini");
                } catch (Error e) {
                    warning ("Recovery copy failed: %s", e.message);
                }
                return Source.REMOVE;
            });
        }

        public void discard (File file) {
            if (source != 0) {
                Source.remove (source);
                source = 0;
            }
            string path = path_for (file);
            FileUtils.unlink (path);
            FileUtils.unlink (path + ".ini");
        }

        public void offer (ReaderWindow window, ReaderDocument doc) {
            string path = path_for (doc.file);
            if (!FileUtils.test (path, FileTest.EXISTS)) return;
            int64 saved = 0;
            try {
                var kf = new KeyFile ();
                kf.load_from_file (path + ".ini", KeyFileFlags.NONE);
                saved = kf.get_int64 ("Recovery", "Time");
                var info = doc.file.query_info (FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                if (info.get_modification_date_time ().to_unix () > saved) {
                    discard (doc.file);
                    return;
                }
            } catch (Error e) {
            }
            var app = (Gtk.Application) window.application;
            var dlg = new ConfirmDialog (app, _("Recover Unsaved Changes?"), "document-open-recent",
                _("Reader closed before your last changes to \"%s\" were saved. Restore them?").printf (doc.title ()),
                _("Restore"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = window;
            dlg.set_secondary (_("Discard"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) {
                    try {
                        uint8[] data;
                        FileUtils.get_data (path, out data);
                        doc.replace_bytes (data);
                    } catch (Error e) {
                        warning ("Recovery failed: %s", e.message);
                    }
                } else if (r == ConfirmDialog.Response.SECONDARY) {
                    discard (doc.file);
                }
            });
            dlg.present ();
        }
    }
}
