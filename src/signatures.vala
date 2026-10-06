using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class SignatureStore : Object {
        public signal void changed ();

        public static string directory () {
            return Path.build_filename (Environment.get_user_data_dir (), "singularity-reader", "signatures");
        }

        public Gee.List<string> list () {
            var result = new Gee.ArrayList<string> ();
            try {
                var dir = Dir.open (directory ());
                string? name;
                while ((name = dir.read_name ()) != null) {
                    if (name.has_suffix (".png")) result.add (Path.build_filename (directory (), name));
                }
            } catch (FileError e) {
            }
            result.sort ((a, b) => strcmp (b, a));
            return result;
        }

        public string save (Cairo.ImageSurface surface) throws Error {
            DirUtils.create_with_parents (directory (), 0700);
            string path = Path.build_filename (directory (), "signature-%s.png".printf (new DateTime.now_utc ().format ("%Y%m%d%H%M%S")));
            var status = surface.write_to_png (path);
            if (status != Cairo.Status.SUCCESS) throw new IOError.FAILED (status.to_string ());
            changed ();
            return path;
        }

        public void remove (string path) {
            FileUtils.remove (path);
            changed ();
        }

        public static Cairo.ImageSurface? load (string path) {
            var surface = new Cairo.ImageSurface.from_png (path);
            if (surface.status () != Cairo.Status.SUCCESS) return null;
            return surface;
        }

        public static Cairo.ImageSurface crop (Cairo.ImageSurface source) {
            source.flush ();
            int w = source.get_width (), h = source.get_height (), stride = source.get_stride ();
            unowned uchar[] data = source.get_data ();
            int x1 = w, y1 = h, x2 = -1, y2 = -1;
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    if (data[y * stride + x * 4 + 3] > 8) {
                        x1 = int.min (x1, x); x2 = int.max (x2, x);
                        y1 = int.min (y1, y); y2 = int.max (y2, y);
                    }
                }
            }
            if (x2 < 0) return source;
            int pad = 6;
            x1 = int.max (0, x1 - pad); y1 = int.max (0, y1 - pad);
            x2 = int.min (w - 1, x2 + pad); y2 = int.min (h - 1, y2 + pad);
            var result = new Cairo.ImageSurface (Cairo.Format.ARGB32, x2 - x1 + 1, y2 - y1 + 1);
            var cr = new Cairo.Context (result);
            cr.set_source_surface (source, -x1, -y1);
            cr.paint ();
            return result;
        }

        public static Cairo.ImageSurface? from_image (string path) {
            Gdk.Texture texture;
            try {
                texture = Gdk.Texture.from_filename (path);
            } catch (Error e) {
                return null;
            }
            int w = texture.get_width (), h = texture.get_height ();
            double scale = double.min (1.0, 1200.0 / int.max (w, h));
            int tw = int.max (1, (int) (w * scale)), th = int.max (1, (int) (h * scale));
            var full = new Cairo.ImageSurface (Cairo.Format.ARGB32, w, h);
            full.flush ();
            texture.download (full.get_data (), full.get_stride ());
            full.mark_dirty ();
            var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, tw, th);
            var scr = new Cairo.Context (surface);
            scr.scale (scale, scale);
            scr.set_source_surface (full, 0, 0);
            scr.paint ();
            surface.flush ();
            unowned uchar[] data = surface.get_data ();
            int stride = surface.get_stride ();
            int[] histogram = new int[256];
            int opaque = 0;
            for (int y = 0; y < th; y++) {
                for (int x = 0; x < tw; x++) {
                    int o = y * stride + x * 4;
                    int a = data[o + 3];
                    if (a < 128) continue;
                    int lum = (int) ((data[o + 2] * 299 + data[o + 1] * 587 + data[o] * 114) / 1000.0 * 255.0 / int.max (1, a));
                    histogram[lum.clamp (0, 255)]++;
                    opaque++;
                }
            }
            if (opaque == 0) return null;
            double sum = 0;
            for (int i = 0; i < 256; i++) sum += i * histogram[i];
            double sum_b = 0, best = -1;
            int weight_b = 0, threshold = 128;
            for (int t = 0; t < 256; t++) {
                weight_b += histogram[t];
                if (weight_b == 0) continue;
                int weight_f = opaque - weight_b;
                if (weight_f == 0) break;
                sum_b += t * histogram[t];
                double mean_b = sum_b / weight_b, mean_f = (sum - sum_b) / weight_f;
                double between = (double) weight_b * weight_f * (mean_b - mean_f) * (mean_b - mean_f);
                if (between > best) {
                    best = between;
                    threshold = t;
                }
            }
            int dark = 0;
            for (int i = 0; i <= threshold; i++) dark += histogram[i];
            bool ink_is_dark = dark <= opaque - dark;
            var result = new Cairo.ImageSurface (Cairo.Format.ARGB32, tw, th);
            result.flush ();
            unowned uchar[] out_data = result.get_data ();
            int out_stride = result.get_stride ();
            for (int y = 0; y < th; y++) {
                for (int x = 0; x < tw; x++) {
                    int o = y * stride + x * 4;
                    int a = data[o + 3];
                    int lum = a == 0 ? 255 : (int) ((data[o + 2] * 299 + data[o + 1] * 587 + data[o] * 114) / 1000.0 * 255.0 / a);
                    bool ink = a >= 128 && (ink_is_dark ? lum <= threshold : lum > threshold);
                    int p = y * out_stride + x * 4;
                    out_data[p] = 0; out_data[p + 1] = 0; out_data[p + 2] = 0;
                    out_data[p + 3] = ink ? 255 : 0;
                }
            }
            result.mark_dirty ();
            return crop (result);
        }
    }

    public class SignaturePad : DrawingArea {
        private Gee.ArrayList<Gee.ArrayList<double?>> strokes = new Gee.ArrayList<Gee.ArrayList<double?>> ();
        private Gee.ArrayList<double?>? current = null;
        public signal void changed ();

        public SignaturePad () {
            add_css_class ("reader-signature-pad");
            set_size_request (440, 180);
            hexpand = true;
            set_draw_func (draw);
            var drag = new GestureDrag ();
            drag.drag_begin.connect ((x, y) => {
                current = new Gee.ArrayList<double?> ();
                current.add (x);
                current.add (y);
                strokes.add (current);
                queue_draw ();
            });
            drag.drag_update.connect ((dx, dy) => {
                double sx, sy;
                drag.get_start_point (out sx, out sy);
                current.add (sx + dx);
                current.add (sy + dy);
                queue_draw ();
            });
            drag.drag_end.connect (() => {
                current = null;
                changed ();
            });
            add_controller (drag);
            set_cursor_from_name ("crosshair");
        }

        public bool empty { get { return strokes.size == 0; } }

        public void clear () {
            strokes.clear ();
            queue_draw ();
            changed ();
        }

        public void undo () {
            if (strokes.size > 0) strokes.remove_at (strokes.size - 1);
            queue_draw ();
            changed ();
        }

        private void paint (Cairo.Context cr, double r, double g, double b) {
            cr.set_source_rgb (r, g, b);
            cr.set_line_width (3.2);
            cr.set_line_cap (Cairo.LineCap.ROUND);
            cr.set_line_join (Cairo.LineJoin.ROUND);
            foreach (var s in strokes) {
                if (s.size == 2) {
                    cr.arc (s[0], s[1], 1.6, 0, 2 * Math.PI);
                    cr.fill ();
                    continue;
                }
                cr.move_to (s[0], s[1]);
                for (int i = 2; i + 3 < s.size; i += 2) {
                    double mx = (s[i] + s[i + 2]) / 2, my = (s[i + 1] + s[i + 3]) / 2;
                    cr.curve_to (s[i], s[i + 1], s[i], s[i + 1], mx, my);
                }
                cr.line_to (s[s.size - 2], s[s.size - 1]);
                cr.stroke ();
            }
        }

        private void draw (DrawingArea area, Cairo.Context cr, int width, int height) {
            var fg = get_color ();
            cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.25);
            cr.set_line_width (1);
            cr.move_to (24, height - 44);
            cr.line_to (width - 24, height - 44);
            cr.stroke ();
            paint (cr, fg.red, fg.green, fg.blue);
        }

        public Cairo.ImageSurface render () {
            int w = get_width () * 2, h = get_height () * 2;
            var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, int.max (1, w), int.max (1, h));
            var cr = new Cairo.Context (surface);
            cr.scale (2, 2);
            paint (cr, 0, 0, 0);
            return SignatureStore.crop (surface);
        }
    }

    public class SignatureDialog : AppDialog {
        private SignaturePad pad;
        private SignatureStore store;
        private Button save_btn;
        public signal void created (string path);

        public SignatureDialog (Gtk.Application app, SignatureStore store) {
            base (app, true);
            this.store = store;
            set_title (_("New Signature"));
            set_default_size (520, -1);
            var body = new Box (Orientation.VERTICAL, 12);
            body.margin_top = 8;
            body.margin_bottom = 16;
            body.margin_start = 20;
            body.margin_end = 20;
            var hint = new Label (_("Sign with the mouse, a touchpad or a pen, or import a picture of your signature."));
            hint.wrap = true;
            hint.xalign = 0;
            hint.add_css_class ("dim-label");
            body.append (hint);
            var frame = new Frame (null);
            frame.add_css_class ("reader-signature-frame");
            pad = new SignaturePad ();
            frame.child = pad;
            body.append (frame);

            var actions = new Box (Orientation.HORIZONTAL, 8);
            var import_btn = new Button.with_label (_("Import Image"));
            import_btn.clicked.connect (import_image);
            var undo = new Button.from_icon_name ("edit-undo-symbolic");
            undo.tooltip_text = _("Undo");
            undo.clicked.connect (() => pad.undo ());
            var clear = new Button.with_label (_("Clear"));
            clear.clicked.connect (() => pad.clear ());
            var spacer = new Box (Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            var cancel = new Button.with_label (_("Cancel"));
            cancel.clicked.connect (() => close_dialog ());
            set_cancel_button (cancel);
            save_btn = new Button.with_label (_("Save"));
            save_btn.add_css_class ("suggested-action");
            save_btn.sensitive = false;
            save_btn.clicked.connect (() => {
                try {
                    string path = store.save (pad.render ());
                    close_dialog ();
                    created (path);
                } catch (Error e) {
                    hint.label = _("The signature could not be saved: %s").printf (e.message);
                }
            });
            pad.changed.connect (() => save_btn.sensitive = !pad.empty);
            actions.append (import_btn);
            actions.append (undo);
            actions.append (clear);
            actions.append (spacer);
            actions.append (cancel);
            actions.append (save_btn);
            body.append (actions);
            content_box.append (body);
        }

        private void import_image () {
            var dialog = new FileDialog ();
            dialog.title = _("Import Signature");
            var filter = new FileFilter ();
            filter.name = _("Images");
            filter.add_mime_type ("image/png");
            filter.add_mime_type ("image/jpeg");
            filter.add_mime_type ("image/svg+xml");
            filter.add_mime_type ("image/webp");
            var filters = new GLib.ListStore (typeof (FileFilter));
            filters.append (filter);
            dialog.filters = filters;
            dialog.open.begin (this, null, (obj, res) => {
                try {
                    var file = dialog.open.end (res);
                    var surface = SignatureStore.from_image (file.get_path ());
                    if (surface == null) return;
                    string path = store.save (surface);
                    close_dialog ();
                    created (path);
                } catch (Error e) {
                }
            });
        }
    }
}
