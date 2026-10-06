using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class SignPage : ToolPage {
        private PreferencesGroup? verify = null;
        private Gee.ArrayList<Widget> signature_rows = new Gee.ArrayList<Widget> ();
        private string? p12_path = null;
        private ActionRow cert_row;
        private PasswordRow password;
        private EntryRow reason;
        private EntryRow location;
        private EntryRow tsa;
        private SwitchRow visible_row;
        private SwitchRow certify_row;
        private SelectionRow token_row;
        private Gee.List<TokenCert> tokens = new Gee.ArrayList<TokenCert> ();
        private ulong area_handler = 0;
        private SwitchRow revocation_row;
        private SelectionRow field_row;

        public SignPage () {
            base (_("Digital Signature"), "security-high-symbolic");
        }

        public override void build () {
            verify = add_group (_("Signatures in This Document"));
            revocation_row = new SwitchRow (_("Check Revocation Online"), _("Asks the certificate authority whether the certificate was revoked"), false);
            revocation_row.switch_btn.notify["active"].connect (refresh);
            verify.add_row (revocation_row);

            var cert = add_group (_("Sign with a Certificate"));
            cert_row = new ActionRow (_("Certificate File…"), _("PKCS#12, .p12 or .pfx"), "dialog-password-symbolic");
            cert_row.activated.connect (() => {
                ctx.choose_open.begin (_("Choose Certificate"), null, "*.[pP][fF12]*", (o, r) => {
                    var f = ctx.choose_open.end (r);
                    if (f == null) return;
                    p12_path = f.get_path ();
                    cert_row.subtitle = f.get_basename ();
                    token_row.current_value = _("None");
                });
            });
            cert.add_row (cert_row);
            token_row = new SelectionRow (_("Smart Card"), { _("None") }, _("None"));
            cert.add_row (token_row);
            password = new PasswordRow (_("Password or PIN"));
            cert.add_row (password);
            reason = new EntryRow (_("Reason"));
            cert.add_row (reason);
            location = new EntryRow (_("Place"));
            cert.add_row (location);
            tsa = new HintEntryRow (_("Timestamp Server"), _("Optional"));
            tsa.text = ctx.app.settings.get_string ("timestamp-server");
            cert.add_row (tsa);
            field_row = new SelectionRow (_("Signature Field"), { _("New Field") }, _("New Field"));
            cert.add_row (field_row);
            visible_row = new SwitchRow (_("Visible Signature"), _("Drag where it appears on the page"), true);
            cert.add_row (visible_row);
            certify_row = new SwitchRow (_("Certify"), _("Allow only form filling and signing afterwards"), false);
            cert.add_row (certify_row);
            var sign = footer_button (_("Sign…"), true);
            sign.clicked.connect (start_sign);
            var others = add_group (_("Ask Others to Sign"), _("Each person opens the file in a PDF reader that signs with certificates, signs their own field and sends it back; the signatures are checked above."));
            var signers = new HintEntryRow (_("Signers"), _("Names separated by commas"));
            others.add_row (signers);
            var send = new ActionRow (_("Prepare and Send…"), _("Adds a signature field for each person, then shares the file"), "mail-send-symbolic");
            send.activated.connect (() => request_signatures.begin (signers.text));
            others.add_row (send);
            var trust = add_group (_("Trust"));
            var add_trust = new ActionRow (_("Trust a Certificate Authority…"), _("Signatures from it will show as trusted"), "emblem-default-symbolic");
            add_trust.activated.connect (() => {
                ctx.choose_open.begin (_("Choose a Certificate to Trust"), null, null, (o, r) => {
                    var f = ctx.choose_open.end (r);
                    if (f == null) return;
                    try {
                        DigitalSigner.trust_certificate (f.get_path ());
                        ctx.toast (_("Certificate trusted"));
                        refresh ();
                    } catch (Error e) {
                        ctx.error_dialog (_("The certificate could not be added"), e.message);
                    }
                });
            });
            trust.add_row (add_trust);
            var stamp = new ActionRow (_("Add a Document Timestamp"), _("Proves the file existed at this time, uses the timestamp server above"), "x-office-calendar-symbolic");
            stamp.activated.connect (() => {
                string url = tsa.text.strip ();
                if (url == "") {
                    ctx.toast (_("Enter a timestamp server first"));
                    return;
                }
                apply_signed (() => {
                    var engine = ctx.document.open_engine ();
                    return DigitalSigner.timestamp_document_online (engine, url);
                });
            });
            trust.add_row (stamp);
        }

        private delegate uint8[] Producer () throws Error;

        private void apply_signed (Producer producer) {
            try {
                var bytes = producer ();
                ctx.document.replace_bytes (bytes);
                ctx.toast (_("Signed. Save the document to keep the signature."));
            } catch (Error e) {
                ctx.error_dialog (_("The document could not be signed"), e.message);
            }
        }

        private void start_sign () {
            bool token = token_row.current_value != _("None");
            if (!token && p12_path == null) {
                ctx.toast (_("Choose a certificate file or a smart card first"));
                return;
            }
            if (ctx.document.modified && !ctx.document.file.query_exists ()) {
                ctx.toast (_("Save the document before signing"));
                return;
            }
            if (!visible_row.active || field_row.current_value != _("New Field")) {
                sign (-1, null);
                return;
            }
            if (area_handler != 0) ctx.view.disconnect (area_handler);
            ctx.view.tool = Tool.AREA;
            ctx.toast (_("Drag where the signature appears"));
            area_handler = ctx.view.area_picked.connect ((page, area, widget) => {
                ctx.view.disconnect (area_handler);
                area_handler = 0;
                ctx.view.tool = Tool.SELECT;
                sign (page, area);
            });
        }

        private void sign (int page, Poppler.Rectangle? area) {
            string url = tsa.text.strip ();
            ctx.app.settings.set_string ("timestamp-server", url);
            bool token = token_row.current_value != _("None");
            string token_url = "";
            foreach (var t in tokens) if (t.label == token_row.current_value) token_url = t.url;
            string pw = password.text;
            apply_signed (() => {
                var engine = ctx.document.open_engine ();
                var req = new Singularity.Pdf.SignatureRequest ();
                req.signer = ctx.author;
                if (field_row.current_value != _("New Field")) req.field_name = field_row.current_value;
                req.reason = reason.text;
                req.location = location.text;
                if (certify_row.active) req.certify_permissions = 2;
                if (page >= 0 && area != null) {
                    req.page = page;
                    req.rect = PageMap.to_pdf (engine, page, area);
                } else {
                    req.page = ctx.current_page;
                }
                if (token) return DigitalSigner.sign_pkcs11 (engine, req, token_url, pw, url != "" ? url : null);
                return DigitalSigner.sign_file_pkcs12 (engine, req, p12_path, pw, url != "" ? url : null);
            });
            password.text = "";
        }

        public override void enter () {
            tokens = DigitalSigner.list_tokens ();
            string[] labels = { _("None") };
            foreach (var t in tokens) labels += t.label;
            token_row.set_items (labels);
            string[] fields = { _("New Field") };
            var e = ctx.engine ();
            if (e != null) {
                foreach (var f in Singularity.Pdf.Forms.list (e)) {
                    if (f.type == Singularity.Pdf.FieldType.SIGNATURE && f.value == "") fields += f.name;
                }
            }
            field_row.set_items (fields);
            field_row.current_value = fields.length > 1 ? fields[1] : fields[0];
            refresh ();
        }

        public override void leave () {
            if (area_handler != 0) ctx.view.disconnect (area_handler);
            area_handler = 0;
            if (ctx.view.tool == Tool.AREA) ctx.view.tool = Tool.SELECT;
        }

        public override void document_changed () {
            refresh ();
        }

        private void refresh () {
            if (verify == null) return;
            foreach (var w in signature_rows) verify.remove_row (w);
            signature_rows.clear ();
            var e = ctx.engine ();
            if (e == null) return;
            var list = DigitalSigner.verify (e, revocation_row.active);
            verify.description = list.size == 0 ? _("This document is not signed.") : "";
            var group = verify;
            foreach (var s in list) {
                string icon;
                string state;
                switch (s.status) {
                    case SignatureState.VALID_TRUSTED:
                        icon = "security-high-symbolic";
                        state = _("Valid and trusted");
                        break;
                    case SignatureState.VALID_UNTRUSTED:
                        icon = "dialog-warning-symbolic";
                        state = _("Valid, but the signer is not in your trusted list");
                        break;
                    case SignatureState.MODIFIED_AFTER:
                        icon = "dialog-warning-symbolic";
                        state = s.only_annotations_after ? _("Valid, comments or form data were added after signing") : _("Valid for an earlier version, the document was changed after signing");
                        break;
                    case SignatureState.INVALID:
                        icon = "dialog-error-symbolic";
                        state = _("Not valid, the signed content was altered");
                        break;
                    default:
                        icon = "dialog-question-symbolic";
                        state = s.message != "" ? s.message : _("Cannot be verified");
                        break;
                }
                string who = s.is_document_timestamp ? _("Document timestamp") : (s.signer != "" ? s.signer : s.signer_dn);
                var exp = new ExpanderRow (who, state, icon);
                if (s.signing_time != null) exp.add_row (new ActionRow (_("Signed"), s.signing_time.to_local ().format ("%x %X") + (s.timestamped ? ", " + _("timestamped") : "")));
                if (s.issuer != "") exp.add_row (new ActionRow (_("Issued by"), s.issuer));
                if (s.valid_until != null) exp.add_row (new ActionRow (_("Certificate valid until"), s.valid_until.to_local ().format ("%x")));
                if (s.reason != "") exp.add_row (new ActionRow (_("Reason"), s.reason));
                if (s.location != "") exp.add_row (new ActionRow (_("Place"), s.location));
                if (s.certification) exp.add_row (new ActionRow (_("Certification signature"), null));
                string rev;
                switch (s.revocation) {
                    case RevocationState.GOOD: rev = _("Not revoked"); break;
                    case RevocationState.REVOKED: rev = _("Revoked"); break;
                    case RevocationState.UNKNOWN: rev = _("Revocation could not be checked"); break;
                    default: rev = _("Revocation not checked"); break;
                }
                exp.add_row (new ActionRow (rev, null));
                if (!s.covers_whole_file && s.revision_end > 0) {
                    var revision = new ActionRow (_("Save the Signed Version…"), _("The file as it was when signed"), "document-save-as-symbolic");
                    int64 end = s.revision_end;
                    revision.activated.connect (() => save_revision.begin (end));
                    exp.add_row (revision);
                }
                if (s.page >= 0) {
                    int page = s.page;
                    var go = new ActionRow (_("Show in Document"), null, "find-location-symbolic");
                    go.activated.connect (() => ctx.view.go_to (page));
                    exp.add_row (go);
                }
                group.add_row (exp);
                signature_rows.add (exp);
            }
        }

        private async void request_signatures (string names) {
            string[] people = {};
            foreach (var n in names.split (",")) if (n.strip () != "") people += n.strip ();
            if (people.length == 0) {
                ctx.toast (_("Type at least one name"));
                return;
            }
            var file = yield ctx.choose_save (_("Save the Copy to Send"), _("%s (to sign).pdf").printf (ctx.base_name ()), "application/pdf");
            if (file == null) return;
            try {
                var e = ctx.document.open_engine ();
                int page = e.page_count () - 1;
                var box = e.page_box (page, "CropBox");
                double y = box[1] + 40;
                foreach (var person in people) {
                    var r = Singularity.Pdf.Rect.of (box[2] - 260, y, box[2] - 40, y + 60);
                    var f = Singularity.Pdf.Forms.create_field (e, page, Singularity.Pdf.FieldType.SIGNATURE, "Signature " + person, r, {}, _("Signature of %s").printf (person));
                    y += 76;
                    if (f == null) continue;
                }
                var opts = new Singularity.Pdf.SaveOptions ();
                opts.mode = Singularity.Pdf.SaveMode.INCREMENTAL;
                ctx.write_file (file, e.save (opts));
                Singularity.Share.files (ctx.window, { file });
            } catch (Error err) {
                ctx.error_dialog (_("The copy could not be prepared"), err.message);
            }
        }

        private async void save_revision (int64 end) {
            var file = yield ctx.choose_save (_("Save Signed Version"), _("%s (signed version).pdf").printf (ctx.base_name ()), "application/pdf");
            if (file == null) return;
            try {
                ctx.write_file (file, Singularity.Pdf.Signing.revision (ctx.document.current_bytes (), end));
            } catch (Error e) {
                ctx.error_dialog (_("The version could not be saved"), e.message);
            }
        }
    }
}
