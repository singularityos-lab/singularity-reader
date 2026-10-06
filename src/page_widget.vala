using Gtk;

namespace Singularity.Apps.Reader {

    public class PageOverlay : Object {
        public Poppler.Rectangle area;
        public string color;
        public bool filled;
        public string label;

        public PageOverlay (Poppler.Rectangle area, string color, bool filled, string label) {
            this.area = area;
            this.color = color;
            this.filled = filled;
            this.label = label;
        }
    }

    public class PageWidget : Widget {
        public int index { get; private set; }
        public unowned DocumentView view;
        public Gdk.Texture? texture = null;
        public double texture_zoom = 0;
        public Cairo.Region? selection = null;
        public double selection_scale = 1;
        public Gee.List<Poppler.Rectangle?> hits = new Gee.ArrayList<Poppler.Rectangle?> ();
        public int current_hit = -1;
        public Gee.List<Gee.List<double?>> strokes = new Gee.ArrayList<Gee.List<double?>> ();
        public string stroke_color = "#1c71d8";
        public double stroke_width = 2;
        public double stroke_alpha = 1;
        public Poppler.Rectangle? outline = null;
        public bool outline_handles = false;
        public Poppler.Rectangle? ghost = null;
        public Gee.List<double?> poly = new Gee.ArrayList<double?> ();
        public Gee.List<PageOverlay> overlays = new Gee.ArrayList<PageOverlay> ();

        public PageWidget (DocumentView view, int index) {
            this.view = view;
            this.index = index;
            add_css_class ("reader-page");
            overflow = Overflow.HIDDEN;
            halign = Align.CENTER;
        }

