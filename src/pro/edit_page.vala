using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class EditPage : ToolPage {
        private enum Mode {
            NONE,
            TEXT,
            ADD_TEXT,
            IMAGE,
            ADD_IMAGE
        }

        private Mode mode = Mode.NONE;
        private ulong point_handler = 0;
        private ulong area_handler = 0;
        private Singularity.Pdf.ImageInfo? selected_image = null;
        private int selected_image_page = -1;
        private PreferencesGroup image_actions;
        private ActionRow edit_text_row;
        private ActionRow add_text_row;
        private ActionRow select_image_row;
        private EntryRow family_row;
        private SpinRow size_row;
        private string? pending_image = null;

        public EditPage () {
            base (_("Edit PDF"), "document-edit-symbolic");
        }

        public override void build () {
            var text = add_group (_("Text"), _("Edited paragraphs reflow inside their own box. When the embedded font lacks a character a similar installed font is used, and you are told which one. For long rewrites, export to Write."));
            edit_text_row = mode_row (_("Edit Text"), _("Click a paragraph to change it"), "insert-text-symbolic");
            edit_text_row.activated.connect (() => set_mode (Mode.TEXT));
            text.add_row (edit_text_row);
            add_text_row = mode_row (_("Add Text"), _("Click where the new text starts"), "list-add-symbolic");
            add_text_row.activated.connect (() => set_mode (Mode.ADD_TEXT));
            text.add_row (add_text_row);
            family_row = new EntryRow (_("Font for New Text"));
            family_row.text = "Sans";
            text.add_row (family_row);
            size_row = new SpinRow (_("Size"), null, 4, 144, 0.5, 12);
            text.add_row (size_row);
            var images = add_group (_("Images"));
            select_image_row = mode_row (_("Select Image"), _("Click an image on the page"), "image-x-generic-symbolic");
            select_image_row.activated.connect (() => set_mode (Mode.IMAGE));
            images.add_row (select_image_row);
            var add = new ActionRow (_("Add Image…"), _("Choose a picture, then drag its place"), "insert-object-symbolic");
            add.activated.connect (() => add_image.begin ());
            images.add_row (add);
            image_actions = add_group (_("Selected Image"));
            image_actions.visible = false;
            var move = new ActionRow (_("Move or Resize"), _("Drag the new position on the page"), "view-fullscreen-symbolic");
            move.activated.connect (() => {
                mode = Mode.IMAGE;
                ctx.view.tool = Tool.AREA;
                connect_area ();
                ctx.toast (_("Drag the new position of the image"));
            });
            image_actions.add_row (move);
            var replace = new ActionRow (_("Replace…"), null, "document-open-symbolic");
            replace.activated.connect (() => replace_image.begin ());
            image_actions.add_row (replace);
            var remove = new ActionRow (_("Delete Image"), null, "user-trash-symbolic");
            remove.activated.connect (() => {
                var info = selected_image;
                int page = selected_image_page;
                if (info == null) return;
                ctx.run (_("Image deleted"), (e) => Singularity.Pdf.Editor.delete_image (e, page, find_image (e, page, info)));
                clear_image ();
            });
            image_actions.add_row (remove);
        }

        private Singularity.Pdf.ImageInfo find_image (Singularity.Pdf.Document e, int page, Singularity.Pdf.ImageInfo old) {
            foreach (var i in Singularity.Pdf.Images.list (e, page)) {
                if ((i.item.box.x1 - old.item.box.x1).abs () < 0.5 && (i.item.box.y1 - old.item.box.y1).abs () < 0.5) return i;
            }
            return old;
        }

        private void set_mode (Mode m) {
            mode = m;
            disconnect_all ();
            ctx.view.clear_overlays ();
            if (m == Mode.NONE) {
                ctx.view.tool = Tool.SELECT;
                return;
            }
            ctx.view.tool = Tool.POINT;
            set_active_mode (m == Mode.TEXT ? edit_text_row : (m == Mode.ADD_TEXT ? add_text_row : select_image_row));
            ctx.view.pick_cursor = m == Mode.ADD_TEXT ? "text" : "pointer";
            point_handler = ctx.view.point_picked.connect (on_point);
            if (m == Mode.TEXT) show_blocks ();
        }

        private void show_blocks () {
            var e = ctx.engine ();
            if (e == null) return;
            int p = ctx.current_page;
            foreach (var b in Singularity.Pdf.Editor.blocks (e, p)) {
                if (b.in_form) continue;
                ctx.view.add_overlay (p, PageMap.to_view (e, p, b.box), "#3584e4", false);
            }
        }

        private void disconnect_all () {
            if (point_handler != 0) ctx.view.disconnect (point_handler);
            if (area_handler != 0) ctx.view.disconnect (area_handler);
            point_handler = area_handler = 0;
        }

        private void connect_area () {
            if (area_handler != 0) ctx.view.disconnect (area_handler);
            area_handler = ctx.view.area_picked.connect (on_area);
        }

        private void on_point (int page, double x, double y, Widget widget) {
            var e = ctx.engine ();
            if (e == null) return;
            double px, py;
            PageMap.point_to_pdf (e, page, x, y, out px, out py);
            switch (mode) {
                case Mode.TEXT:
                    foreach (var b in Singularity.Pdf.Editor.blocks (e, page)) {
                        var grow = Singularity.Pdf.Rect.of (b.box.x1 - 2, b.box.y1 - 2, b.box.x2 + 2, b.box.y2 + 2);
                        if (!grow.contains_point (px, py)) continue;
                        if (b.in_form) {
                            ctx.toast (_("This text is inside a reusable graphic and cannot be edited here"));
                            return;
                        }
                        edit_block (page, b, widget, PageMap.to_view (e, page, b.box));
                        return;
                    }
                    ctx.toast (_("No text here"));
                    break;
                case Mode.ADD_TEXT:
                    var prompt = new TextPrompt (_("New Text"), "", _("Add"));
                    string family = family_row.text.strip () != "" ? family_row.text.strip () : "Sans";
                    double size = size_row.value;
                    prompt.submitted.connect ((text) => {
                        Singularity.Pdf.EditResult? r = null;
                        double[] color = Singularity.Pdf.Annotations.rgb (ctx.app.settings.get_string ("text-color"));
                        ctx.run (_("Text added"), (en) => {
                            r = Singularity.Pdf.Editor.add_text (en, page, px, py - size, text, family, size, color);
                        });
                        if (r != null && r.font_family != "") ctx.toast (_("Font used: %s").printf (r.font_family));
                    });
                    ctx.window.show_popover_at (prompt, widget, Geometry.rect (x, y, x + 1, y + 1));
                    break;
                case Mode.IMAGE:
                    clear_image ();
                    foreach (var info in Singularity.Pdf.Images.list (e, page)) {
                        if (info.item.box.contains_point (px, py)) {
                            selected_image = info;
                            selected_image_page = page;
                            ctx.view.add_overlay (page, PageMap.to_view (e, page, info.item.box), "#e66100", false, _("Image"));
                            image_actions.visible = true;
                            image_actions.description = _("%d by %d pixels, %d dpi").printf (info.pixel_width, info.pixel_height, (int) double.min (info.dpi_x, info.dpi_y));
                            return;
                        }
                    }
                    ctx.toast (_("No image here"));
                    break;
                default:
                    break;
            }
        }

        private void clear_image () {
            selected_image = null;
            selected_image_page = -1;
            image_actions.visible = false;
            ctx.view.clear_overlays ();
        }

        private void on_area (int page, Poppler.Rectangle area, Widget widget) {
            if (pending_image != null) {
                string path = pending_image;
                pending_image = null;
                ctx.view.tool = Tool.SELECT;
                disconnect_all ();
                ctx.run (_("Image added"), (e) => {
                    int w, h;
                    var img = Singularity.Pdf.Images.from_file (e, path, out w, out h);
                    var r = PageMap.to_pdf (e, page, area);
                    double s = double.min (r.width () / double.max (1, w), r.height () / double.max (1, h));
                    double dw = w * s, dh = h * s;
                    Singularity.Pdf.Editor.add_image (e, page, img, Singularity.Pdf.Rect.of (r.x1, r.y2 - dh, r.x1 + dw, r.y2));
                });
                return;
            }
            var info = selected_image;
            int src_page = selected_image_page;
            if (info == null || src_page != page) return;
            ctx.run (_("Image moved"), (e) => {
                var r = PageMap.to_pdf (e, page, area);
                Singularity.Pdf.Editor.move_image (e, page, find_image (e, page, info), r);
            });
            clear_image ();
            set_mode (Mode.IMAGE);
        }

        private void edit_block (int page, Singularity.Pdf.TextBlock block, Widget widget, Poppler.Rectangle view_area) {
            var pop = new Popover ();
            var box = new Box (Orientation.VERTICAL, 8);
            box.margin_top = 10;
            box.margin_bottom = 10;
            box.margin_start = 10;
            box.margin_end = 10;
            var tv = new TextView ();
            tv.wrap_mode = WrapMode.WORD_CHAR;
            tv.buffer.text = block.text ().replace ("\n", " ");
            tv.set_size_request (320, 110);
            var sw = new ScrolledWindow ();
            sw.child = tv;
            sw.min_content_height = 110;
            box.append (sw);
            var row = new Box (Orientation.HORIZONTAL, 8);
            var size = new SpinButton.with_range (4, 144, 0.5);
            size.value = Math.round (block.size * 2) / 2;
            size.tooltip_text = _("Size");
            row.append (new Label (_("Size")));
            row.append (size);
            var font = new Entry ();
            font.placeholder_text = _("Keep font");
            font.hexpand = true;
            row.append (font);
            box.append (row);
            var buttons = new Box (Orientation.HORIZONTAL, 8);
            buttons.halign = Align.END;
            var delete = new Button.with_label (_("Delete"));
            delete.add_css_class ("destructive-action");
            var apply = new Button.with_label (_("Apply"));
            apply.add_css_class ("suggested-action");
            buttons.append (delete);
            buttons.append (apply);
            box.append (buttons);
            pop.child = box;
            delete.clicked.connect (() => {
                pop.popdown ();
                ctx.run (_("Text deleted"), (e) => Singularity.Pdf.Editor.delete_block (e, page, block));
            });
            apply.clicked.connect (() => {
                pop.popdown ();
                string text = tv.buffer.text;
                string? family = font.text.strip () != "" ? font.text.strip () : null;
                double sz = (size.value - block.size).abs () > 0.2 ? size.value : 0;
                Singularity.Pdf.EditResult? r = null;
                ctx.run (_("Text updated"), (e) => {
                    r = Singularity.Pdf.Editor.replace_block (e, page, block, text, family, sz);
                    if (r.message != "") throw new IOError.FAILED (r.message);
                });
                if (r != null && r.substituted && family == null) {
                    ctx.toast (_("The original font lacked some characters, so %s was used.").printf (r.font_family));
                }
                if (mode == Mode.TEXT) show_blocks ();
            });
            ctx.window.show_popover_at (pop, widget, view_area);
        }

        private async void add_image () {
            var file = yield ctx.choose_open (_("Add Image"), "image/*");
            if (file == null) return;
            pending_image = file.get_path ();
            disconnect_all ();
            ctx.view.tool = Tool.AREA;
            connect_area ();
            ctx.toast (_("Drag on the page where the image goes"));
        }

        private async void replace_image () {
            var info = selected_image;
            int page = selected_image_page;
            if (info == null) return;
            var file = yield ctx.choose_open (_("Replace Image"), "image/*");
            if (file == null) return;
            ctx.run (_("Image replaced"), (e) => {
                int w, h;
                var img = Singularity.Pdf.Images.from_file (e, file.get_path (), out w, out h);
                Singularity.Pdf.Editor.replace_image (e, page, find_image (e, page, info), img);
            });
            clear_image ();
        }

        public override void leave () {
            disconnect_all ();
            mode = Mode.NONE;
            pending_image = null;
            ctx.view.clear_overlays ();
            if (ctx.view.tool == Tool.POINT || ctx.view.tool == Tool.AREA) ctx.view.tool = Tool.SELECT;
        }

        public override void document_changed () {
            if (mode == Mode.TEXT) {
                ctx.view.clear_overlays ();
                show_blocks ();
            }
        }
    }
}
