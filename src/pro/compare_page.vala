using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class ComparePage : ToolPage {
        private PreferencesGroup changes;
        private File? other = null;
        private SwitchRow visual;

        public ComparePage () {
            base (_("Compare Files"), "edit-copy-symbolic");
        }

        public override void build () {
            var group = add_group (_("Older Version"), _("Compares this document with an older version: changed words are highlighted here, removed words are listed below."));
            var pick = new ActionRow (_("Choose File…"), null, "document-open-symbolic");
            pick.activated.connect (() => {
                ctx.choose_open.begin (_("Choose the Older Version"), "application/pdf", null, (obj, res) => {
                    var f = ctx.choose_open.end (res);
                    if (f == null) return;
                    other = f;
                    pick.subtitle = f.get_basename ();
                    run ();
                });
            });
            group.add_row (pick);
            visual = new SwitchRow (_("Also Compare Appearance"), _("Marks areas that look different, like moved pictures"), true);
            group.add_row (visual);
            changes = add_group (_("Changes"));
            changes.visible = false;
        }

        private void run () {
            if (other == null) return;
            var current = ctx.engine ();
            if (current == null) return;
            ctx.view.clear_overlays ();
            changes.clear ();
            try {
                var old_doc = Singularity.Pdf.Document.open_file (other.get_path ());
                var result = Singularity.Pdf.Compare.documents (old_doc, current);
                int visual_regions = 0;
                if (visual.active) visual_regions = compare_pixels (current, result);
                changes.visible = true;
                changes.description = result.identical && visual_regions == 0 ? _("The documents are identical.") :
                    _("%d words added, %d words removed, %d passages changed, %d pages added, %d pages removed, %d areas look different.").printf (
                        result.inserted_words, result.deleted_words, result.replaced, result.pages_added, result.pages_removed, visual_regions);
                var group = changes;
                int shown = 0;
                foreach (var c in result.changes) {
                    foreach (var b in c.boxes_b) {
                        ctx.view.add_overlay (c.page_b, PageMap.to_view (current, c.page_b, b), c.kind == Singularity.Pdf.ChangeKind.INSERTED ? "#26a269" : "#e5a50a", true);
                    }
                    string title;
                    string sub;
                    switch (c.kind) {
                        case Singularity.Pdf.ChangeKind.INSERTED: title = c.new_text; sub = _("Added"); break;
                        case Singularity.Pdf.ChangeKind.DELETED: title = c.old_text; sub = _("Removed"); break;
                        case Singularity.Pdf.ChangeKind.REPLACED: title = _("\"%s\" became \"%s\"").printf (c.old_text, c.new_text); sub = _("Changed"); break;
                        case Singularity.Pdf.ChangeKind.PAGE_ADDED: title = c.new_text; sub = _("Page added"); break;
                        default: title = c.old_text; sub = _("Page removed"); break;
                    }
                    if (title.char_count () > 90) title = title.substring (0, title.index_of_nth_char (90)) + "…";
                    int page = c.page_b >= 0 ? c.page_b : int.max (0, int.min (c.page_a, ctx.document.n_pages - 1));
                    var row = new ActionRow (title, "%s, %s".printf (sub, _("page %d").printf (page + 1)));
                    double y = c.boxes_b.size > 0 ? PageMap.to_view (current, page, c.boxes_b[0]).y1 : -1;
                    row.activated.connect (() => ctx.view.go_to (page, y));
                    group.add_row (row);
                    if (++shown >= 500) break;
                }

            } catch (Error e) {
                ctx.error_dialog (_("The files could not be compared"), e.message);
            }
        }

        private int compare_pixels (Singularity.Pdf.Document current, Singularity.Pdf.CompareResult result) throws Error {
            var old_poppler = new Poppler.Document.from_file (other.get_uri (), null);
            int pages = int.min (old_poppler.get_n_pages (), ctx.document.n_pages);
            int regions = 0;
            const double SCALE = 1.0;
            const int CELL = 12;
            for (int p = 0; p < pages; p++) {
                var a = render (old_poppler.get_page (p), SCALE);
                var b = render (ctx.document.page (p), SCALE);
                int w = int.min (a.get_width (), b.get_width ()), h = int.min (a.get_height (), b.get_height ());
                unowned uint8[] da = a.get_data ();
                unowned uint8[] db = b.get_data ();
                int sa = a.get_stride (), sb = b.get_stride ();
                for (int cy = 0; cy < h; cy += CELL) {
                    for (int cx = 0; cx < w; cx += CELL) {
                        int diff = 0;
                        for (int y = cy; y < int.min (h, cy + CELL); y++) {
                            for (int x = cx; x < int.min (w, cx + CELL); x++) {
                                int oa = y * sa + x * 4, ob = y * sb + x * 4;
                                int d = ((int) da[oa] - (int) db[ob]).abs () + ((int) da[oa + 1] - (int) db[ob + 1]).abs () + ((int) da[oa + 2] - (int) db[ob + 2]).abs ();
                                if (d > 60) diff++;
                            }
                        }
                        if (diff > CELL * CELL / 12) {
                            ctx.view.add_overlay (p, Geometry.rect (cx / SCALE, cy / SCALE, (cx + CELL) / SCALE, (cy + CELL) / SCALE), "#c01c28", false);
                            regions++;
                        }
                    }
                }
            }
            return regions;
        }

        private Cairo.ImageSurface render (Poppler.Page page, double scale) {
            double w, h;
            page.get_size (out w, out h);
            var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, int.max (1, (int) (w * scale)), int.max (1, (int) (h * scale)));
            var cr = new Cairo.Context (surface);
            cr.set_source_rgb (1, 1, 1);
            cr.paint ();
            cr.scale (scale, scale);
            page.render (cr);
            surface.flush ();
            return surface;
        }

        public override void leave () {
            ctx.view.clear_overlays ();
        }

        public override void enter () {
            if (other != null) run ();
        }
    }
}
