using Gtk;

namespace Singularity.Apps.Reader {

    public class Palette : Box {
        public const string[] COLORS = { "#f5c211", "#33d17a", "#3584e4", "#c061cb", "#ed333b", "#ff7800", "#241f31", "#ffffff" };
        public signal void picked (string hex);

        public Palette (string current) {
            Object (orientation: Orientation.HORIZONTAL, spacing: 6);
            add_css_class ("reader-palette");
            ToggleButton? group = null;
            foreach (string hex in COLORS) {
                var btn = new ToggleButton ();
                btn.add_css_class ("reader-swatch");
                btn.tooltip_text = hex;
                var provider = new CssProvider ();
                provider.load_from_string ("button { background-color: %s; background-image: none; min-width: 26px; min-height: 26px; padding: 0; margin: 0; border-radius: 999px; }".printf (hex));
                btn.get_style_context ().add_provider (provider, STYLE_PROVIDER_PRIORITY_USER + 10);
                if (group != null) btn.group = group; else group = btn;
                btn.active = hex.down () == current.down ();
                string value = hex;
                btn.toggled.connect (() => { if (btn.active) picked (value); });
                append (btn);
            }
        }
    }

    public class TextPrompt : Popover {
        private TextView text;
        public signal void submitted (string value);

        public TextPrompt (string title, string initial, string action) {
            add_css_class ("reader-prompt");
            var box = new Box (Orientation.VERTICAL, 8);
            box.margin_top = 10;
            box.margin_bottom = 10;
            box.margin_start = 10;
            box.margin_end = 10;
            var heading = new Label (title);
            heading.add_css_class ("heading");
            heading.xalign = 0;
            box.append (heading);
            text = new TextView ();
            text.wrap_mode = WrapMode.WORD_CHAR;
            text.buffer.text = initial;
            text.top_margin = 6;
            text.bottom_margin = 6;
            text.left_margin = 6;
            text.right_margin = 6;
            var frame = new Frame (null);
            frame.child = text;
            frame.set_size_request (260, 90);
            box.append (frame);
            var buttons = new Box (Orientation.HORIZONTAL, 6);
            buttons.halign = Align.END;
            var cancel = new Button.with_label (_("Cancel"));
            cancel.clicked.connect (() => popdown ());
            var ok = new Button.with_label (action);
            ok.add_css_class ("suggested-action");
            ok.clicked.connect (() => {
                string value = text.buffer.text.strip ();
                popdown ();
                if (value != "") submitted (value);
            });
            buttons.append (cancel);
            buttons.append (ok);
            box.append (buttons);
            child = box;
            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((keyval, code, state) => {
                if ((keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) && (state & Gdk.ModifierType.CONTROL_MASK) != 0) {
                    ok.activate ();
                    return true;
                }
                return false;
            });
            text.add_controller (keys);
            map.connect (() => text.grab_focus ());
        }
    }

    public class AnnotationPopover : Popover {
        public AnnotationPopover (ReaderDocument document, DocumentView view, int page, Poppler.Annot annot, Poppler.Rectangle area) {
            add_css_class ("reader-annotation-popover");
            var box = new Box (Orientation.VERTICAL, 8);
            box.margin_top = 10;
            box.margin_bottom = 10;
            box.margin_start = 10;
            box.margin_end = 10;
            var type = annot.get_annot_type ();
            var heading = new Label (Annotations.describe (annot));
            heading.add_css_class ("heading");
            heading.xalign = 0;
            box.append (heading);
            var markup = annot as Poppler.AnnotMarkup;
            if (markup != null) {
                string author = markup.get_label () ?? "";
                if (author != "") {
                    var by = new Label (_("By %s").printf (author));
                    by.add_css_class ("dim-label");
                    by.xalign = 0;
                    box.append (by);
                }
            }

            if (type != Poppler.AnnotType.STAMP) {
                var color = annot.get_color ();
                var palette = new Palette (color != null ? Geometry.hex (color) : "");
                palette.picked.connect ((hex) => Annotations.recolor (document, page, annot, hex));
                box.append (palette);
            } else if (view.annotation_movable (page, area)) {
                var hint = new Label (_("Drag to move it, drag a corner to resize it."));
                hint.add_css_class ("dim-label");
                hint.wrap = true;
                hint.max_width_chars = 30;
                hint.xalign = 0;
                box.append (hint);
            }

            TextView? editor = null;
            if (type != Poppler.AnnotType.STAMP && type != Poppler.AnnotType.INK) {
                editor = new TextView ();
                editor.wrap_mode = WrapMode.WORD_CHAR;
                editor.buffer.text = annot.get_contents () ?? "";
                editor.top_margin = 6;
                editor.bottom_margin = 6;
                editor.left_margin = 6;
                editor.right_margin = 6;
                var frame = new Frame (null);
                frame.child = editor;
                frame.set_size_request (260, type == Poppler.AnnotType.TEXT || type == Poppler.AnnotType.FREE_TEXT ? 110 : 64);
                var label = new Label (type == Poppler.AnnotType.FREE_TEXT ? _("Text") : _("Comment"));
                label.xalign = 0;
                label.add_css_class ("caption");
                box.append (label);
                box.append (frame);
            }

            var actions = new Box (Orientation.HORIZONTAL, 6);
            var delete_btn = new Button.from_icon_name ("user-trash-symbolic");
            delete_btn.tooltip_text = _("Delete");
            delete_btn.add_css_class ("flat");
            delete_btn.clicked.connect (() => {
                popdown ();
                view.deselect_annotation ();
                Annotations.remove (document, page, annot);
            });
            actions.append (delete_btn);
            var spacer = new Box (Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            actions.append (spacer);
            if (editor != null) {
                var save = new Button.with_label (_("Done"));
                save.add_css_class ("suggested-action");
                save.clicked.connect (() => popdown ());
                actions.append (save);
                closed.connect (() => {
                    string value = editor.buffer.text;
                    if (value != (annot.get_contents () ?? "")) Annotations.set_text (document, page, annot, value);
                });
            }
            box.append (actions);
            child = box;
            closed.connect (() => {
                if (!(type == Poppler.AnnotType.STAMP && view.annotation_movable (page, area))) view.deselect_annotation ();
            });
        }
    }
}
