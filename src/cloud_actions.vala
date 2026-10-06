using GLib;
using Singularity.Accounts;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public delegate void CloudFileFunc (GLib.File file);

    public class CloudActions : Object {
        private static string[] mime_types () {
            return { "application/pdf" };
        }

        public static async void open (Gtk.Window window, owned CloudFileFunc open_file) {
            var file = yield CloudFileDialog.open (window, mime_types ());
            if (file != null) open_file (file.local);
        }

        public static async void save (Singularity.Widgets.Window window, string name,
                                       owned CloudFileFunc write, owned CloudFileFunc adopt) {
            string dir;
            try {
                dir = DirUtils.make_tmp ("singularity-reader-XXXXXX");
            } catch (Error e) {
                window.add_toast (new Toast (e.message));
                return;
            }
            var source = GLib.File.new_for_path (Path.build_filename (dir, name));
            write (source);
            CloudFile? cloud = null;
            if (source.query_exists ()) cloud = yield CloudFileDialog.save (window, source, name);
            FileUtils.remove (source.get_path ());
            DirUtils.remove (dir);
            if (cloud == null) return;
            adopt (cloud.local);
            window.add_toast (new Toast (_("Saved to %s").printf (account_name (cloud.local))));
        }

        public static void save_document (ReaderWindow window) {
            var document = window.document;
            if (document == null) return;
            string name = document.file.get_basename () ?? "document.pdf";
            save.begin (window, name, (f) => {
                try {
                    for (int i = 0; i < document.n_pages; i++) {
                        var cr = new Cairo.Context (new Cairo.ImageSurface (Cairo.Format.ARGB32, 1, 1));
                        cr.scale (0.001, 0.001);
                        document.doc.get_page (i).render (cr);
                    }
                    if (!document.doc.save (f.get_uri ())) throw new IOError.FAILED (_("The document could not be written."));
                } catch (Error e) {
                    window.add_toast (new Toast (e.message));
                }
            }, (f) => {
                try {
                    document.save (f);
                    document.notify_property ("modified");
                } catch (Error e) {
                    window.add_toast (new Toast (e.message));
                }
            });
        }

        public static void sync_back (Singularity.Widgets.Window window, GLib.File file) {
            CloudFile.sync_back.begin (file, null, (obj, res) => {
                try {
                    if (CloudFile.sync_back.end (res))
                        window.add_toast (new Toast (_("Saved to %s").printf (account_name (file))));
                } catch (Error e) {
                    window.add_toast (new Toast (_("Not saved to %s: %s").printf (account_name (file), e.message)));
                }
            });
        }

        private static string account_name (GLib.File file) {
            var cloud = CloudFile.for_local (file);
            var account = cloud != null ? Manager.get_default ().get_account (cloud.account_id) : null;
            return account != null ? account.display_name : _("Online Account");
        }
    }
}
