using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class OptimizePage : ToolPage {
        private Label result;

        public OptimizePage () {
            base (_("Optimize"), "package-x-generic-symbolic");
        }

        public override void build () {
            var preset = add_group (_("Size"));
            var quality = new SelectionRow (_("Target"), { _("Smallest File"), _("Balanced"), _("High Quality") }, _("Balanced"));
            preset.add_row (quality);
            var downsample = new SwitchRow (_("Reduce Image Resolution"), null, true);
            preset.add_row (downsample);
            var dpi = new SpinRow (_("Image Resolution (dpi)"), null, 50, 600, 10, 150);
            preset.add_row (dpi);
            var jpeg = new SpinRow (_("Photo Quality"), null, 20, 100, 5, 75);
            preset.add_row (jpeg);
            quality.selected.connect ((v) => {
                if (v == _("Smallest File")) {
                    dpi.value = 96;
                    jpeg.value = 55;
                } else if (v == _("High Quality")) {
                    dpi.value = 300;
                    jpeg.value = 90;
                } else {
                    dpi.value = 150;
                    jpeg.value = 75;
                }
            });
            var cleanup = add_group (_("Cleanup"));
            var dedupe = new SwitchRow (_("Merge Duplicate Images and Fonts"), null, true);
            var objstm = new SwitchRow (_("Compress Document Structure"), _("Needs PDF 1.5 or later to open"), true);
            var meta = new SwitchRow (_("Remove Metadata and Private Data"), null, false);
            var thumbs = new SwitchRow (_("Remove Embedded Thumbnails"), null, true);
            foreach (var r in new SwitchRow[] { dedupe, objstm, meta, thumbs }) cleanup.add_row (r);
            var web = add_group (_("Fast Web View"), _("Writes the file so its first page shows before the rest has downloaded."));
            var web_row = new ActionRow (_("Save for Fast Web View…"), null, "document-save-as-symbolic");
            web_row.activated.connect (() => save_linearized.begin ());
            web.add_row (web_row);
            var outcome = add_group (_("Result"));
            outcome.visible = false;
            result = text_row (outcome);
            var go = footer_button (_("Optimize"), true);
            go.clicked.connect (() => {
                var engine = ctx.engine ();
                if (engine == null) return;
                var opts = new Singularity.Pdf.OptimizeOptions ();
                opts.downsample = downsample.active;
                opts.color_dpi = (int) dpi.value;
                opts.jpeg_quality = (int) jpeg.value;
                opts.deduplicate = dedupe.active;
                opts.object_streams = objstm.active;
                opts.remove_metadata = meta.active;
                opts.remove_thumbnails = thumbs.active;
                var report = new Singularity.Pdf.OptimizeReport ();
                try {
                    int64 before = ctx.document.current_bytes ().length;
                    var bytes = Singularity.Pdf.Optimizer.run (engine, opts, report);
                    ctx.document.replace_bytes (bytes);
                    outcome.visible = true;
                    result.label = _("%s before, %s after. %d images resampled, %d duplicates merged, %d streams compressed.").printf (
                        format_size (before), format_size (bytes.length), report.images_resampled, report.duplicates_merged, report.streams_compressed);
                    ctx.toast (_("Document optimized"));
                } catch (Error e) {
                    ctx.error_dialog (_("The document could not be optimized"), e.message);
                }
            });
        }

        private async void save_linearized () {
            var file = yield ctx.choose_save (_("Save for Fast Web View"), _("%s (web).pdf").printf (ctx.base_name ()), "application/pdf");
            if (file == null) return;
            try {
                var engine = ctx.document.open_engine ();
                ctx.write_file (file, Singularity.Pdf.Linearizer.write (engine));
                ctx.toast (_("Saved for fast web view"));
            } catch (Error e) {
                ctx.error_dialog (_("The document could not be saved"), e.message);
            }
        }
    }
}
