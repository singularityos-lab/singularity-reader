using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class ReaderSidebar : AppSidebar {
        private const int THUMB_WIDTH = 120;

        private DocumentView view;
        private Stack stack;
        private ListView thumbs;
        private SingleSelection thumb_selection;
        private Gee.HashMap<int, Gdk.Texture> thumb_cache = new Gee.HashMap<int, Gdk.Texture> ();
        private ListBox outline_list;
        private ListBox annotation_list;
        private StatusPage outline_empty;
        private StatusPage annotations_empty;
        private ListBox layers_list;
        private StatusPage layers_empty;
        private bool syncing = false;
        private uint annotations_source = 0;

        public ReaderSidebar (DocumentView view) {
            Object ();
            this.view = view;
            add_css_class ("reader-sidebar");
            box.remove_css_class ("navigation-sidebar");
            stack = new Stack ();
            stack.vexpand = true;
            stack.transition_type = StackTransitionType.CROSSFADE;

            var factory = new SignalListItemFactory ();
            factory.setup.connect ((obj) => {
                var item = (ListItem) obj;
                var box = new Box (Orientation.VERTICAL, 4);
                box.margin_top = 6;
                box.margin_bottom = 6;
                var picture = new Picture ();
                picture.add_css_class ("reader-thumbnail");
                picture.can_shrink = false;
                picture.halign = Align.CENTER;
                var label = new Label ("");
                label.add_css_class ("caption");
                label.add_css_class ("dim-label");
                box.append (picture);
                box.append (label);
                item.child = box;
            });
            factory.bind.connect ((obj) => {
                var item = (ListItem) obj;
                var box = (Box) item.child;
                var picture = (Picture) box.get_first_child ();
                var label = (Label) picture.get_next_sibling ();
                int index = (int) item.position;
                var doc = view.document;
                if (doc == null || index >= doc.n_pages) return;
                string page_label = doc.page (index).get_label () ?? "";
                label.label = page_label != "" && page_label != (index + 1).to_string () ? "%s (%d)".printf (page_label, index + 1) : (index + 1).to_string ();
                double scale = THUMB_WIDTH / doc.width (index);
                picture.set_size_request (THUMB_WIDTH, (int) (doc.height (index) * scale));
                picture.paintable = thumbnail (index);
            });
            thumb_selection = new SingleSelection (new StringList (null));
            thumb_selection.autoselect = false;
            thumbs = new ListView (thumb_selection, factory);
            thumbs.add_css_class ("reader-thumbnails");
            thumbs.single_click_activate = true;
            thumbs.activate.connect ((position) => {
                if (!syncing) view.go_to ((int) position);
            });
            var thumb_scroll = new ScrolledWindow ();
            thumb_scroll.hscrollbar_policy = PolicyType.NEVER;
            thumb_scroll.child = thumbs;
            stack.add_titled (thumb_scroll, "pages", _("Pages"));

            outline_list = new ListBox ();
            outline_list.add_css_class ("navigation-sidebar");
            outline_list.row_activated.connect ((row) => {
                var dest = row.get_data<Poppler.Dest?> ("dest");
                var action = row.get_data<Poppler.Action?> ("action");
                if (action != null) view.follow (action);
                else if (dest != null) view.go_to_dest (dest);
            });
            outline_empty = new StatusPage ();
            outline_empty.icon_name = "user-bookmarks";
            outline_empty.title = _("No Outline");
            outline_empty.description = _("This document has no bookmarks or table of contents.");
            outline_empty.vexpand = true;
            var outline_box = new Box (Orientation.VERTICAL, 0);
            outline_box.append (outline_empty);
            outline_box.append (outline_list);
            var outline_scroll = new ScrolledWindow ();
            outline_scroll.hscrollbar_policy = PolicyType.NEVER;
            outline_scroll.child = outline_box;
            stack.add_titled (outline_scroll, "outline", _("Outline"));

            annotation_list = new ListBox ();
            annotation_list.add_css_class ("navigation-sidebar");
            annotation_list.row_activated.connect ((row) => {
                int page = row.get_data<int> ("page");
                var annot = row.get_data<Poppler.Annot> ("annot");
                var area = row.get_data<Poppler.Rectangle?> ("area");
                view.go_to (page, area.y1);
                Idle.add (() => {
                    view.select_annotation (page, annot, area);
                    return Source.REMOVE;
                });
            });
            annotations_empty = new StatusPage ();
            annotations_empty.icon_name = "text-x-generic";
            annotations_empty.title = _("No Notes");
            annotations_empty.description = _("Highlights, notes and drawings you add appear here.");
            annotations_empty.vexpand = true;
            var annot_box = new Box (Orientation.VERTICAL, 0);
            annot_box.append (annotations_empty);
            annot_box.append (annotation_list);
            var annot_scroll = new ScrolledWindow ();
            annot_scroll.hscrollbar_policy = PolicyType.NEVER;
            annot_scroll.child = annot_box;
            stack.add_titled (annot_scroll, "annotations", _("Notes"));

            layers_list = new ListBox ();
            layers_list.add_css_class ("navigation-sidebar");
            layers_list.selection_mode = SelectionMode.NONE;
            layers_empty = new StatusPage ();
            layers_empty.icon_name = "x-office-document";
            layers_empty.title = _("No Layers");
            layers_empty.description = _("This document has no optional layers.");
            layers_empty.vexpand = true;
            var layers_box = new Box (Orientation.VERTICAL, 0);
            layers_box.append (layers_empty);
            layers_box.append (layers_list);
            var layers_scroll = new ScrolledWindow ();
            layers_scroll.hscrollbar_policy = PolicyType.NEVER;
            layers_scroll.child = layers_box;
            stack.add_titled (layers_scroll, "layers", _("Layers"));

            add_bubble_widget (new BubbleSwitcher (stack));
            box.append (stack);

            view.page_changed.connect ((page) => {
                syncing = true;
                thumb_selection.selected = page;
                if (stack.visible_child_name == "pages") thumbs.scroll_to (page, ListScrollFlags.NONE, null);
                syncing = false;
            });
            view.edited.connect (queue_annotations);
        }

        private Gdk.Texture? thumbnail (int index) {
            if (thumb_cache.has_key (index)) return thumb_cache[index];
            var doc = view.document;
            int factor = int.max (1, get_scale_factor ());
            double scale = THUMB_WIDTH * factor / doc.width (index);
            int w = int.max (1, (int) (doc.width (index) * scale)), h = int.max (1, (int) (doc.height (index) * scale));
            var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, w, h);
            var cr = new Cairo.Context (surface);
            cr.set_source_rgb (1, 1, 1);
            cr.paint ();
            cr.scale (scale, scale);
            doc.render_page (index, cr);
            surface.flush ();
            var bytes = new Bytes (surface.get_data ()[0 : surface.get_stride () * h]);
            var texture = new Gdk.MemoryTexture (w, h, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, bytes, surface.get_stride ());
            thumb_cache[index] = texture;
            return texture;
        }

        public void load (ReaderDocument doc) {
            thumb_cache.clear ();
            string[] items = new string[doc.n_pages];
            for (int i = 0; i < doc.n_pages; i++) items[i] = (i + 1).to_string ();
            thumb_selection.model = new StringList (items);
            doc.page_changed.connect ((index) => {
                thumb_cache.unset (index);
                var model = (StringList) thumb_selection.model;
                model.splice (index, 1, { (index + 1).to_string () });
            });
            load_outline (doc);
            load_layers (doc);
            queue_annotations ();
        }

        private void load_layers (ReaderDocument doc) {
            Widget? child;
            while ((child = layers_list.get_first_child ()) != null) layers_list.remove (child);
            var iter = new Poppler.LayersIter (doc.doc);
            int count = iter != null ? add_layers (doc, iter, 0) : 0;
            layers_empty.visible = count == 0;
            layers_list.visible = count > 0;
        }

        private int add_layers (ReaderDocument doc, Poppler.LayersIter iter, int depth) {
            int count = 0;
            do {
                var layer = iter.get_layer ();
                string title = layer != null ? layer.get_title () : (iter.get_title () ?? "");
                var row = new Box (Orientation.HORIZONTAL, 8);
                row.margin_start = 8 + depth * 14;
                row.margin_end = 8;
                row.margin_top = 4;
                row.margin_bottom = 4;
                var label = new Label (title);
                label.xalign = 0;
                label.hexpand = true;
                label.ellipsize = Pango.EllipsizeMode.END;
                row.append (label);
                if (layer != null) {
                    var sw = new Switch ();
                    sw.active = layer.is_visible ();
                    sw.valign = Align.CENTER;
                    var l = layer;
                    sw.notify["active"].connect (() => {
                        if (sw.active) l.show ();
                        else l.hide ();
                        thumb_cache.clear ();
                        view.use_main_thread ();
                        var model = (StringList) thumb_selection.model;
                        model.splice (0, model.get_n_items (), model_items (doc.n_pages));
                    });
                    row.append (sw);
                } else {
                    label.add_css_class ("heading");
                }
                layers_list.append (row);
                count++;
                var child = iter.get_child ();
                if (child != null) count += add_layers (doc, child, depth + 1);
            } while (iter.next ());
            return count;
        }

        private static string[] model_items (int n) {
            string[] items = new string[n];
            for (int i = 0; i < n; i++) items[i] = (i + 1).to_string ();
            return items;
        }

        private void load_outline (ReaderDocument doc) {
            Widget? child;
            while ((child = outline_list.get_first_child ()) != null) outline_list.remove (child);
            var iter = new Poppler.IndexIter (doc.doc);
            int count = 0;
            if (iter != null) count = add_outline (iter, 0);
            outline_empty.visible = count == 0;
            outline_list.visible = count > 0;
        }

        private int add_outline (Poppler.IndexIter iter, int depth) {
            int count = 0;
            do {
                var action = iter.get_action ();
                string title = "";
                if (action != null) {
                    if (action.type == Poppler.ActionType.GOTO_DEST) title = action.goto_dest.title ?? "";
                    else if (action.type == Poppler.ActionType.URI) title = action.uri.title ?? "";
                    else if (action.type == Poppler.ActionType.NAMED) title = action.named.title ?? "";
                    else title = action.any.title ?? "";
                }
                var row = new ListBoxRow ();
                var label = new Label (title.strip ());
                label.xalign = 0;
                label.ellipsize = Pango.EllipsizeMode.END;
                label.margin_start = 8 + depth * 14;
                label.margin_top = 5;
                label.margin_bottom = 5;
                label.tooltip_text = title.strip ();
                if (depth == 0) label.add_css_class ("heading");
                row.child = label;
                if (action != null) row.set_data<Poppler.Action?> ("action", action.copy ());
                outline_list.append (row);
                count++;
                var child = iter.get_child ();
                if (child != null) count += add_outline (child, depth + 1);
            } while (iter.next ());
            return count;
        }

        private void queue_annotations () {
            if (annotations_source != 0) return;
            annotations_source = Timeout.add (250, () => {
                annotations_source = 0;
                load_annotations ();
                return Source.REMOVE;
            });
        }

        private void load_annotations () {
            Widget? child;
            while ((child = annotation_list.get_first_child ()) != null) annotation_list.remove (child);
            var doc = view.document;
            int count = 0;
            if (doc != null) {
                for (int p = 0; p < doc.n_pages; p++) {
                    foreach (var mapping in doc.annotations (p)) {
                        var annot = mapping.annot;
                        string text = annot.get_contents () ?? "";
                        var type = annot.get_annot_type ();
                        if (text.strip () == "" && (type == Poppler.AnnotType.HIGHLIGHT || type == Poppler.AnnotType.UNDERLINE
                                || type == Poppler.AnnotType.STRIKE_OUT || type == Poppler.AnnotType.SQUIGGLY)) {
                            text = doc.page (p).get_selected_text (Poppler.SelectionStyle.GLYPH, mapping.area) ?? "";
                        }
                        var row = new ListBoxRow ();
                        var box = new Box (Orientation.HORIZONTAL, 8);
                        box.margin_top = 6;
                        box.margin_bottom = 6;
                        box.margin_start = 8;
                        box.margin_end = 8;
                        var swatch = new Box (Orientation.HORIZONTAL, 0);
                        swatch.add_css_class ("reader-annotation-swatch");
                        swatch.valign = Align.START;
                        swatch.margin_top = 4;
                        var color = annot.get_color ();
                        if (color != null) {
                            var provider = new CssProvider ();
                            provider.load_from_string ("box { background-color: %s; }".printf (Geometry.hex (color)));
                            swatch.get_style_context ().add_provider (provider, STYLE_PROVIDER_PRIORITY_APPLICATION);
                        }
                        box.append (swatch);
                        var labels = new Box (Orientation.VERTICAL, 2);
                        labels.hexpand = true;
                        var title = new Label (_("%s, page %d").printf (Annotations.describe (annot), p + 1));
                        title.xalign = 0;
                        title.add_css_class ("caption");
                        title.add_css_class ("dim-label");
                        labels.append (title);
                        string clean = text.replace ("\n", " ").strip ();
                        if (clean != "") {
                            var body = new Label (clean);
                            body.xalign = 0;
                            body.wrap = true;
                            body.lines = 3;
                            body.ellipsize = Pango.EllipsizeMode.END;
                            body.max_width_chars = 28;
                            labels.append (body);
                        }
                        box.append (labels);
                        row.child = box;
                        row.set_data<int> ("page", p);
                        row.set_data<Poppler.Annot> ("annot", annot);
                        row.set_data<Poppler.Rectangle?> ("area", mapping.area);
                        annotation_list.append (row);
                        count++;
                    }
                }
            }
            annotations_empty.visible = count == 0;
            annotation_list.visible = count > 0;
        }
    }
}
