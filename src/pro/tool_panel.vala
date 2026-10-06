using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class ToolPanel : InspectorPanel {
        public const int WIDTH = 340;

        private ProContext ctx;
        private Stack stack;
        private Stack footers;
        private Label title_label;
        private Button back_button;
        private Gee.HashMap<string, ToolPage> pages = new Gee.HashMap<string, ToolPage> ();
        private Gee.ArrayList<string> order = new Gee.ArrayList<string> ();
        private ToolPage? active = null;

        public signal void close_requested ();

        public ToolPanel (ProContext ctx) {
            Object (panel_width: WIDTH);
            this.ctx = ctx;
            add_css_class ("reader-tool-panel");
            Singularity.Widgets.apply_titlebar_inset (this);
            back_button = new Button.from_icon_name ("go-previous-symbolic");
            back_button.add_css_class ("sx-inspector-more");
            back_button.valign = Align.CENTER;
            back_button.tooltip_text = _("All Tools");
            back_button.clicked.connect (() => show_hub ());
            header.append (back_button);
            title_label = new Label (_("Tools"));
            title_label.add_css_class ("title-4");
            title_label.hexpand = true;
            title_label.xalign = 0;
            title_label.ellipsize = Pango.EllipsizeMode.END;
            header.append (title_label);
            var close = new Button.from_icon_name ("window-close-symbolic");
            close.add_css_class ("sx-inspector-more");
            close.valign = Align.CENTER;
            close.tooltip_text = _("Close Tools");
            close.clicked.connect (() => close_requested ());
            header.append (close);
            stack = new Stack ();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.vhomogeneous = false;
            stack.hhomogeneous = false;
            set_body (stack);
            footers = new Stack ();
            footers.transition_type = StackTransitionType.CROSSFADE;
            footers.vhomogeneous = false;
            set_footer_content (footers);
            footer.visible = false;
            ctx.view.notify["tool"].connect (() => {
                if (active != null && ctx.view.tool == Tool.SELECT) active.clear_modes ();
            });
        }

        public void register (string id, ToolPage page, string group) {
            page.ctx = ctx;
            page.set_data<string> ("group", group);
            pages[id] = page;
            order.add (id);
        }

        public void finish_registration () {
            stack.add_named (build_hub (), "hub");
            show_hub ();
        }

        private Widget build_hub () {
            var box = new Box (Orientation.VERTICAL, 18);
            box.margin_top = 6;
            box.margin_bottom = 24;
            box.margin_start = 14;
            box.margin_end = 14;
            var groups = new Gee.HashMap<string, PreferencesGroup> ();
            foreach (var id in order) {
                var page = pages[id];
                string group = page.get_data<string> ("group");
                if (!groups.has_key (group)) {
                    var g = new PreferencesGroup (group);
                    groups[group] = g;
                    box.append (g);
                }

                var row = new ActionRow (page.title, null, page.icon);
                row.activatable = true;
                string target = id;
                row.activated.connect (() => open (target));
                var arrow = new Image.from_icon_name ("go-next-symbolic");
                arrow.add_css_class ("dim-label");
                row.add_suffix (arrow);
                groups[group].add_row (row);
            }
            return box;
        }

        public void show_hub () {
            if (active != null) {
                active.clear_modes ();
                active.leave ();
                active = null;
            }
            stack.visible_child_name = "hub";
            title_label.label = _("Tools");
            back_button.visible = false;
            footer.visible = false;
            scroller.vadjustment.value = 0;
        }

        public void open (string id) {
            if (!pages.has_key (id)) return;
            var page = pages[id];
            if (active != null && active != page) {
                active.clear_modes ();
                active.leave ();
            }
            if (page.get_parent () == null) {
                page.build ();
                stack.add_named (page, id);
                footers.add_named (page.footer, id);
            }
            stack.visible_child_name = id;
            footers.visible_child_name = id;
            footer.visible = page.footer.get_first_child () != null;
            title_label.label = page.title;
            back_button.visible = true;
            scroller.vadjustment.value = 0;
            active = page;
            page.enter ();
        }

        public void leave_active () {
            if (active != null) {
                active.clear_modes ();
                active.leave ();
            }
        }

        public void document_changed () {
            foreach (var page in pages.values) {
                if (page.get_parent () != null) page.document_changed ();
            }
        }
    }
}
