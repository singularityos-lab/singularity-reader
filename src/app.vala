using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class DocumentHistory : Object {
        private KeyFile keyfile = new KeyFile ();
        private string path;

        public DocumentHistory () {
            path = Path.build_filename (Environment.get_user_state_dir (), "singularity-reader", "history.ini");
            try {
                keyfile.load_from_file (path, KeyFileFlags.NONE);
            } catch (Error e) {
            }
        }

        public int page_for (File file) {
            try {
                return keyfile.get_integer (file.get_uri (), "page");
            } catch (Error e) {
                return 0;
            }
        }

        public void remember (File file, int page) {
            keyfile.set_integer (file.get_uri (), "page", page);
            keyfile.set_int64 (file.get_uri (), "time", new DateTime.now_utc ().to_unix ());
            var groups = keyfile.get_groups ();
            if (groups.length > 300) {
                try {
                    keyfile.remove_group (groups[0]);
                } catch (Error e) {
                }
            }
            try {
                DirUtils.create_with_parents (Path.get_dirname (path), 0700);
                keyfile.save_to_file (path);
            } catch (Error e) {
            }
        }
    }

    public class ReaderApp : Singularity.Application {
        public GLib.Settings settings { get; private set; }
        public SignatureStore signatures { get; private set; }
        public DocumentHistory history { get; private set; }

        public ReaderApp () {
            Object (application_id: "dev.sinty.reader", flags: ApplicationFlags.HANDLES_OPEN);
        }

        protected override void startup () {
            base.startup ();
            settings = new GLib.Settings ("dev.sinty.reader");
            signatures = new SignatureStore ();
            history = new DocumentHistory ();
            IconTheme.get_for_display (Gdk.Display.get_default ()).add_resource_path ("/dev/sinty/reader/icons");
            var provider = new CssProvider ();
            provider.load_from_string (CSS);
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, STYLE_PROVIDER_PRIORITY_USER + 1);

            var menu = new GLib.Menu ();
            var file_menu = new GLib.Menu ();
            var f1 = new GLib.Menu ();
            f1.append (_("Open…"), "app.open");
            f1.append (_("Open from Online Account…"), "app.open-online");
            file_menu.append_section (null, f1);
            var f2 = new GLib.Menu ();
            f2.append (_("Save"), "win.save");
            f2.append (_("Save As…"), "win.save-as");
            f2.append (_("Save to Online Account…"), "win.save-online");
            f2.append (_("Print…"), "win.print");
            f2.append (_("Share…"), "win.share");
            file_menu.append_section (null, f2);
            var f3 = new GLib.Menu ();
            f3.append (_("Close Document"), "win.close-document");
            file_menu.append_section (null, f3);
            var f4 = new GLib.Menu ();
            f4.append (_("Close Window"), "win.close");
            f4.append (_("Quit"), "app.quit");
            file_menu.append_section (null, f4);
            menu.append_submenu (_("File"), file_menu);
            var edit_menu = new GLib.Menu ();
            var e1 = new GLib.Menu ();
            e1.append (_("Copy"), "win.copy");
            edit_menu.append_section (null, e1);
            var e2 = new GLib.Menu ();
            e2.append (_("Find"), "win.find");
            e2.append (_("Find Next"), "win.find-next");
            e2.append (_("Find Previous"), "win.find-previous");
            edit_menu.append_section (null, e2);
            var e3 = new GLib.Menu ();
            e3.append (_("Settings"), "app.settings");
            edit_menu.append_section (null, e3);
            menu.append_submenu (_("Edit"), edit_menu);
            var view_menu = new GLib.Menu ();
            var v1 = new GLib.Menu ();
            v1.append (_("Show Sidebar"), "win.sidebar");
            view_menu.append_section (null, v1);
            var v2 = new GLib.Menu ();
            v2.append (_("Zoom In"), "win.zoom-in");
            v2.append (_("Zoom Out"), "win.zoom-out");
            v2.append (_("Actual Size"), "win.zoom-reset");
            v2.append (_("Fit Width"), "win.zoom-fit");
            v2.append (_("Fit Page"), "win.zoom-page");
            view_menu.append_section (null, v2);
            menu.append_submenu (_("View"), view_menu);
            var go_menu = new GLib.Menu ();
            var g1 = new GLib.Menu ();
            g1.append (_("Previous Page"), "win.previous-page");
            g1.append (_("Next Page"), "win.next-page");
            go_menu.append_section (null, g1);
            var g2 = new GLib.Menu ();
            g2.append (_("First Page"), "win.first-page");
            g2.append (_("Last Page"), "win.last-page");
            g2.append (_("Go to Page…"), "win.go-to-page");
            go_menu.append_section (null, g2);
            menu.append_submenu (_("Go"), go_menu);
            var tools_menu = new GLib.Menu ();
            var t1 = new GLib.Menu ();
            t1.append (_("Select Text"), "win.tool-select");
            tools_menu.append_section (null, t1);
            var t2 = new GLib.Menu ();
            t2.append (_("Highlight"), "win.tool-highlight");
            t2.append (_("Underline"), "win.tool-underline");
            t2.append (_("Strikeout"), "win.tool-strikeout");
            t2.append (_("Squiggly"), "win.tool-squiggly");
            tools_menu.append_section (null, t2);
            var t3 = new GLib.Menu ();
            t3.append (_("Pen"), "win.tool-pen");
            t3.append (_("Highlighter Pen"), "win.tool-highlighter-pen");
            t3.append (_("Note"), "win.tool-note");
            t3.append (_("Text Box"), "win.tool-text");
            tools_menu.append_section (null, t3);
            var t4 = new GLib.Menu ();
            t4.append (_("Sign…"), "win.sign");
            tools_menu.append_section (null, t4);
            var t5 = new GLib.Menu ();
            t5.append (_("All Tools"), "win.tools");
            string[] ids = { "edit", "organize", "comment", "fill", "prepare", "sign", "redact", "protect", "ocr", "export", "optimize", "standards", "accessibility", "compare" };
            string[] labels = { _("Edit PDF"), _("Organize Pages"), _("Comment"), _("Fill and Sign"), _("Prepare Form"), _("Digital Signature"), _("Redact"), _("Protect"), _("Recognize Text"), _("Export and Create"), _("Optimize"), _("Standards and Preflight"), _("Accessibility"), _("Compare Files") };
            for (int i = 0; i < ids.length; i++) t5.append (labels[i], "app.tool::" + ids[i]);
            tools_menu.append_section (null, t5);
            menu.append_submenu (_("Tools"), tools_menu);
            set_menubar (menu);

            var open = new SimpleAction ("open", null);
            open.activate.connect (() => choose_file (get_active_window () as ReaderWindow));
            add_action (open);
            var open_online = new SimpleAction ("open-online", null);
            open_online.activate.connect (() => {
                var window = get_active_window () as ReaderWindow;
                if (window == null) {
                    window = new ReaderWindow (this);
                    window.present ();
                }
                CloudActions.open.begin (window, (f) => open_file (f, window));
            });
            add_action (open_online);
            var settings_action = new SimpleAction ("settings", null);
            settings_action.activate.connect (() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings ("dev.sinty.reader");
                } catch (Error e) {
                    warning ("Failed to open settings: %s", e.message);
                }
            });
            add_action (settings_action);
            var tool_action = new SimpleAction ("tool", VariantType.STRING);
            tool_action.activate.connect ((v) => {
                ReaderWindow? window = get_active_window () as ReaderWindow;
                if (window == null) {
                    foreach (var w in get_windows ()) {
                        if (w is ReaderWindow) {
                            window = (ReaderWindow) w;
                            break;
                        }
                    }
                }
                if (window != null) window.open_tool (v.get_string ());
            });
            add_action (tool_action);
            var quit_action = new SimpleAction ("quit", null);
            quit_action.activate.connect (() => {
                var windows = new Gee.ArrayList<Gtk.Window> ();
                foreach (var w in get_windows ()) windows.add (w);
                foreach (var w in windows) w.close ();
            });
            add_action (quit_action);

            set_accels_for_action ("app.open", { "<Control>o" });
            set_accels_for_action ("app.quit", { "<Control>q" });
            set_accels_for_action ("win.save", { "<Control>s" });
            set_accels_for_action ("win.save-as", { "<Control><Shift>s" });
            set_accels_for_action ("win.print", { "<Control>p" });
            set_accels_for_action ("win.copy", { "<Control>c" });
            set_accels_for_action ("win.find", { "<Control>f" });
            set_accels_for_action ("win.find-next", { "<Control>g", "F3" });
            set_accels_for_action ("win.find-previous", { "<Control><Shift>g", "<Shift>F3" });
            set_accels_for_action ("win.zoom-in", { "<Control>plus", "<Control>equal", "<Control>KP_Add" });
            set_accels_for_action ("win.zoom-out", { "<Control>minus", "<Control>KP_Subtract" });
            set_accels_for_action ("win.zoom-fit", { "<Control>0" });
            set_accels_for_action ("win.sidebar", { "F9" });
            set_accels_for_action ("win.close", { "<Control>w" });
            set_accels_for_action ("win.tool-select", { "<Alt>1" });
            set_accels_for_action ("win.tool-highlight", { "<Alt>2" });
            set_accels_for_action ("win.tool-note", { "<Alt>3" });
            set_accels_for_action ("win.tool-text", { "<Alt>4" });
            set_accels_for_action ("win.tool-pen", { "<Alt>5" });
            set_accels_for_action ("win.tools", { "<Control><Shift>t" });
        }

        public override void activate () {
            var window = get_active_window ();
            if (window == null) window = new ReaderWindow (this);
            window.present ();
        }

        public override void open (File[] files, string hint) {
            foreach (var file in files) open_file (file, null);
        }

        public void choose_file (ReaderWindow? parent) {
            var dialog = new FileDialog ();
            dialog.title = _("Open Document");
            var filter = new FileFilter ();
            filter.name = _("PDF Documents");
            filter.add_mime_type ("application/pdf");
            filter.add_suffix ("pdf");
            var filters = new GLib.ListStore (typeof (FileFilter));
            filters.append (filter);
            dialog.filters = filters;
            dialog.open.begin (parent, null, (obj, res) => {
                try {
                    var file = dialog.open.end (res);
                    if (file != null) open_file (file, parent);
                } catch (Error e) {
                }
            });
        }

        public void open_file (File file, ReaderWindow? preferred, string? password = null) {
            foreach (var w in get_windows ()) {
                var rw = w as ReaderWindow;
                if (rw != null && rw.document != null && rw.document.file.equal (file)) {
                    rw.present ();
                    return;
                }
            }
            ReaderDocument doc;
            try {
                doc = new ReaderDocument (file, password);
            } catch (Error e) {
                var target = preferred ?? (get_active_window () as ReaderWindow) ?? new ReaderWindow (this);
                target.present ();
                uint8[] raw = {};
                try {
                    FileUtils.get_data (file.get_path (), out raw);
                } catch (Error ignored) {
                }
                if (raw.length > 0 && CertEncryption.needs_certificate (raw)) {
                    ask_certificate (file, raw, target, null);
                } else if (e is Poppler.Error.ENCRYPTED) {
                    ask_password (file, target, password != null);
                } else {
                    var dlg = new ConfirmDialog.message (this, _("Cannot Open Document"), "dialog-error",
                        _("\"%s\" could not be opened: %s").printf (file.get_basename (), e.message), _("Close"));
                    dlg.transient_for = target;
                    dlg.present ();
                }
                return;
            }
            ReaderWindow? window = preferred;
            if (window == null || window.document != null) {
                window = get_active_window () as ReaderWindow;
                if (window == null || window.document != null) window = new ReaderWindow (this);
            }
            window.show_document (doc);
            window.present ();
        }

        private void ask_certificate (File file, uint8[] raw, ReaderWindow parent, string? problem) {
            string text = _("\"%s\" is encrypted for specific people. Choose your certificate file to open it.").printf (file.get_basename ());
            if (problem != null) text = problem;
            var dlg = new ConfirmDialog (this, _("Certificate Required"), "dialog-password", text,
                _("Open"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = parent;
            string? chosen = null;
            var pick = new Button.with_label (_("Choose Certificate…"));
            dlg.custom_area.append (pick);
            var entry = new PasswordEntry ();
            entry.show_peek_icon = true;
            entry.placeholder_text = _("Certificate password");
            dlg.custom_area.append (entry);
            pick.clicked.connect (() => {
                var fd = new FileDialog ();
                fd.title = _("Choose Certificate");
                var filter = new FileFilter ();
                filter.name = _("Certificates");
                filter.add_suffix ("p12");
                filter.add_suffix ("pfx");
                var filters = new GLib.ListStore (typeof (FileFilter));
                filters.append (filter);
                fd.filters = filters;
                fd.open.begin (dlg, null, (o, r) => {
                    try {
                        var f = fd.open.end (r);
                        if (f != null) {
                            chosen = f.get_path ();
                            pick.label = f.get_basename ();
                        }
                    } catch (Error err) {
                    }
                });
            });
            dlg.response.connect ((resp) => {
                if (resp != ConfirmDialog.Response.PRIMARY || chosen == null) return;
                CertEncryption.install_unlocker (chosen, entry.text);
                try {
                    var engine = Singularity.Pdf.Document.open_bytes (raw);
                    var opts = new Singularity.Pdf.SaveOptions ();
                    opts.remove_security = true;
                    var plain = engine.save (opts);
                    string name = file.get_basename () ?? "document.pdf";
                    if (name.down ().has_suffix (".pdf")) name = name.substring (0, name.length - 4);
                    var parent_dir = file.get_parent ();
                    var copy = parent_dir != null ? parent_dir.get_child (_("%s (decrypted).pdf").printf (name)) : File.new_for_path (_("%s (decrypted).pdf").printf (name));
                    var doc = new ReaderDocument.from_bytes (copy, plain);
                    parent.show_document (doc);
                    parent.present ();
                } catch (Error err) {
                    ask_certificate (file, raw, parent, err.message);
                }
            });
            dlg.present ();
        }

        private void ask_password (File file, ReaderWindow parent, bool retry) {
            var dlg = new ConfirmDialog (this, _("Password Required"), "dialog-password",
                retry ? _("The password was not correct. Try again.") : _("\"%s\" is protected with a password.").printf (file.get_basename ()),
                _("Unlock"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = parent;
            var entry = new PasswordEntry ();
            entry.show_peek_icon = true;
            dlg.custom_area.append (entry);
            entry.activate.connect (() => {
                dlg.close_dialog ();
                open_file (file, parent, entry.text);
            });
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) open_file (file, parent, entry.text);
            });
            dlg.present ();
            entry.grab_focus ();
        }

        private const string CSS = """
.reader-view {
    background-color: alpha(@window_fg_color, 0.06);
}

.reader-page {
    background-color: white;
    box-shadow: 0 1px 3px alpha(black, 0.18), 0 6px 18px alpha(black, 0.10);
}

.reader-thumbnail {
    background-color: white;
    box-shadow: 0 1px 3px alpha(black, 0.2);
}

.reader-thumbnails row:selected .reader-thumbnail {
    box-shadow: 0 0 0 3px @accent_bg_color;
}

.reader-thumbnails,
.reader-thumbnails row,
.reader-thumbnails row:selected,
.reader-thumbnails row:hover {
    background: transparent;
    color: inherit;
}

.reader-recent-list {
    border-radius: 10px;
    border: 1px solid alpha(@borders, 0.4);
}

.reader-recent-row {
    border-radius: 0;
    background-color: transparent;
    transition: background-color 0.1s ease;
}

.reader-recent-row:hover {
    background-color: alpha(@accent_color, 0.08);
}

.reader-recent-row + .reader-recent-row {
    border-top: 1px solid alpha(@borders, 0.3);
}

.reader-unsaved {
    color: @accent_color;
}

.reader-color-dot {
    min-width: 16px;
    min-height: 16px;
    border-radius: 999px;
    box-shadow: 0 0 0 2px alpha(white, 0.8), 0 0 0 3px alpha(black, 0.2);
}

.reader-swatch {
    min-width: 24px;
    min-height: 24px;
    padding: 0;
    border-radius: 999px;
    box-shadow: inset 0 0 0 1px alpha(black, 0.18);
}

.reader-swatch:checked {
    box-shadow: 0 0 0 2px @window_bg_color, 0 0 0 4px @accent_bg_color;
}

.reader-annotation-swatch {
    min-width: 10px;
    min-height: 10px;
    border-radius: 3px;
}

.reader-signature-frame {
    background-color: @window_bg_color;
    border-radius: 12px;
}

.sx-inspector {
    border-left: 1px solid alpha(@window_fg_color, 0.08);
}

.sx-inspector-header {
    margin: 0 14px 10px 14px;
}

.sx-inspector .preferences-row switch,
.sx-inspector .preferences-row spinbutton {
    margin-left: 12px;
}

.sx-inspector-footer {
    padding: 12px 14px 14px 14px;
    border-top: 1px solid alpha(@window_fg_color, 0.08);
}

.singularity .preferences-row.reader-mode-active,
.singularity .preferences-row.reader-mode-active:hover {
    background-color: alpha(@accent_color, 0.15);
}

.reader-mode-check {
    color: @accent_color;
}

.reader-signature-choice {
    background-color: white;
    border-radius: 8px;
    padding: 6px;
}
""";
    }
}
