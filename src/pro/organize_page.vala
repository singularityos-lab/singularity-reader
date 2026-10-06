using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class PageGrid : Box {
        private FlowBox flow;
        private ReaderDocument? document = null;
        private int drag_from = -1;

        public signal void moved (int from, int to);
        public signal void selection_changed ();
        public signal void opened (int page);

        public PageGrid () {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class ("reader-view");
            flow = new FlowBox ();
            flow.selection_mode = SelectionMode.MULTIPLE;
            flow.homogeneous = true;
            flow.column_spacing = 18;
            flow.row_spacing = 18;
            flow.margin_top = 24;
            flow.margin_bottom = 24;
            flow.margin_start = 24;
            flow.margin_end = 24;
            flow.max_children_per_line = 12;
            flow.valign = Align.START;
            flow.selected_children_changed.connect (() => selection_changed ());
            flow.child_activated.connect ((child) => opened (child.get_index ()));
            var scroll = new ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = flow;
            Singularity.Widgets.apply_titlebar_inset (flow);
            append (scroll);
        }

        public void load (ReaderDocument doc) {
            document = doc;
            Widget? child;
            while ((child = flow.get_first_child ()) != null) flow.remove (child);
            for (int i = 0; i < doc.n_pages; i++) flow.append (make_tile (i));
        }

        private Widget make_tile (int index) {
            var box = new Box (Orientation.VERTICAL, 6);
            var picture = new Picture ();
            picture.add_css_class ("reader-thumbnail");
            picture.can_shrink = false;
            picture.halign = Align.CENTER;
            picture.valign = Align.END;
            double w = document.width (index), h = document.height (index);
            double scale = 140.0 / double.max (w, h);
            int tw = int.max (1, (int) (w * scale)), th = int.max (1, (int) (h * scale));
            picture.set_size_request (tw, th);
            picture.paintable = render (index, tw, th);
            var holder = new Box (Orientation.VERTICAL, 0);
            holder.height_request = 150;
            holder.valign = Align.END;
            holder.append (picture);
            box.append (holder);
            var label = new Label ((index + 1).to_string ());
            label.add_css_class ("caption");
            label.add_css_class ("dim-label");
            box.append (label);
            var source = new DragSource ();
            source.actions = Gdk.DragAction.MOVE;
            source.prepare.connect ((x, y) => {
                drag_from = index;
                return new Gdk.ContentProvider.for_value (index);
            });
            source.drag_begin.connect ((drag) => source.set_icon (picture.paintable, tw / 2, th / 2));
            box.add_controller (source);
            var target = new DropTarget (typeof (int), Gdk.DragAction.MOVE);
            target.drop.connect ((value, x, y) => {
                int from = drag_from;
                drag_from = -1;
                if (from < 0 || from == index) return false;
                moved (from, index);
                return true;
            });
            box.add_controller (target);
            return box;
        }

        private Gdk.Texture? render (int index, int w, int h) {
            int factor = int.max (1, get_scale_factor ());
            int pw = w * factor, ph = h * factor;
            var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, pw, ph);
            var cr = new Cairo.Context (surface);
            cr.set_source_rgb (1, 1, 1);
            cr.paint ();
            cr.scale ((double) pw / document.width (index), (double) ph / document.height (index));
            document.page (index).render (cr);
            surface.flush ();
            var bytes = new Bytes (surface.get_data ()[0 : surface.get_stride () * ph]);
            return new Gdk.MemoryTexture (pw, ph, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, bytes, surface.get_stride ());
        }

        public int[] selected () {
            int[] result = {};
            foreach (var child in flow.get_selected_children ()) result += child.get_index ();
            int[] sorted = result;
            for (int i = 0; i < sorted.length; i++) {
                for (int j = i + 1; j < sorted.length; j++) {
                    if (sorted[j] < sorted[i]) {
                        int t = sorted[i];
                        sorted[i] = sorted[j];
                        sorted[j] = t;
                    }
                }
            }
            return sorted;
        }

        public void select (int[] indices) {
            flow.unselect_all ();
            foreach (int i in indices) {
                var child = flow.get_child_at_index (i);
                if (child != null) flow.select_child (child);
            }
        }

        public void select_all () {
            flow.select_all ();
        }
    }

    public class OrganizePage : ToolPage {
        private PreferencesGroup selected_group;
        private int[] keep_selection = {};

        public OrganizePage () {
            base (_("Organize Pages"), "view-grid-symbolic");
        }

        private int[] targets () {
            var sel = ctx.window.page_grid.selected ();
            if (sel.length == 0) sel = { ctx.current_page };
            return sel;
        }

        public override void build () {
            var pages = add_group (_("Selected Pages"));
            selected_group = pages;
            add_action (pages, _("Rotate Left"), "object-rotate-left-symbolic", () => {
                var t = targets ();
                keep_selection = t;
                ctx.run (_("Pages rotated"), (e) => Singularity.Pdf.Pages.rotate (e, t, 270));
            });
            add_action (pages, _("Rotate Right"), "object-rotate-right-symbolic", () => {
                var t = targets ();
                keep_selection = t;
                ctx.run (_("Pages rotated"), (e) => Singularity.Pdf.Pages.rotate (e, t, 90));
            });
            add_action (pages, _("Duplicate"), "edit-copy-symbolic", () => {
                var t = targets ();
                ctx.run (_("Page duplicated"), (e) => {
                    for (int i = t.length - 1; i >= 0; i--) Singularity.Pdf.Pages.duplicate (e, t[i]);
                });
            });
            add_action (pages, _("Delete"), "user-trash-symbolic", () => {
                var t = targets ();
                if (t.length >= ctx.document.n_pages) {
                    ctx.error_dialog (_("Pages cannot be deleted"), _("A document needs at least one page."));
                    return;
                }
                ctx.run (ngettext ("%d page deleted", "%d pages deleted", t.length).printf (t.length), (e) => Singularity.Pdf.Pages.delete (e, t));
            });
            add_action (pages, _("Extract to New File…"), "document-save-as-symbolic", () => extract.begin ());
            add_action (pages, _("Extract Images…"), "image-x-generic-symbolic", () => extract_images.begin ());

            var insert = add_group (_("Insert"));
            add_action (insert, _("Blank Page After Selection"), "list-add-symbolic", () => {
                var t = targets ();
                int after = t[t.length - 1];
                double w = ctx.document.width (after), h = ctx.document.height (after);
                ctx.run (_("Blank page inserted"), (e) => Singularity.Pdf.Pages.insert_blank (e, after + 1, w, h));
            });
            add_action (insert, _("Pages from File…"), "document-open-symbolic", () => insert_file.begin ());
            add_action (insert, _("Combine Files into New Document…"), "folder-documents-symbolic", () => combine.begin ());

            var split = add_group (_("Split"));
            var every = new SpinRow (_("Pages per File"), null, 1, 9999, 1, 1);
            split.add_row (every);
            add_action (split, _("Split by Page Count…"), "edit-cut-symbolic", () => split_run.begin (0, (int) every.value));
            var size = new SpinRow (_("Maximum File Size (MB)"), null, 1, 2000, 1, 10);
            split.add_row (size);
            add_action (split, _("Split by File Size…"), "edit-cut-symbolic", () => split_run.begin (1, (int) size.value));
            add_action (split, _("Split by Top-Level Bookmarks…"), "user-bookmarks-symbolic", () => split_run.begin (2, 0));

            var crop = add_group (_("Crop and Page Size"));
            var margin = new SpinRow (_("Crop Margin (pt)"), _("Removed from every side"), 0, 300, 1, 18);
            crop.add_row (margin);
            add_action (crop, _("Crop Selected Pages"), "view-restore-symbolic", () => {
                var t = targets ();
                double m = margin.value;
                ctx.run (_("Pages cropped"), (e) => Singularity.Pdf.Pages.crop (e, t, m, m, m, m));
            });
            add_action (crop, _("Crop by Drawing on the Page"), "view-restore-symbolic", () => {
                ctx.window.show_document_view ();
                ctx.view.tool = Tool.AREA;
                ulong handler = 0;
                handler = ctx.view.area_picked.connect ((page, area, widget) => {
                    ctx.view.disconnect (handler);
                    ctx.view.tool = Tool.SELECT;
                    ctx.run (_("Page cropped"), (e) => {
                        var r = PageMap.to_pdf (e, page, area);
                        Singularity.Pdf.Pages.set_box (e, page, "CropBox", r);
                    });
                });
            });
            var formats = new SelectionRow (_("Resize To"), { "A4", "A3", "A5", "Letter", "Legal" }, "A4");
            crop.add_row (formats);
            var scale = new SwitchRow (_("Scale Content to Fit"), null, true);
            crop.add_row (scale);
            add_action (crop, _("Resize Selected Pages"), "zoom-fit-best-symbolic", () => {
                var t = targets ();
                double w = 595.28, h = 841.89;
                switch (formats.current_value) {
                    case "A3": w = 841.89; h = 1190.55; break;
                    case "A5": w = 419.53; h = 595.28; break;
                    case "Letter": w = 612; h = 792; break;
                    case "Legal": w = 612; h = 1008; break;
                    default: break;
                }
                bool fit = scale.active;
                ctx.run (_("Pages resized"), (e) => Singularity.Pdf.Pages.resize (e, t, w, h, fit));
            });
            update_selection ();
            ctx.window.page_grid.selection_changed.connect (update_selection);
            ctx.window.page_grid.moved.connect ((from, to) => {
                ctx.run ("", (e) => Singularity.Pdf.Pages.move (e, from, to));
                keep_selection = { to };
            });
            ctx.window.page_grid.opened.connect ((page) => {
                ctx.window.show_document_view ();
                ctx.view.go_to (page);
            });
        }

        private void update_selection () {
            int n = ctx.window.page_grid.selected ().length;
            selected_group.description = n == 0 ? _("Drag pages to reorder them. Select pages to rotate, delete, duplicate or extract them; without a selection the current page is used.") : ngettext ("%d page selected", "%d pages selected", n).printf (n);
        }

        private delegate void Handler ();

        private void add_action (PreferencesGroup group, string title, string icon, owned Handler handler) {
            var row = new ActionRow (title, null, icon);
            row.activated.connect (() => handler ());
            group.add_row (row);
        }

        public override void enter () {
            ctx.window.show_page_grid ();
            update_selection ();
        }

        public override void leave () {
            ctx.window.show_document_view ();
        }

        public override void document_changed () {
            if (ctx.window.page_grid_visible ()) {
                ctx.window.page_grid.load (ctx.document);
                var valid = new int[0];
                foreach (int i in keep_selection) if (i < ctx.document.n_pages) valid += i;
                ctx.window.page_grid.select (valid);
                keep_selection = {};
                update_selection ();
            }
        }

        private async void extract () {
            var t = targets ();
            var file = yield ctx.choose_save (_("Extract Pages"), _("%s (pages).pdf").printf (ctx.base_name ()), "application/pdf");
            if (file == null) return;
            try {
                var e = ctx.document.open_engine ();
                var sub = Singularity.Pdf.Pages.extract (e, t);
                var opts = new Singularity.Pdf.SaveOptions ();
                opts.garbage_collect = true;
                ctx.write_file (file, sub.save (opts));
                ctx.toast (_("Pages extracted"));
            } catch (Error err) {
                ctx.error_dialog (_("The pages could not be extracted"), err.message);
            }
        }

        private async void extract_images () {
            var folder = yield ctx.choose_folder (_("Choose a Folder for the Images"));
            if (folder == null) return;
            try {
                var e = ctx.document.open_engine ();
                int count = 0;
                var seen = new Gee.HashSet<int> ();
                foreach (int p in targets ()) {
                    foreach (var info in Singularity.Pdf.Images.list (e, p)) {
                        if (info.xobject == null) continue;
                        if (info.xobject.is_ref ()) {
                            if (seen.contains (info.xobject.num)) continue;
                            seen.add (info.xobject.num);
                        }
                        string ext;
                        try {
                            var data = Singularity.Pdf.Images.original (e, info, out ext);
                            count++;
                            var target = folder.get_child ("%s-page%d-%d.%s".printf (ctx.base_name (), p + 1, count, ext));
                            FileUtils.set_data (target.get_path (), data);
                        } catch (Error inner) {
                        }
                    }
                }
                ctx.toast (ngettext ("%d image extracted", "%d images extracted", count).printf (count));
            } catch (Error err) {
                ctx.error_dialog (_("The images could not be extracted"), err.message);
            }
        }

        private async void insert_file () {
            var t = targets ();
            int at = t[t.length - 1] + 1;
            var file = yield ctx.choose_open (_("Insert Pages from File"), "application/pdf");
            if (file == null) return;
            ctx.run (_("Pages inserted"), (e) => {
                var src = Singularity.Pdf.Document.open_file (file.get_path ());
                Singularity.Pdf.Pages.insert_from (e, src, Singularity.Pdf.Pages.range (0, src.page_count ()), at);
            });
        }

        private async void combine () {
            var files = yield ctx.choose_many (_("Choose Files to Combine"), { "application/pdf", "image/png", "image/jpeg", "image/tiff", "image/webp" });
            if (files.length == 0) return;
            var target = yield ctx.choose_save (_("Save Combined Document"), _("Combined.pdf"), "application/pdf");
            if (target == null) return;
            try {
                var docs = new Gee.ArrayList<Singularity.Pdf.Document> ();
                string[] titles = {};
                if (ctx.document != null) {
                    docs.add (ctx.document.open_engine ());
                    titles += ctx.base_name ();
                }
                foreach (var f in files) {
                    string name = f.get_basename () ?? "";
                    if (name.down ().has_suffix (".pdf")) docs.add (Singularity.Pdf.Document.open_file (f.get_path ()));
                    else docs.add (Singularity.Pdf.Scans.from_images ({ f.get_path () }));
                    int dot = name.last_index_of_char ('.');
                    titles += dot > 0 ? name.substring (0, dot) : name;
                }
                var merged = Singularity.Pdf.Pages.merge (docs, titles);
                ctx.write_file (target, merged.save ());
                ctx.open_result (target);
            } catch (Error err) {
                ctx.error_dialog (_("The files could not be combined"), err.message);
            }
        }

        private async void split_run (int mode, int value) {
            var folder = yield ctx.choose_folder (_("Choose a Folder for the Parts"));
            if (folder == null) return;
            try {
                var e = ctx.document.open_engine ();
                Gee.ArrayList<Singularity.Pdf.Document> parts;
                string[] titles = {};
                if (mode == 0) parts = Singularity.Pdf.Pages.split_every (e, value);
                else if (mode == 1) parts = Singularity.Pdf.Pages.split_by_size (e, (int64) value * 1024 * 1024);
                else parts = Singularity.Pdf.Pages.split_by_outline (e, out titles);
                var opts = new Singularity.Pdf.SaveOptions ();
                opts.garbage_collect = true;
                for (int i = 0; i < parts.size; i++) {
                    string label = i < titles.length && titles[i].strip () != "" ? titles[i].replace ("/", "-").strip () : "%s-%d".printf (ctx.base_name (), i + 1);
                    FileUtils.set_data (folder.get_child (label + ".pdf").get_path (), parts[i].save (opts));
                }
                ctx.toast (ngettext ("Split into %d file", "Split into %d files", parts.size).printf (parts.size));
            } catch (Error err) {
                ctx.error_dialog (_("The document could not be split"), err.message);
            }
        }
    }
}
