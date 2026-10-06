using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class CommentPage : ToolPage {
        private Singularity.Pdf.ShapeKind shape = Singularity.Pdf.ShapeKind.RECTANGLE;
        private bool placing_stamp = false;
        private string stamp_label = "";
        private ulong area_handler = 0;
        private ulong poly_handler = 0;
        private ulong point_handler = 0;
        private PreferencesGroup? comments = null;
        private Gee.ArrayList<Widget> comment_rows = new Gee.ArrayList<Widget> ();
        private SelectionRow author_filter;
        private SelectionRow status_filter;
        private SpinRow width_row;
        private SwitchRow fill_row;

        public CommentPage () {
            base (_("Comment"), "reader-note-symbolic");
        }

        private delegate void Handler ();

        private void add_mode (PreferencesGroup group, string title, string icon, owned Handler handler) {
            var row = mode_row (title, null, icon);
            row.activated.connect (() => {
                handler ();
                set_active_mode (row);
            });
            group.add_row (row);
        }

        private void add_action (PreferencesGroup group, string title, string icon, owned Handler handler) {
            var row = new ActionRow (title, null, icon);
            row.activated.connect (() => handler ());
            group.add_row (row);
        }

        public override void build () {
            var draw = add_group (_("Draw"), _("Drag on the page to draw. For polygons and clouds click each corner, then double-click to finish."));
            add_mode (draw, _("Rectangle"), "media-playback-stop-symbolic", () => start_shape (Singularity.Pdf.ShapeKind.RECTANGLE));
            add_mode (draw, _("Ellipse"), "media-record-symbolic", () => start_shape (Singularity.Pdf.ShapeKind.ELLIPSE));
            add_mode (draw, _("Line"), "list-remove-symbolic", () => start_shape (Singularity.Pdf.ShapeKind.LINE));
            add_mode (draw, _("Arrow"), "go-next-symbolic", () => start_shape (Singularity.Pdf.ShapeKind.ARROW));
            add_mode (draw, _("Polygon"), "non-starred-symbolic", () => start_shape (Singularity.Pdf.ShapeKind.POLYGON));
            add_mode (draw, _("Cloud"), "weather-overcast-symbolic", () => start_shape (Singularity.Pdf.ShapeKind.CLOUD));
            width_row = new SpinRow (_("Line Width"), null, 0.5, 12, 0.5, 2);
            draw.add_row (width_row);
            fill_row = new SwitchRow (_("Fill Closed Shapes"), null, false);
            draw.add_row (fill_row);

            var stamps = add_group (_("Stamps"), _("Pick a stamp, then drag on the page where it goes."));
            foreach (var label in new string[] { _("Approved"), _("Draft"), _("Confidential"), _("Final"), _("Not Approved"), _("For Comment"), _("Received") }) {
                string l = label;
                add_mode (stamps, l, "emoji-flags-symbolic", () => start_stamp (l));
            }
            var custom = new HintEntryRow (_("Custom Stamp"), _("Type the text, then press Enter"));
            custom.entry_activated.connect (() => {
                if (custom.text.strip () != "") {
                    start_stamp (custom.text.strip ());
                    set_active_mode (null);
                }
            });
            stamps.add_row (custom);

            comments = add_group (_("Comments"));
            author_filter = new SelectionRow (_("Author"), { _("Everyone") }, _("Everyone"));
            author_filter.selected.connect (() => refresh ());
            comments.add_row (author_filter);
            status_filter = new SelectionRow (_("Status"), { _("Any"), _("None"), "Accepted", "Rejected", "Cancelled", "Completed" }, _("Any"));
            status_filter.selected.connect (() => refresh ());
            comments.add_row (status_filter);

            var exchange = add_group (_("Exchange Comments"));
            add_action (exchange, _("Export as XFDF…"), "document-send-symbolic", () => export_comments.begin (true));
            add_action (exchange, _("Export as FDF…"), "document-send-symbolic", () => export_comments.begin (false));
            add_action (exchange, _("Import Comments…"), "document-open-symbolic", () => import_comments.begin ());
        }

        private double[] color () {
            var hex = ctx.app.settings.get_string ("pen-color");
            return Singularity.Pdf.Annotations.rgb (hex);
        }

        private void disconnect_all () {
            if (area_handler != 0) ctx.view.disconnect (area_handler);
            if (poly_handler != 0) ctx.view.disconnect (poly_handler);
            if (point_handler != 0) ctx.view.disconnect (point_handler);
            area_handler = poly_handler = point_handler = 0;
        }

        private void start_shape (Singularity.Pdf.ShapeKind kind) {
            disconnect_all ();
            shape = kind;
            placing_stamp = false;
            bool poly = kind == Singularity.Pdf.ShapeKind.POLYGON || kind == Singularity.Pdf.ShapeKind.CLOUD || kind == Singularity.Pdf.ShapeKind.POLYLINE;
            ctx.view.tool = poly ? Tool.POLYLINE : Tool.AREA;
            if (poly) {
                poly_handler = ctx.view.polyline_done.connect ((page, pts, widget) => {
                    ctx.run (_("Shape added"), (e) => {
                        double[] pdf = {};
                        for (int i = 0; i + 1 < pts.length; i += 2) {
                            double x, y;
                            PageMap.point_to_pdf (e, page, pts[i], pts[i + 1], out x, out y);
                            pdf += x;
                            pdf += y;
                        }
                        Singularity.Pdf.Annotations.shape (e, page, shape, pdf, color (), fill_row.active ? color () : null, width_row.value, 1, ctx.author, "");
                    });
                });
            } else {
                area_handler = ctx.view.area_picked.connect ((page, area, widget) => on_area (page, area));
            }
        }

        private void on_area (int page, Poppler.Rectangle area) {
            if (placing_stamp) {
                string label = stamp_label;
                ctx.run (_("Stamp added"), (e) => {
                    var r = PageMap.to_pdf (e, page, area);
                    Singularity.Pdf.Annotations.stamp (e, page, r, label, { 0.75, 0.1, 0.1 }, ctx.author);
                });
                return;
            }
            ctx.run (_("Shape added"), (e) => {
                double x1, y1, x2, y2;
                bool line = shape == Singularity.Pdf.ShapeKind.LINE || shape == Singularity.Pdf.ShapeKind.ARROW;
                PageMap.point_to_pdf (e, page, area.x1, area.y1, out x1, out y1);
                PageMap.point_to_pdf (e, page, area.x2, area.y2, out x2, out y2);
                double[] pts = line ? new double[] { x1, y1, x2, y2 } : new double[] { double.min (x1, x2), double.min (y1, y2), double.max (x1, x2), double.max (y1, y2) };
                Singularity.Pdf.Annotations.shape (e, page, shape, pts, color (), fill_row.active && !line ? color () : null, width_row.value, 1, ctx.author, "");
            });
        }

        private void start_stamp (string label) {
            disconnect_all ();
            placing_stamp = true;
            stamp_label = label;
            ctx.view.tool = Tool.AREA;
            area_handler = ctx.view.area_picked.connect ((page, area, widget) => on_area (page, area));
            ctx.toast (_("Drag on the page where the stamp goes"));
        }

        public override void enter () {
            refresh ();
        }

        public override void leave () {
            disconnect_all ();
            ctx.view.cancel_polyline ();
            if (ctx.view.tool == Tool.AREA || ctx.view.tool == Tool.POLYLINE) ctx.view.tool = Tool.SELECT;
        }

        public override void document_changed () {
            refresh ();
        }

        private void refresh () {
            if (comments == null) return;
            foreach (var w in comment_rows) comments.remove_row (w);
            comment_rows.clear ();
            var e = ctx.engine ();
            if (e == null) return;
            var all = Singularity.Pdf.Annotations.list (e);
            var authors = new Gee.TreeSet<string> ();
            foreach (var a in all) if (a.author != "") authors.add (a.author);
            string[] items = { _("Everyone") };
            foreach (var au in authors) items += au;
            string current_author = author_filter.current_value;
            author_filter.set_items (items);
            author_filter.current_value = current_author in items ? current_author : _("Everyone");
            int shown = 0;
            foreach (var a in all) {
                if (a.is_reply || !(a.subtype in Singularity.Pdf.Annotations.MARKUP_TYPES)) continue;
                if (author_filter.current_value != _("Everyone") && a.author != author_filter.current_value) continue;
                string state = Singularity.Pdf.Annotations.current_state (all, a);
                string sf = status_filter.current_value;
                if (sf == _("None") && state != "") continue;
                if (sf != _("Any") && sf != _("None") && state != sf) continue;
                var card = comment_card (e, all, a, state);
                comments.add_row (card);
                comment_rows.add (card);
                shown++;
            }
            comments.description = shown == 0 ? _("No comments match the filter.") : ngettext ("%d comment", "%d comments", shown).printf (shown);
        }

        private Widget comment_card (Singularity.Pdf.Document e, Gee.List<Singularity.Pdf.AnnotInfo> all, Singularity.Pdf.AnnotInfo a, string state) {
            string heading = "%s, %s".printf (a.subtype, _("page %d").printf (a.page + 1));
            string sub = a.author != "" ? a.author : _("Unknown author");
            if (state != "") sub += ", " + state;
            var group = new ExpanderRow (a.contents != "" ? a.contents : heading, a.contents != "" ? heading + ", " + sub : sub);
            int page = a.page;
            var area = PageMap.to_view (e, a.page, a.rect);
            var row = new ActionRow (_("Show in Document"), null, "find-location-symbolic");
            row.activated.connect (() => ctx.view.go_to (page, area.y1));
            group.add_row (row);
            foreach (var r in all) {
                if (r.reply_to != a.reference.num || r.state != "") continue;
                group.add_row (new ActionRow (r.contents, r.author != "" ? _("Reply from %s").printf (r.author) : _("Reply")));
            }
            var reply = new EntryRow (_("Reply"));
            int num = a.reference.num;
            reply.entry_activated.connect (() => {
                string text = reply.text.strip ();
                if (text == "") return;
                ctx.run (_("Reply added"), (en) => Singularity.Pdf.Annotations.reply (en, page, Singularity.Pdf.Obj.reference (num), text, ctx.author));
            });
            group.add_row (reply);
            var status = new SelectionRow (_("Status"), { _("None"), "Accepted", "Rejected", "Cancelled", "Completed" }, state != "" ? state : _("None"));
            status.selected.connect ((value) => {
                string v = value == _("None") ? "None" : value;
                ctx.run (_("Status changed"), (en) => Singularity.Pdf.Annotations.set_state (en, page, Singularity.Pdf.Obj.reference (num), v, ctx.author));
            });
            group.add_row (status);
            var delete = new ActionRow (_("Delete Comment"), null, "user-trash-symbolic");
            delete.activated.connect (() => ctx.run (_("Comment deleted"), (en) => Singularity.Pdf.Annotations.remove (en, page, Singularity.Pdf.Obj.reference (num))));
            group.add_row (delete);
            return group;
        }

        private async void export_comments (bool xfdf) {
            var file = yield ctx.choose_save (xfdf ? _("Export Comments as XFDF") : _("Export Comments as FDF"),
                ctx.base_name () + (xfdf ? ".xfdf" : ".fdf"));
            if (file == null) return;
            try {
                var e = ctx.document.open_engine ();
                string name = ctx.document.file.get_basename () ?? "document.pdf";
                if (xfdf) FileUtils.set_contents (file.get_path (), Singularity.Pdf.Annotations.export_xfdf (e, name));
                else FileUtils.set_data (file.get_path (), Singularity.Pdf.Annotations.export_fdf (e, name));
                ctx.toast (_("Comments exported"));
            } catch (Error err) {
                ctx.error_dialog (_("The comments could not be exported"), err.message);
            }
        }

        private async void import_comments () {
            var file = yield ctx.choose_open (_("Import Comments"), null, "*.[xX][fF][dD][fF]");
            if (file == null) return;
            int count = 0;
            ctx.run ("", (e) => {
                uint8[] data;
                FileUtils.get_data (file.get_path (), out data);
                string name = file.get_basename ().down ();
                if (name.has_suffix (".xfdf")) {
                    var text = new uint8[data.length + 1];
                    Memory.copy (text, data, data.length);
                    count = Singularity.Pdf.Annotations.import_xfdf (e, (string) text);
                } else {
                    count = Singularity.Pdf.Annotations.import_fdf (e, data);
                }
            });
            ctx.toast (ngettext ("%d comment imported", "%d comments imported", count).printf (count));
        }
    }
}
