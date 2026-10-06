using Gtk;

namespace Singularity.Apps.Reader {

    public class InspectorPanel : Widget {
        public int panel_width { get; construct; }
        public Box header { get; private set; }
        public ScrolledWindow scroller { get; private set; }
        public Box footer { get; private set; }
        private Box column;

        public InspectorPanel (int panel_width) {
            Object (panel_width: panel_width);
        }

        construct {
            add_css_class ("sx-inspector");
            hexpand = false;
            overflow = Overflow.HIDDEN;
            column = new Box (Orientation.VERTICAL, 0);
            column.set_parent (this);
            header = new Box (Orientation.HORIZONTAL, 8);
            header.add_css_class ("sx-inspector-header");
            column.append (header);
            scroller = new ScrolledWindow ();
            scroller.hscrollbar_policy = PolicyType.NEVER;
            scroller.propagate_natural_width = false;
            scroller.vexpand = true;
            column.append (scroller);
            footer = new Box (Orientation.HORIZONTAL, 8);
            footer.add_css_class ("sx-inspector-footer");
            footer.visible = false;
            column.append (footer);
        }

        public void set_body (Widget body) {
            scroller.child = body;
        }

        public void set_footer_content (Widget? content) {
            Widget? child;
            while ((child = footer.get_first_child ()) != null) footer.remove (child);
            if (content != null) {
                content.hexpand = true;
                footer.append (content);
            }
            footer.visible = content != null;
        }

        public override void dispose () {
            if (column != null) column.unparent ();
            column = null;
            base.dispose ();
        }

        public override SizeRequestMode get_request_mode () {
            return SizeRequestMode.HEIGHT_FOR_WIDTH;
        }

        public override void measure (Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = natural_baseline = -1;
            if (orientation == Orientation.HORIZONTAL) {
                minimum = natural = panel_width;
                return;
            }
            column.measure (orientation, panel_width, out minimum, out natural, null, null);
        }

        public override void size_allocate (int width, int height, int baseline) {
            column.allocate (width, height, baseline, null);
        }
    }
}
