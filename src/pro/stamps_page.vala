using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class PageMarksPage : ToolPage {
        public PageMarksPage () {
            base (_("Headers and Watermarks"), "text-x-generic-symbolic");
        }

        public override void build () {
            var hf = add_group (_("Header and Footer"), _("Placeholders: <<page>>, <<pages>>, <<date>>, <<time>>, <<file>> and <<bates>>."));
            var tl = new EntryRow (_("Header Left"));
            var tc = new EntryRow (_("Header Center"));
            var tr = new EntryRow (_("Header Right"));
            var bl = new EntryRow (_("Footer Left"));
            var bc = new EntryRow (_("Footer Center"));
            bc.text = "<<page>> / <<pages>>";
            var br = new EntryRow (_("Footer Right"));
            foreach (var r in new EntryRow[] { tl, tc, tr, bl, bc, br }) hf.add_row (r);
            var size = new SpinRow (_("Text Size"), null, 5, 36, 0.5, 9);
            hf.add_row (size);
            var range = new HintEntryRow (_("Pages"), _("For example 2-5, empty for all"));
            hf.add_row (range);
            var start = new SpinRow (_("First Page Number"), null, 0, 100000, 1, 1);
            hf.add_row (start);
            var remove_hf = new ActionRow (_("Remove Headers and Footers"), null, "edit-clear-symbolic");
            remove_hf.activated.connect (() => ctx.run (_("Removed"), (e) => {
                Singularity.Pdf.Stamps.remove_pagination (e, "Header");
                Singularity.Pdf.Stamps.remove_pagination (e, "Footer");
            }));
            hf.add_row (remove_hf);
            var bates = add_group (_("Bates Numbering"), _("Fills the <<bates>> placeholder."));
            var prefix = new EntryRow (_("Prefix"));
            var suffix = new EntryRow (_("Suffix"));
            var digits = new SpinRow (_("Digits"), null, 3, 12, 1, 6);
            var bates_start = new SpinRow (_("Start At"), null, 0, 99999999, 1, 1);
            foreach (var r in new Widget[] { prefix, suffix, digits, bates_start }) bates.add_row (r);
            var add_hf = header_button (hf, _("Add"), true);
            add_hf.tooltip_text = _("Add Header and Footer");
            add_hf.clicked.connect (() => {
                var h = new Singularity.Pdf.HeaderFooter ();
                h.top_left = tl.text;
                h.top_center = tc.text;
                h.top_right = tr.text;
                h.bottom_left = bl.text;
                h.bottom_center = bc.text;
                h.bottom_right = br.text;
                h.size = size.value;
                h.start_number = (int) start.value;
                h.bates_prefix = prefix.text;
                h.bates_suffix = suffix.text;
                h.bates_digits = (int) digits.value;
                h.bates_start = (int) bates_start.value;
                h.file_name = ctx.document.file.get_basename () ?? "";
                var pages = ctx.parse_pages (range.text, ctx.document.n_pages);
                if (pages.length > 0) {
                    h.first_page = pages[0];
                    h.last_page = pages[pages.length - 1];
                }
                ctx.run (_("Header and footer added"), (e) => Singularity.Pdf.Stamps.apply_header_footer (e, h));
            });

            var wm = add_group (_("Watermark"));
            var text = new EntryRow (_("Watermark Text"));
            text.text = _("CONFIDENTIAL");
            wm.add_row (text);
            var image_row = new ActionRow (_("Use an Image Instead…"), null, "image-x-generic-symbolic");
            string image_path = "";
            image_row.activated.connect (() => {
                ctx.choose_open.begin (_("Choose Watermark Image"), "image/*", null, (obj, res) => {
                    var f = ctx.choose_open.end (res);
                    if (f == null) return;
                    image_path = f.get_path ();
                    image_row.subtitle = f.get_basename ();
                });
            });
            wm.add_row (image_row);
            var wsize = new SpinRow (_("Text Size"), null, 8, 300, 1, 72);
            var opacity = new SpinRow (_("Opacity (%)"), null, 5, 100, 5, 25);
            var rotation = new SpinRow (_("Rotation (degrees)"), null, -180, 180, 5, 45);
            var behind = new SwitchRow (_("Behind the Page Content"), _("Use it as a background"), false);
            var wrange = new HintEntryRow (_("Pages"), _("For example 1,3-4, empty for all"));
            foreach (var r in new Widget[] { wsize, opacity, rotation, behind, wrange }) wm.add_row (r);
            var remove_wm = new ActionRow (_("Remove Watermarks"), null, "edit-clear-symbolic");
            remove_wm.activated.connect (() => ctx.run (_("Removed"), (e) => Singularity.Pdf.Stamps.remove_pagination (e, "Watermark")));
            wm.add_row (remove_wm);
            var add_wm = header_button (wm, _("Add"), true);
            add_wm.tooltip_text = _("Add Watermark");
            add_wm.clicked.connect (() => {
                var w = new Singularity.Pdf.Watermark ();
                w.text = text.text;
                w.image_path = image_path;
                w.size = wsize.value;
                w.opacity = opacity.value / 100;
                w.rotation = rotation.value;
                w.behind = behind.active;
                w.color = Singularity.Pdf.Annotations.rgb (ctx.app.settings.get_string ("markup-color"));
                var pages = ctx.parse_pages (wrange.text, ctx.document.n_pages);
                if (pages.length > 0) {
                    w.first_page = pages[0];
                    w.last_page = pages[pages.length - 1];
                }
                ctx.run (_("Watermark added"), (e) => Singularity.Pdf.Stamps.apply_watermark (e, w));
            });
        }
    }
}
