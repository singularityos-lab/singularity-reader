using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class BatchPage : ToolPage {
        private File? input = null;
        private File? output = null;
        private Label log;
        private PreferencesGroup result_group;
        private ProgressBar progress;
        private SwitchRow ocr_row;
        private SwitchRow optimize_row;
        private SwitchRow number_row;
        private SwitchRow watermark_row;
        private EntryRow watermark_text;
        private SwitchRow sanitize_row;
        private SwitchRow pdfa_row;
        private SwitchRow tag_row;
        private SwitchRow protect_row;
        private PasswordRow password_row;
        private Button run_button;
        private Cancellable? cancellable = null;

        public BatchPage () {
            base (_("Batch Actions"), "system-run-symbolic");
        }

        public override void build () {
            var folders = add_group (_("Folders"));
            var in_row = new ActionRow (_("PDF Files From…"), _("Choose a folder"), "folder-open-symbolic");
            in_row.activated.connect (() => ctx.choose_folder.begin (_("Folder with PDF Files"), (o, r) => {
                input = ctx.choose_folder.end (r);
                if (input != null) in_row.subtitle = input.get_parse_name ();
            }));
            folders.add_row (in_row);
            var out_row = new ActionRow (_("Save Results To…"), _("Choose a folder"), "folder-symbolic");
            out_row.activated.connect (() => ctx.choose_folder.begin (_("Folder for the Results"), (o, r) => {
                output = ctx.choose_folder.end (r);
                if (output != null) out_row.subtitle = output.get_parse_name ();
            }));
            folders.add_row (out_row);
            var steps = add_group (_("Steps"), _("Applied to every file, in this order."));
            ocr_row = new SwitchRow (_("Recognize Text"), null, false);
            sanitize_row = new SwitchRow (_("Remove Hidden Information"), null, false);
            number_row = new SwitchRow (_("Number Pages"), null, false);
            watermark_row = new SwitchRow (_("Add Watermark"), null, false);
            watermark_text = new EntryRow (_("Watermark Text"));
            watermark_text.text = _("DRAFT");
            tag_row = new SwitchRow (_("Add Accessibility Tags"), null, false);
            pdfa_row = new SwitchRow (_("Convert to PDF/A-2b"), null, false);
            optimize_row = new SwitchRow (_("Optimize"), null, true);
            protect_row = new SwitchRow (_("Protect with Password"), null, false);
            password_row = new PasswordRow (_("Password"));
            foreach (var r in new Widget[] { ocr_row, sanitize_row, number_row, watermark_row, watermark_text, tag_row, pdfa_row, optimize_row, protect_row, password_row }) steps.add_row (r);
            watermark_row.switch_btn.bind_property ("active", watermark_text, "visible", BindingFlags.SYNC_CREATE);
            protect_row.switch_btn.bind_property ("active", password_row, "visible", BindingFlags.SYNC_CREATE);
            result_group = add_group (_("Progress"));
            result_group.visible = false;
            progress = new ProgressBar ();
            progress.show_text = true;
            progress.margin_top = 14;
            progress.margin_bottom = 14;
            progress.margin_start = 12;
            progress.margin_end = 12;
            var progress_row = new PreferencesRow ();
            progress_row.activatable = false;
            progress_row.child = progress;
            progress.bind_property ("visible", progress_row, "visible", BindingFlags.SYNC_CREATE);
            result_group.add_row (progress_row);
            log = text_row (result_group);
            log.get_parent ().visible = false;
            run_button = footer_button (_("Run"), true);
            run_button.clicked.connect (() => {
                if (cancellable != null) {
                    cancellable.cancel ();
                    return;
                }
                run.begin ();
            });

        }

        private async void run () {
            if (input == null || output == null) {
                ctx.toast (_("Choose both folders first"));
                return;
            }
            var files = new Gee.ArrayList<File> ();
            try {
                var e = input.enumerate_children (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE);
                FileInfo? info;
                while ((info = e.next_file ()) != null) {
                    if (info.get_name ().down ().has_suffix (".pdf")) files.add (input.get_child (info.get_name ()));
                }
            } catch (Error err) {
                ctx.error_dialog (_("The folder could not be read"), err.message);
                return;
            }
            files.sort ((a, b) => strcmp (a.get_basename (), b.get_basename ()));
            cancellable = new Cancellable ();
            run_button.label = _("Stop");
            result_group.visible = true;
            progress.visible = true;
            var report = new StringBuilder ();
            int ok = 0;
            for (int i = 0; i < files.size; i++) {
                if (cancellable.is_cancelled ()) break;
                var f = files[i];
                progress.fraction = (double) i / files.size;
                progress.text = f.get_basename ();
                try {
                    uint8[] data;
                    FileUtils.get_data (f.get_path (), out data);
                    if (ocr_row.active) {
                        int words;
                        data = yield Operations.ocr (data, "", true, cancellable, out words);
                    }
                    if (sanitize_row.active) data = Operations.sanitize (data, "");
                    if (number_row.active) data = Operations.number_pages (data, "", f.get_basename ());
                    if (watermark_row.active) data = Operations.watermark (data, "", watermark_text.text);
                    if (tag_row.active) data = Operations.tag (data, "", StandardsPage.default_language ());
                    if (pdfa_row.active) {
                        int remaining;
                        data = Operations.pdfa (data, "", "2b", out remaining);
                        if (remaining > 0) report.append (_("%s: %d PDF/A problems left\n").printf (f.get_basename (), remaining));
                    }
                    if (optimize_row.active) data = Operations.optimize (data, "", 150, 75);
                    if (protect_row.active && password_row.text != "") data = Operations.protect (data, "", password_row.text);
                    FileUtils.set_data (output.get_child (f.get_basename ()).get_path (), data);
                    ok++;
                } catch (Error err) {
                    report.append ("%s: %s\n".printf (f.get_basename (), err.message));
                }
                Idle.add (run.callback);
                yield;
            }
            report.prepend (_("%d of %d files processed.\n").printf (ok, files.size));
            log.label = report.str.strip ();
            log.get_parent ().visible = true;
            progress.visible = false;
            run_button.label = _("Run");
            cancellable = null;
        }
    }
}
