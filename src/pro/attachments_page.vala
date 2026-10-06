using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class AttachmentsPage : ToolPage {
        private PreferencesGroup? files = null;
        private ulong point_handler = 0;

        public AttachmentsPage () {
            base (_("Attachments"), "mail-attachment-symbolic");
        }

        public override void build () {
            files = add_group (_("Attached Files"));
            var add = add_group (_("Add"));
            var doc_level = new ActionRow (_("Attach File to Document…"), null, "list-add-symbolic");
            doc_level.activated.connect (() => attach.begin (false));
            add.add_row (doc_level);
            var page_level = new ActionRow (_("Attach File to a Spot on the Page…"), _("Choose the file, then click on the page"), "mail-attachment-symbolic");
            page_level.activated.connect (() => attach.begin (true));
            add.add_row (page_level);
            refresh ();
        }

        private async void attach (bool on_page) {
            var file = yield ctx.choose_open (_("Choose File to Attach"));
            if (file == null) return;
            uint8[] data;
            try {
                FileUtils.get_data (file.get_path (), out data);
            } catch (Error e) {
                ctx.error_dialog (_("The file could not be read"), e.message);
                return;
            }
            string name = file.get_basename () ?? "attachment";
            if (!on_page) {
                ctx.run (_("File attached"), (en) => Singularity.Pdf.Attachments.add (en, name, data));
                return;
            }
            if (point_handler != 0) ctx.view.disconnect (point_handler);
            ctx.view.tool = Tool.POINT;
            point_handler = ctx.view.point_picked.connect ((page, x, y, widget) => {
                ctx.view.disconnect (point_handler);
                point_handler = 0;
                ctx.view.tool = Tool.SELECT;
                ctx.run (_("File attached"), (en) => {
                    double px, py;
                    PageMap.point_to_pdf (en, page, x, y, out px, out py);
                    Singularity.Pdf.Annotations.file_attachment (en, page, px, py, name, data, ctx.author, "");
                });
            });
        }

        public override void enter () {
            refresh ();
        }

        public override void document_changed () {
            refresh ();
        }

        public override void leave () {
            if (point_handler != 0) ctx.view.disconnect (point_handler);
            point_handler = 0;
        }

        private void refresh () {
            if (files == null) return;
            files.clear ();
            var e = ctx.engine ();
            if (e == null) return;
            var list = Singularity.Pdf.Attachments.list (e);
            if (list.size == 0) files.description = _("No files are attached.");
            else if (Singularity.Pdf.Attachments.is_portfolio (e)) files.description = _("This document is a portfolio: its files are listed below and can be saved, but the portfolio layout is shown as a plain list.");
            else files.description = "";
            var group = files;
            foreach (var a in list) {
                string sub = a.size >= 0 ? format_size (a.size) : "";
                if (a.page >= 0) sub += (sub != "" ? ", " : "") + _("page %d").printf (a.page + 1);
                if (a.description != "" && a.description != a.name) sub += (sub != "" ? ", " : "") + a.description;
                var exp = new ExpanderRow (a.name, sub, "mail-attachment-symbolic");
                var info = a;
                var save = new ActionRow (_("Save As…"), null, "document-save-as-symbolic");
                save.activated.connect (() => save_attachment.begin (info));
                exp.add_row (save);
                var open = new ActionRow (_("Open"), null, "document-open-symbolic");
                open.activated.connect (() => open_attachment (info));
                exp.add_row (open);
                var remove = new ActionRow (_("Remove"), null, "user-trash-symbolic");
                string name = a.name;
                remove.activated.connect (() => ctx.run (_("Attachment removed"), (en) => {
                    foreach (var x in Singularity.Pdf.Attachments.list (en)) {
                        if (x.name == name) {
                            Singularity.Pdf.Attachments.remove (en, x);
                            break;
                        }
                    }
                }));
                exp.add_row (remove);
                group.add_row (exp);
            }
        }

        private async void save_attachment (Singularity.Pdf.AttachmentInfo info) {
            var file = yield ctx.choose_save (_("Save Attachment"), info.name);
            if (file == null) return;
            try {
                var e = ctx.document.open_engine ();
                foreach (var x in Singularity.Pdf.Attachments.list (e)) {
                    if (x.name == info.name) {
                        ctx.write_file (file, Singularity.Pdf.Attachments.data (e, x));
                        ctx.toast (_("Attachment saved"));
                        return;
                    }
                }
            } catch (Error err) {
                ctx.error_dialog (_("The attachment could not be saved"), err.message);
            }
        }

        private void open_attachment (Singularity.Pdf.AttachmentInfo info) {
            try {
                var e = ctx.document.open_engine ();
                foreach (var x in Singularity.Pdf.Attachments.list (e)) {
                    if (x.name != info.name) continue;
                    string dir = Path.build_filename (Environment.get_user_cache_dir (), "singularity-reader", "attachments");
                    DirUtils.create_with_parents (dir, 0700);
                    string path = Path.build_filename (dir, Path.get_basename (x.name));
                    FileUtils.set_data (path, Singularity.Pdf.Attachments.data (e, x));
                    var launcher = new FileLauncher (File.new_for_path (path));
                    launcher.launch.begin (ctx.window, null);
                    return;
                }
            } catch (Error err) {
                ctx.error_dialog (_("The attachment could not be opened"), err.message);
            }
        }
    }
}