        public override SizeRequestMode get_request_mode () {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure (Orientation orientation, int for_size, out int minimum, out int natural,
                                      out int minimum_baseline, out int natural_baseline) {
            double size = orientation == Orientation.HORIZONTAL ? view.document.width (index) : view.document.height (index);
            minimum = natural = (int) Math.round (size * view.zoom);
            minimum_baseline = natural_baseline = -1;
        }

        public void invalidate () {
            texture = null;
            texture_zoom = 0;
            queue_draw ();
        }

        private Gdk.RGBA rgba (string hex, double alpha) {
            var c = Gdk.RGBA ();
            if (!c.parse (hex)) c.parse ("#1c71d8");
            c.alpha = (float) alpha;
            return c;
        }

        public override void snapshot (Snapshot snapshot) {
            float w = get_width (), h = get_height ();
            var bounds = Graphene.Rect ().init (0, 0, w, h);
            var white = Gdk.RGBA ();
            white.parse ("white");
            snapshot.append_color (white, bounds);
            if (texture != null) {
                snapshot.append_scaled_texture (texture, Gsk.ScalingFilter.TRILINEAR, bounds);
            }
            if (texture == null || texture_zoom != view.zoom) view.request_render (this);
            double z = view.zoom;

            var hit_color = rgba ("#f6d32d", 0.45);
            var current_color = rgba ("#ff7800", 0.55);
            for (int i = 0; i < hits.size; i++) {
                var r = hits[i];
                var rect = Graphene.Rect ().init ((float) (r.x1 * z), (float) (r.y1 * z), (float) ((r.x2 - r.x1) * z), (float) ((r.y2 - r.y1) * z));
                snapshot.append_color (i == current_hit ? current_color : hit_color, rect);
            }

            if (selection != null) {
                var sel_color = rgba ("#3584e4", 0.30);
                int n = selection.num_rectangles ();
                double k = z / selection_scale;
                for (int i = 0; i < n; i++) {
                    Cairo.RectangleInt r = selection.get_rectangle (i);
                    var rect = Graphene.Rect ().init ((float) (r.x * k), (float) (r.y * k), (float) (r.width * k), (float) (r.height * k));
                    snapshot.append_color (sel_color, rect);
                }
            }

            if (strokes.size > 0) {
                var cr = snapshot.append_cairo (bounds);
                var c = rgba (stroke_color, stroke_alpha);
                cr.set_source_rgba (c.red, c.green, c.blue, c.alpha);
                cr.set_line_width (stroke_width * z);
                cr.set_line_cap (Cairo.LineCap.ROUND);
                cr.set_line_join (Cairo.LineJoin.ROUND);
                foreach (var stroke in strokes) {
                    for (int i = 0; i + 1 < stroke.size; i += 2) {
                        if (i == 0) cr.move_to (stroke[i] * z, stroke[i + 1] * z);
                        else cr.line_to (stroke[i] * z, stroke[i + 1] * z);
                    }
                    cr.stroke ();
                }
            }

            if (overlays.size > 0) {
                var cr = snapshot.append_cairo (bounds);
                foreach (var o in overlays) {
                    var c = rgba (o.color, 1);
                    cr.rectangle (o.area.x1 * z, o.area.y1 * z, (o.area.x2 - o.area.x1) * z, (o.area.y2 - o.area.y1) * z);
                    if (o.filled) {
                        cr.set_source_rgba (c.red, c.green, c.blue, 0.28);
                        cr.fill_preserve ();
                    }
                    cr.set_source_rgba (c.red, c.green, c.blue, 0.95);
                    cr.set_line_width (1.5);
                    cr.stroke ();
                    if (o.label != "") {
                        cr.select_font_face ("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
                        cr.set_font_size (10);
                        cr.move_to (o.area.x1 * z + 2, o.area.y1 * z - 3);
                        cr.show_text (o.label);
                    }
                }
            }

            if (poly.size >= 2) {
                var cr = snapshot.append_cairo (bounds);
                var accent = rgba ("#3584e4", 1);
                cr.set_source_rgba (accent.red, accent.green, accent.blue, 0.95);
                cr.set_line_width (1.5);
                for (int i = 0; i + 1 < poly.size; i += 2) {
                    if (i == 0) cr.move_to (poly[i] * z, poly[i + 1] * z);
                    else cr.line_to (poly[i] * z, poly[i + 1] * z);
                }
                cr.stroke ();
                for (int i = 0; i + 1 < poly.size; i += 2) {
                    cr.arc (poly[i] * z, poly[i + 1] * z, 3, 0, 2 * Math.PI);
                    cr.fill ();
                }
            }

            if (ghost != null) {
                var cr = snapshot.append_cairo (bounds);
                var accent = rgba ("#3584e4", 1);
                cr.set_source_rgba (accent.red, accent.green, accent.blue, 0.15);
                cr.rectangle (ghost.x1 * z, ghost.y1 * z, (ghost.x2 - ghost.x1) * z, (ghost.y2 - ghost.y1) * z);
                cr.fill_preserve ();
                cr.set_source_rgba (accent.red, accent.green, accent.blue, 0.9);
                cr.set_line_width (1.5);
                cr.set_dash ({ 5, 3 }, 0);
                cr.stroke ();
            }

            if (outline != null) {
                var cr = snapshot.append_cairo (bounds);
                var accent = rgba ("#3584e4", 1);
                cr.set_source_rgba (accent.red, accent.green, accent.blue, 0.95);
                cr.set_line_width (1.5);
                double x = outline.x1 * z - 3, y = outline.y1 * z - 3;
                double ow = (outline.x2 - outline.x1) * z + 6, oh = (outline.y2 - outline.y1) * z + 6;
                cr.rectangle (x, y, ow, oh);
                cr.stroke ();
                if (outline_handles) {
                    double[] hx = { x, x + ow, x, x + ow };
                    double[] hy = { y, y, y + oh, y + oh };
                    for (int i = 0; i < 4; i++) {
                        cr.arc (hx[i], hy[i], 5, 0, 2 * Math.PI);
                        cr.set_source_rgba (1, 1, 1, 1);
                        cr.fill_preserve ();
                        cr.set_source_rgba (accent.red, accent.green, accent.blue, 1);
                        cr.stroke ();
                    }
                }
            }
        }
    }
}
