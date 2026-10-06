namespace Singularity.Apps.Reader {

    public class Geometry : Object {
        public static Poppler.Rectangle rect (double x1, double y1, double x2, double y2) {
            var r = Poppler.Rectangle ();
            r.x1 = double.min (x1, x2);
            r.y1 = double.min (y1, y2);
            r.x2 = double.max (x1, x2);
            r.y2 = double.max (y1, y2);
            return r;
        }

        public static Poppler.Rectangle to_pdf (Poppler.Rectangle view, double page_height) {
            return rect (view.x1, page_height - view.y2, view.x2, page_height - view.y1);
        }

        public static Poppler.Rectangle to_view (Poppler.Rectangle pdf, double page_height) {
            return rect (pdf.x1, page_height - pdf.y2, pdf.x2, page_height - pdf.y1);
        }

        public static bool contains (Poppler.Rectangle r, double x, double y) {
            return x >= r.x1 && x <= r.x2 && y >= r.y1 && y <= r.y2;
        }

        public static void unrotate (int rotation, double width, double height, ref double x, ref double y) {
            double t;
            switch (rotation) {
                case 90: t = x; x = height - y; y = t; break;
                case 180: x = width - x; y = height - y; break;
                case 270: t = x; x = y; y = width - t; break;
                default: break;
            }
        }

        private static Poppler.Point point (double x, double y) {
            var p = Poppler.Point ();
            p.x = x;
            p.y = y;
            return p;
        }

        public static Poppler.Quadrilateral quad_for (Poppler.Rectangle[] glyphs, int first, int last, double page_height) {
            var bounds = glyphs[first];
            for (int i = first + 1; i <= last; i++) {
                bounds.x1 = double.min (bounds.x1, glyphs[i].x1);
                bounds.y1 = double.min (bounds.y1, glyphs[i].y1);
                bounds.x2 = double.max (bounds.x2, glyphs[i].x2);
                bounds.y2 = double.max (bounds.y2, glyphs[i].y2);
            }
            double left = bounds.x1, right = bounds.x2;
            double bottom = page_height - bounds.y2, top = page_height - bounds.y1;
            double dx = (glyphs[last].x1 + glyphs[last].x2) - (glyphs[first].x1 + glyphs[first].x2);
            double dy = (glyphs[last].y1 + glyphs[last].y2) - (glyphs[first].y1 + glyphs[first].y2);
            var q = Poppler.Quadrilateral ();
            if (dx.abs () >= dy.abs () && dx >= 0) {
                q.p1 = point (left, top); q.p2 = point (right, top); q.p3 = point (left, bottom); q.p4 = point (right, bottom);
            } else if (dx.abs () >= dy.abs ()) {
                q.p1 = point (right, bottom); q.p2 = point (left, bottom); q.p3 = point (right, top); q.p4 = point (left, top);
            } else if (dy > 0) {
                q.p1 = point (right, top); q.p2 = point (right, bottom); q.p3 = point (left, top); q.p4 = point (left, bottom);
            } else {
                q.p1 = point (left, bottom); q.p2 = point (left, top); q.p3 = point (right, bottom); q.p4 = point (right, top);
            }
            return q;
        }

        private static bool overlaps (double a1, double a2, double b1, double b2) {
            double overlap = double.min (a2, b2) - double.max (a1, b1);
            double smallest = double.min (a2 - a1, b2 - b1);
            return smallest <= 0 ? false : overlap >= smallest * 0.5;
        }

        public static Gee.List<int> line_breaks (Poppler.Rectangle[] glyphs) {
            var starts = new Gee.ArrayList<int> ();
            if (glyphs.length == 0) return starts;
            starts.add (0);
            int line_start = 0;
            for (int i = 1; i < glyphs.length; i++) {
                var prev = glyphs[i - 1];
                var cur = glyphs[i];
                double dx = (prev.x1 + prev.x2) - (glyphs[line_start].x1 + glyphs[line_start].x2);
                double dy = (prev.y1 + prev.y2) - (glyphs[line_start].y1 + glyphs[line_start].y2);
                if (dx == 0 && dy == 0) {
                    dx = (cur.x1 + cur.x2) - (prev.x1 + prev.x2);
                    dy = (cur.y1 + cur.y2) - (prev.y1 + prev.y2);
                }
                bool horizontal = dx.abs () >= dy.abs ();
                bool same = horizontal ? overlaps (prev.y1, prev.y2, cur.y1, cur.y2) : overlaps (prev.x1, prev.x2, cur.x1, cur.x2);
                if (!same) {
                    starts.add (i);
                    line_start = i;
                }
            }
            return starts;
        }

        public static GLib.Array<Poppler.Quadrilateral> quads (Poppler.Rectangle[] glyphs, double page_height, out Poppler.Rectangle bounds,
                                                            Gee.List<int>? line_starts = null) {
            var result = new GLib.Array<Poppler.Quadrilateral> (false, false, (uint) sizeof (Poppler.Quadrilateral));
            bounds = rect (0, 0, 0, 0);
            if (glyphs.length == 0) return result;
            var starts = line_starts ?? line_breaks (glyphs);
            bool first = true;
            for (int i = 0; i < starts.size; i++) {
                int a = starts[i];
                int b = i + 1 < starts.size ? starts[i + 1] - 1 : glyphs.length - 1;
                var q = quad_for (glyphs, a, b, page_height);
                result.append_val (q);
                double qx1 = double.min (double.min (q.p1.x, q.p2.x), double.min (q.p3.x, q.p4.x));
                double qx2 = double.max (double.max (q.p1.x, q.p2.x), double.max (q.p3.x, q.p4.x));
                double qy1 = double.min (double.min (q.p1.y, q.p2.y), double.min (q.p3.y, q.p4.y));
                double qy2 = double.max (double.max (q.p1.y, q.p2.y), double.max (q.p3.y, q.p4.y));
                if (first) {
                    bounds = rect (qx1, qy1, qx2, qy2);
                    first = false;
                } else {
                    bounds = rect (double.min (bounds.x1, qx1), double.min (bounds.y1, qy1),
                                   double.max (bounds.x2, qx2), double.max (bounds.y2, qy2));
                }
            }
            return result;
        }

        public static Poppler.Color color (string hex) {
            string text = hex.strip ();
            if (text.has_prefix ("#")) text = text.substring (1);
            if (text.length == 3) text = "%c%c%c%c%c%c".printf (text[0], text[0], text[1], text[1], text[2], text[2]);
            uint64 value = 0;
            if (text.length != 6 || !uint64.try_parse (text, out value, null, 16)) value = 0xf5c211;
            var c = Poppler.Color ();
            c.red = (uint16) (((value >> 16) & 0xff) * 257);
            c.green = (uint16) (((value >> 8) & 0xff) * 257);
            c.blue = (uint16) ((value & 0xff) * 257);
            return c;
        }

        public static string hex (Poppler.Color c) {
            return "#%02x%02x%02x".printf (c.red >> 8, c.green >> 8, c.blue >> 8);
        }
    }
}
