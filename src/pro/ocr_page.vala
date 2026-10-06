using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class OcrPage : ToolPage {
        private ProgressBar progress;
        private Cancellable? cancellable = null;
        private SelectionRow pages_row;
        private SwitchRow skip_row;
        private Button run_button;

        public OcrPage () {
            base (_("Recognize Text"), "edit-find-replace-symbolic");
        }

        public override void build () {
            var recognizer = Singularity.TextRecognition.Recognizer.get_default ();
            var group = add_group (_("Text Recognition"));
            pages_row = new SelectionRow (_("Pages"), { _("All Pages"), _("Current Page") }, _("All Pages"));
            group.add_row (pages_row);
            skip_row = new SwitchRow (_("Skip Pages That Already Have Text"), null, true);
            group.add_row (skip_row);
            var langs = new ActionRow (_("Languages"), recognizer.chosen_languages ().length > 0 ? string.joinv (", ", recognizer.chosen_languages ()) : _("Automatic, from your system language"), "preferences-desktop-locale-symbolic");
            langs.activatable = false;
            group.add_row (langs);
            progress = new ProgressBar ();
            progress.margin_top = 14;
            progress.margin_bottom = 14;
            progress.margin_start = 12;
            progress.margin_end = 12;
            progress.valign = Align.CENTER;
            var progress_row = new PreferencesRow ();
            progress_row.activatable = false;
            progress_row.child = progress;
            progress_row.visible = false;
            progress.bind_property ("visible", progress_row, "visible", BindingFlags.SYNC_CREATE);
            group.add_row (progress_row);
            progress.visible = false;
            run_button = footer_button (_("Recognize Text"), true);
            run_button.clicked.connect (() => {
                if (cancellable != null) {
                    cancellable.cancel ();
                    return;
                }
                recognize.begin ();
            });
            if (!recognizer.available) {
                group.description = recognizer.install_hint;
                run_button.sensitive = false;
            } else {
                group.description = _("The recognized text is placed invisibly under the page, so it can be searched, selected and read aloud. Recognition runs on this computer with %s.").printf (recognizer.engine.name);
            }

            var clean = add_group (_("Improve Scans"));
            var deskew = new SwitchRow (_("Straighten"), null, true);
            var whiten = new SwitchRow (_("Clean Background"), null, true);
            var borders = new SwitchRow (_("Remove Dark Borders"), null, true);
            clean.add_row (deskew);
            clean.add_row (whiten);
            clean.add_row (borders);
            var apply = new ActionRow (_("Improve Scanned Pages"), _("Only pages made of one scanned image"), "image-x-generic-symbolic");
            apply.activated.connect (() => {
                var opts = new Singularity.Pdf.ScanOptions ();
                opts.deskew = deskew.active;
                opts.whiten = whiten.active;
                opts.remove_borders = borders.active;
                int count = 0;
                double max_angle = 0;
                bool current = pages_row.current_value == _("Current Page");
                int page = ctx.current_page;
                ctx.run ("", (e) => {
                    for (int p = 0; p < e.page_count (); p++) {
                        if (current && p != page) continue;
                        if (!Singularity.Pdf.Scans.is_scanned (e, p) && Singularity.Pdf.Scans.main_image (e, p) == null) continue;
                        double a = Singularity.Pdf.Scans.clean_page (e, p, opts);
                        max_angle = double.max (max_angle, a.abs ());
                        count++;
                    }
                });
                ctx.toast (count == 0 ? _("No scanned pages found") : ngettext ("%d page improved", "%d pages improved", count).printf (count) + (max_angle > 0 ? ", " + _("straightened up to %.1f degrees").printf (max_angle) : ""));
            });
            clean.add_row (apply);

            var create = add_group (_("Create PDF from Scans"));
            var from_images = new ActionRow (_("From Images or Photos…"), null, "camera-photo-symbolic");
            from_images.activated.connect (() => images_to_pdf.begin ());
            create.add_row (from_images);
            var from_scanner = new ActionRow (_("From the Scanner…"), _("Opens Scanner; open the saved PDF here to recognize its text"), "edit-find-replace-symbolic");
            from_scanner.activated.connect (() => {
                AppInfo? info = null;
                foreach (var candidate in AppInfo.get_all ()) {
                    if (candidate.get_id () == "dev.sinty.scanner.desktop") info = candidate;
                }
                try {
                    if (info == null) throw new IOError.NOT_FOUND (_("Scanner is not installed"));
                    info.launch (null, ctx.window.get_display ().get_app_launch_context ());
                } catch (Error e) {
                    ctx.error_dialog (_("Scanner could not be opened"), e.message);
                }
            });
            create.add_row (from_scanner);
        }

        private async void images_to_pdf () {
            var files = yield ctx.choose_many (_("Choose Images"), { "image/png", "image/jpeg", "image/tiff", "image/webp", "image/bmp" });
            if (files.length == 0) return;
            var target = yield ctx.choose_save (_("Save PDF"), _("Scan.pdf"), "application/pdf");
            if (target == null) return;
            try {
                string[] paths = {};
                foreach (var f in files) paths += f.get_path ();
                var doc = Singularity.Pdf.Scans.from_images (paths, 595.28, 841.89);
                ctx.write_file (target, doc.save ());
                ctx.open_result (target);
            } catch (Error e) {
                ctx.error_dialog (_("The PDF could not be created"), e.message);
            }
        }

        private Gdk.Texture render_page (int index, double dpi, out double scale) {
            var doc = ctx.document;
            scale = dpi / 72.0;
            int w = int.max (1, (int) (doc.width (index) * scale)), h = int.max (1, (int) (doc.height (index) * scale));
            var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, w, h);
            var cr = new Cairo.Context (surface);
            cr.set_source_rgb (1, 1, 1);
            cr.paint ();
            cr.scale (scale, scale);
            doc.page (index).render_for_printing (cr);
            surface.flush ();
            var bytes = new Bytes (surface.get_data ()[0 : surface.get_stride () * h]);
            return new Gdk.MemoryTexture (w, h, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, bytes, surface.get_stride ());
        }

        private async void recognize () {
            var recognizer = Singularity.TextRecognition.Recognizer.get_default ();
            var engine = ctx.engine ();
            if (engine == null) return;
            cancellable = new Cancellable ();
            run_button.label = _("Stop");
            progress.visible = true;
            progress.fraction = 0;
            int first = 0, last = ctx.document.n_pages - 1;
            if (pages_row.current_value == _("Current Page")) first = last = ctx.current_page;
            int done = 0, words_total = 0;
            var results = new Gee.HashMap<int, Gee.ArrayList<Singularity.Pdf.OcrWord>> ();
            try {
                for (int p = first; p <= last; p++) {
                    if (cancellable.is_cancelled ()) break;
                    progress.text = _("Page %d of %d").printf (p - first + 1, last - first + 1);
                    progress.show_text = true;
                    if (skip_row.active && Singularity.Pdf.Scans.has_text_layer (engine, p) && !Singularity.Pdf.Scans.is_scanned (engine, p)) {
                        done++;
                        continue;
                    }
                    double scale;
                    var texture = render_page (p, 300, out scale);
                    var text = yield recognizer.recognize_texture (texture, cancellable);
                    var words = new Gee.ArrayList<Singularity.Pdf.OcrWord> ();
                    foreach (var w in text.words) {
                        if (w.text.strip () == "") continue;
                        var view = Geometry.rect (w.x / scale, w.y / scale, (w.x + w.width) / scale, (w.y + w.height) / scale);
                        words.add (new Singularity.Pdf.OcrWord (w.text, PageMap.to_pdf (engine, p, view)));
                    }
                    results[p] = words;
                    words_total += words.size;
                    done++;
                    progress.fraction = (double) done / (last - first + 1);
                }
                if (results.size > 0) {
                    ctx.run ("", (e) => {
                        foreach (var entry in results.entries) Singularity.Pdf.Scans.add_text_layer (e, entry.key, entry.value);
                    });
                }
                ctx.toast (ngettext ("%d word recognized", "%d words recognized", words_total).printf (words_total));
            } catch (Error e) {
                if (!(e is IOError.CANCELLED)) ctx.error_dialog (_("Text recognition failed"), e.message);
            }
            cancellable = null;
            run_button.label = _("Recognize Text");
            progress.visible = false;
        }
    }
}
