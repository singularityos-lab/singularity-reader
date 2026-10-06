using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class MeasurePage : ToolPage {
        private enum Kind {
            DISTANCE,
            PERIMETER,
            AREA
        }

        private Kind kind = Kind.DISTANCE;
        private ulong poly_handler = 0;
        private SpinRow paper_row;
        private SelectionRow paper_unit;
        private SpinRow real_row;
        private EntryRow real_unit;
        private Label result;
        private PreferencesGroup result_group;
        private SwitchRow keep_row;

        public MeasurePage () {
            base (_("Measure"), "applications-engineering-symbolic");
        }

        public override void build () {
            var scale = add_group (_("Scale"));
            paper_row = new SpinRow (_("On Paper"), null, 0.001, 100000, 0.1, 1);
            paper_unit = new SelectionRow (_("Paper Unit"), { "cm", "mm", "in", "pt" }, "cm");
            real_row = new SpinRow (_("In Reality"), null, 0.001, 1000000, 0.1, 1);
            real_unit = new EntryRow (_("Real Unit"));
            real_unit.text = "m";
            foreach (var r in new Widget[] { paper_row, paper_unit, real_row, real_unit }) scale.add_row (r);
            var tools = add_group (_("Measure"));
            var dist = mode_row (_("Distance"), _("Click two points"), "list-remove-symbolic");
            dist.activated.connect (() => {
                start (Kind.DISTANCE);
                set_active_mode (dist);
            });
            var per = mode_row (_("Perimeter"), _("Click each point, double-click to end"), "non-starred-symbolic");
            per.activated.connect (() => {
                start (Kind.PERIMETER);
                set_active_mode (per);
            });
            var area = mode_row (_("Area"), _("Click each corner, double-click to end"), "media-playback-stop-symbolic");
            area.activated.connect (() => {
                start (Kind.AREA);
                set_active_mode (area);
            });
            tools.add_row (dist);
            tools.add_row (per);
            tools.add_row (area);
            keep_row = new SwitchRow (_("Keep Measurements as Comments"), null, true);
            tools.add_row (keep_row);
            result_group = add_group (_("Last Measurement"));
            result_group.visible = false;
            result = text_row (result_group);
            result.add_css_class ("title-3");
        }

        private double points_per_unit () {
            switch (paper_unit.current_value) {
                case "mm": return 72.0 / 25.4;
                case "in": return 72.0;
                case "pt": return 1.0;
                default: return 72.0 / 2.54;
            }
        }

        private double factor () {
            return real_row.value / (paper_row.value * points_per_unit ());
        }

        private void start (Kind k) {
            kind = k;
            if (poly_handler != 0) ctx.view.disconnect (poly_handler);
            ctx.view.tool = Tool.POLYLINE;
            poly_handler = ctx.view.polyline_done.connect (on_done);
            ctx.view.poly_limit = k == Kind.DISTANCE ? 2 : 0;
        }

        private void on_done (int page, double[] view_pts, Widget widget) {
            var e = ctx.engine ();
            if (e == null) return;
            double[] pts = {};
            for (int i = 0; i + 1 < view_pts.length; i += 2) {
                double x, y;
                PageMap.point_to_pdf (e, page, view_pts[i], view_pts[i + 1], out x, out y);
                pts += x;
                pts += y;
            }
            if (kind == Kind.DISTANCE && pts.length > 4) pts = pts[0 : 4];
            double f = factor ();
            string unit = real_unit.text.strip () != "" ? real_unit.text.strip () : "m";
            double value;
            string text;
            if (kind == Kind.AREA) {
                double a = 0;
                int n = pts.length / 2;
                for (int i = 0; i < n; i++) {
                    int j = (i + 1) % n;
                    a += pts[i * 2] * pts[j * 2 + 1] - pts[j * 2] * pts[i * 2 + 1];
                }
                value = a.abs () / 2 * f * f;
                text = "%s %s²".printf (fmt (value), unit);
            } else {
                double len = 0;
                for (int i = 2; i + 1 < pts.length; i += 2) len += Math.sqrt (Math.pow (pts[i] - pts[i - 2], 2) + Math.pow (pts[i + 1] - pts[i - 1], 2));
                value = len * f;
                text = "%s %s".printf (fmt (value), unit);
            }
            result.label = text;
            result_group.visible = true;
            if (!keep_row.active) return;
            string ratio = "%s %s = %s %s".printf (fmt (paper_row.value), paper_unit.current_value, fmt (real_row.value), unit);
            var k = kind;
            ctx.run (_("Measurement added"), (en) => {
                var shape = k == Kind.AREA ? Singularity.Pdf.ShapeKind.POLYGON : (k == Kind.PERIMETER ? Singularity.Pdf.ShapeKind.POLYLINE : Singularity.Pdf.ShapeKind.LINE);
                var r = Singularity.Pdf.Annotations.shape (en, page, shape, pts, { 0.1, 0.45, 0.85 }, null, 1, 1, ctx.author, text);
                var a = en.resolve (r);
                a.set ("IT", Singularity.Pdf.Obj.name_obj (k == Kind.AREA ? "PolygonDimension" : (k == Kind.PERIMETER ? "PolyLineDimension" : "LineDimension")));
                var measure = Singularity.Pdf.Obj.dictionary ();
                measure.set ("Type", Singularity.Pdf.Obj.name_obj ("Measure"));
                measure.set ("Subtype", Singularity.Pdf.Obj.name_obj ("RL"));
                measure.set ("R", Singularity.Pdf.Obj.text (ratio));
                var x = Singularity.Pdf.Obj.array ();
                var nf = Singularity.Pdf.Obj.dictionary ();
                nf.set ("Type", Singularity.Pdf.Obj.name_obj ("NumberFormat"));
                nf.set ("U", Singularity.Pdf.Obj.text (unit));
                nf.set ("C", Singularity.Pdf.Obj.number (f));
                nf.set ("D", Singularity.Pdf.Obj.integer (100));
                x.add (nf);
                measure.set ("X", x);
                measure.set ("D", x.clone ());
                var ar = Singularity.Pdf.Obj.array ();
                var af = nf.clone ();
                af.set ("U", Singularity.Pdf.Obj.text (unit + "²"));
                af.set ("C", Singularity.Pdf.Obj.number (f * f));
                ar.add (af);
                measure.set ("A", ar);
                a.set ("Measure", measure);
                if (k == Kind.DISTANCE) a.set ("Cap", Singularity.Pdf.Obj.boolean (true));
            });
        }

        private static string fmt (double v) {
            if (v >= 100) return "%.1f".printf (v);
            if (v >= 1) return "%.2f".printf (v);
            return "%.4f".printf (v);
        }

        public override void leave () {
            if (poly_handler != 0) ctx.view.disconnect (poly_handler);
            poly_handler = 0;
            ctx.view.poly_limit = 0;
            ctx.view.cancel_polyline ();
            if (ctx.view.tool == Tool.POLYLINE) ctx.view.tool = Tool.SELECT;
        }
    }
}
