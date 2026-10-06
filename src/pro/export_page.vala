using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class ExportPage : ToolPage {
        private SpinRow dpi;
        private EntryRow range;

        public ExportPage () {
            base (_("Export and Create"), "document-send-symbolic");
        }

        public override void build () {
            var options = add_group (_("Options"));
            range = new HintEntryRow (_("Pages"), _("For example 1-3, empty for all"));
            options.add_row (range);
            dpi = new SpinRow (_("Image Resolution (dpi)"), _("For pictures and slides"), 36, 600, 12, 150);
            options.add_row (dpi);
            var export = add_group (_("Export To"), _("Office exports rebuild paragraphs, headings, simple tables and pictures. Complex layouts are approximated; for faithful copies export pages as images."));
            foreach (var format in Exporter.formats ()) {
                string f = format;
                var row = new ActionRow (Exporter.label (f), "." + Exporter.extension (f), icon_for (f));
                row.activated.connect (() => run.begin (f));
                export.add_row (row);
            }
            var create = add_group (_("Create PDF"));
            var images = new ActionRow (_("From Images…"), null, "image-x-generic-symbolic");
            images.activated.connect (() => CreatePdf.from_images.begin (ctx));
            create.add_row (images);
            var text = new ActionRow (_("From a Text File…"), _("Opens the print dialog, choose Save as PDF"), "text-x-generic-symbolic");
            text.activated.connect (() => CreatePdf.from_text.begin (ctx));
            create.add_row (text);
            var office = new ActionRow (_("From an Office Document…"), _("Opens it in its app, then use Print and Save as PDF"), "x-office-document-symbolic");
            office.activated.connect (() => CreatePdf.from_other.begin (ctx));
            create.add_row (office);
            var combine = new ActionRow (_("Combine Several Files…"), null, "folder-documents-symbolic");
            combine.activated.connect (() => ctx.window.open_tool ("organize"));
            create.add_row (combine);
        }

        private static string icon_for (string f) {
            switch (f) {
                case "docx":
                case "odt":
                case "html":
                    return "x-office-document-symbolic";
                case "xlsx":
                case "ods":
                    return "x-office-spreadsheet-symbolic";
                case "pptx":
                case "odp":
                    return "x-office-presentation-symbolic";
                case "txt":
                    return "text-x-generic-symbolic";
                default:
                    return "image-x-generic-symbolic";
            }
        }

        private async void run (string format) {
            var file = yield ctx.choose_save (_("Export as %s").printf (Exporter.label (format)), ctx.base_name () + "." + Exporter.extension (format));
            if (file == null) return;
            var pages = ctx.parse_pages (range.text, ctx.document.n_pages);
            int first = pages.length > 0 ? pages[0] : 0;
            int last = pages.length > 0 ? pages[pages.length - 1] : -1;
            try {
                Exporter.export (ctx.document.doc, format, file, first, last, dpi.value);
                ctx.toast (_("Exported to %s").printf (file.get_basename ()));
            } catch (Error e) {
                ctx.error_dialog (_("The document could not be exported"), e.message);
            }
        }
    }

    public class CreatePdf : Object {
        public static async void from_images (ProContext ctx) {
            var files = yield ctx.choose_many (_("Choose Images"), { "image/png", "image/jpeg", "image/tiff", "image/webp", "image/bmp", "image/gif" });
            if (files.length == 0) return;
            var target = yield ctx.choose_save (_("Save PDF"), _("Images.pdf"), "application/pdf");
            if (target == null) return;
            try {
                string[] paths = {};
                foreach (var f in files) paths += f.get_path ();
                ctx.write_file (target, Singularity.Pdf.Scans.from_images (paths).save ());
                ctx.open_result (target);
            } catch (Error e) {
                ctx.error_dialog (_("The PDF could not be created"), e.message);
            }
        }

        public static async void from_text (ProContext ctx) {
            var file = yield ctx.choose_open (_("Choose a Text File"), "text/plain");
            if (file == null) return;
            try {
                uint8[] data;
                FileUtils.get_data (file.get_path (), out data);
                var copy = new uint8[data.length + 1];
                Memory.copy (copy, data, data.length);
                string text = (string) copy;
                if (!text.validate ()) text = text.make_valid ();
                var buffer = new TextBuffer (null);
                buffer.text = text;
                string? base_name = file.get_basename ();
                var source = new Singularity.Print.TextBufferSource (buffer, base_name != null ? base_name : _("Text"));
                yield Singularity.Print.run_source (ctx.window, source);
            } catch (Error e) {
                ctx.error_dialog (_("The file could not be read"), e.message);
            }
        }

        public static async void from_other (ProContext ctx) {
            var file = yield ctx.choose_open (_("Choose a Document"));
            if (file == null) return;
            var launcher = new FileLauncher (file);
            try {
                yield launcher.launch (ctx.window, null);
                ctx.toast (_("In the app that opened, choose Print, then Save as PDF"));
            } catch (Error e) {
                ctx.error_dialog (_("The document could not be opened"), e.message);
            }
        }
    }
}
