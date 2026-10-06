using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class ProtectPage : ToolPage {
        private PreferencesGroup state;
        private Gee.ArrayList<string> recipients = new Gee.ArrayList<string> ();
        private PreferencesGroup recipients_group;
        private Gee.ArrayList<Widget> recipient_rows = new Gee.ArrayList<Widget> ();

        public ProtectPage () {
            base (_("Protect"), "channel-secure-symbolic");
        }

        public override void build () {
            state = add_group (_("Current Protection"));
            var remove_row = new ActionRow (_("Remove Passwords and Restrictions"), _("Needs the permissions password when one is set"), "changes-allow-symbolic");
            remove_row.activated.connect (() => {
                var engine = ctx.engine ();
                if (engine == null) return;
                if (engine.security == null) {
                    ctx.toast (_("The document is not protected"));
                    return;
                }
                if (!engine.security.owner_access && (engine.security.p & Singularity.Pdf.Permissions.MODIFY) == 0) {
                    ask_owner_password ();
                    return;
                }
                strip (engine);
            });
            state.add_row (remove_row);
            var open = add_group (_("Password to Open"));
            var user_pw = new PasswordRow (_("Password"));
            open.add_row (user_pw);
            var user_pw2 = new PasswordRow (_("Repeat Password"));
            open.add_row (user_pw2);
            var perms = add_group (_("Permissions"), _("Encryption uses AES with 256-bit keys. Permissions are honored by well-behaved readers only; the open password is what really keeps content private."));
            var owner_pw = new PasswordRow (_("Password to Change Permissions"));
            perms.add_row (owner_pw);
            var print = new SwitchRow (_("Allow Printing"), null, true);
            var print_hq = new SwitchRow (_("Allow High Quality Printing"), null, true);
            var copy = new SwitchRow (_("Allow Copying Text and Images"), null, true);
            var modify = new SwitchRow (_("Allow Editing"), null, false);
            var annotate = new SwitchRow (_("Allow Comments"), null, true);
            var fill = new SwitchRow (_("Allow Filling Forms"), null, true);
            var assemble = new SwitchRow (_("Allow Organizing Pages"), null, false);
            var access = new SwitchRow (_("Allow Screen Readers"), null, true);
            foreach (var r in new SwitchRow[] { print, print_hq, copy, modify, annotate, fill, assemble, access }) perms.add_row (r);
            var apply = footer_button (_("Protect Document"), true);
            apply.clicked.connect (() => {
                if (user_pw.text != user_pw2.text) {
                    ctx.error_dialog (_("The passwords do not match"), _("Type the same password twice."));
                    return;
                }
                if (user_pw.text == "" && owner_pw.text == "") {
                    ctx.error_dialog (_("No password set"), _("Set a password to open the document, a password for permissions, or both."));
                    return;
                }
                int flags = 0;
                if (print.active) flags |= Singularity.Pdf.Permissions.PRINT;
                if (print_hq.active && print.active) flags |= Singularity.Pdf.Permissions.PRINT_HIGH;
                if (copy.active) flags |= Singularity.Pdf.Permissions.COPY;
                if (modify.active) flags |= Singularity.Pdf.Permissions.MODIFY;
                if (annotate.active) flags |= Singularity.Pdf.Permissions.ANNOTATE;
                if (fill.active) flags |= Singularity.Pdf.Permissions.FILL_FORMS;
                if (assemble.active) flags |= Singularity.Pdf.Permissions.ASSEMBLE;
                if (access.active) flags |= Singularity.Pdf.Permissions.ACCESSIBILITY;
                string upw = user_pw.text;
                string opw = owner_pw.text != "" ? owner_pw.text : Uuid.string_random ();
                var engine = ctx.engine ();
                if (engine == null) return;
                try {
                    var opts = new Singularity.Pdf.SaveOptions ();
                    opts.new_security = Singularity.Pdf.SecurityHandler.create_aes256 (upw, opw, flags);
                    ctx.document.replace_bytes (engine.save (opts), upw != "" ? upw : "");
                    ctx.toast (_("Document protected"));
                    user_pw.text = "";
                    user_pw2.text = "";
                    owner_pw.text = "";
                    refresh ();
                } catch (Error e) {
                    ctx.error_dialog (_("The document could not be protected"), e.message);
                }
            });
            recipients_group = add_group (_("Encrypt for Certificates"), _("Only the people whose certificates you add can open the file. Add your own certificate too, or you will not be able to open it again."));
            var add_cert = new ActionRow (_("Add Recipient Certificate…"), _("PEM, CRT or CER file of each person who may open it"), "list-add-symbolic");
            add_cert.activated.connect (() => {
                ctx.choose_open.begin (_("Choose a Certificate"), null, null, (o, r) => {
                    var f = ctx.choose_open.end (r);
                    if (f == null || f.get_path () in recipients) return;
                    recipients.add (f.get_path ());
                    refresh_recipients ();
                });
            });
            recipients_group.add_row (add_cert);
            var encrypt = header_button (recipients_group, _("Encrypt…"));
            encrypt.tooltip_text = _("Encrypt and Save As…");
            encrypt.clicked.connect (() => encrypt_for_certificates.begin ());
        }

        private void refresh_recipients () {
            foreach (var w in recipient_rows) recipients_group.remove_row (w);
            recipient_rows.clear ();
            foreach (var path in recipients) {
                var row = new ActionRow (Path.get_basename (path), null, "dialog-password-symbolic");
                var remove = new Button.from_icon_name ("user-trash-symbolic");
                remove.add_css_class ("flat");
                remove.valign = Align.CENTER;
                remove.tooltip_text = _("Remove");
                string p = path;
                remove.clicked.connect (() => {
                    recipients.remove (p);
                    refresh_recipients ();
                });
                row.add_suffix (remove);
                recipients_group.add_row (row);
                recipient_rows.add (row);
            }
        }

        private async void encrypt_for_certificates () {
            if (recipients.size == 0) {
                ctx.toast (_("Add at least one certificate"));
                return;
            }
            var file = yield ctx.choose_save (_("Save Encrypted Copy"), _("%s (encrypted).pdf").printf (ctx.base_name ()), "application/pdf");
            if (file == null) return;
            try {
                var engine = ctx.document.open_engine ();
                var bytes = CertEncryption.encrypt_for (engine, recipients.to_array (), Singularity.Pdf.Permissions.ALL);
                ctx.write_file (file, bytes);
                ctx.toast (ngettext ("Encrypted for %d certificate", "Encrypted for %d certificates", recipients.size).printf (recipients.size));
            } catch (Error e) {
                ctx.error_dialog (_("The document could not be encrypted"), e.message);
            }
        }

        private void strip (Singularity.Pdf.Document engine) {
            try {
                var opts = new Singularity.Pdf.SaveOptions ();
                opts.remove_security = true;
                ctx.document.replace_bytes (engine.save (opts), "");
                ctx.toast (_("Protection removed"));
                refresh ();
            } catch (Error e) {
                ctx.error_dialog (_("The protection could not be removed"), e.message);
            }
        }

        private void ask_owner_password () {
            var dlg = new ConfirmDialog (ctx.app, _("Permissions Password"), "dialog-password",
                _("Enter the password that protects the permissions of this document."), _("Remove"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = ctx.window;
            var entry = new PasswordEntry ();
            entry.show_peek_icon = true;
            dlg.custom_area.append (entry);
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                try {
                    var engine = Singularity.Pdf.Document.open_bytes (ctx.document.current_bytes (), entry.text);
                    if (!engine.security.owner_access) throw new IOError.PERMISSION_DENIED (_("The password is not the permissions password"));
                    strip (engine);
                } catch (Error e) {
                    ctx.error_dialog (_("The protection could not be removed"), e.message);
                }
            });
            dlg.present ();
        }

        public override void enter () {
            refresh ();
        }

        public override void document_changed () {
            refresh ();
        }

        private void refresh () {
            var e = ctx.engine ();
            if (e == null || state == null) return;
            if (e.security == null) {
                state.description = _("This document is not protected.");
                return;
            }
            string algo = e.security.revision >= 5 ? "AES-256" : (e.security.stream_method == Singularity.Pdf.CryptMethod.AESV2 ? "AES-128" : "RC4");
            state.description = _("This document is encrypted with %s.").printf (algo);
        }
    }
}
