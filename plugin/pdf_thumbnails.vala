using GLib;

[ModuleInit]
public void peas_register_types (TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type (typeof (Singularity.FilesPlugin), typeof (Singularity.Apps.Reader.PdfThumbnailsPlugin));
}

namespace Singularity.Apps.Reader {

    public class PdfThumbnailsPlugin : Object, Singularity.FilesPlugin {
        private Singularity.FilesPluginContext? context = null;
        private PdfIconProvider? provider = null;

        public void activate (Singularity.FilesPluginContext context) {
            this.context = context;
            provider = new PdfIconProvider ();
            context.add_file_icon_provider (provider);
        }

        public void deactivate () {
            if (context != null && provider != null) context.remove_file_icon_provider (provider);
            provider = null;
            context = null;
        }
    }

    public class PdfIconProvider : Object, Singularity.FileIconProvider {
        private const int MAX_SIZE = 512;

        private static ThreadPool<ThumbnailJob>? pool = null;
        private GLib.Settings? files_settings = null;

        construct {
            var source = SettingsSchemaSource.get_default ();
            if (source != null && source.lookup ("dev.sinty.files", true) != null)
                files_settings = new GLib.Settings ("dev.sinty.files");
        }

        public bool matches (File file, string? content_type) {
            if (content_type == null || file.get_path () == null) return false;
            if (files_settings != null && !files_settings.get_boolean ("show-previews")) return false;
            string mime = ContentType.get_mime_type (content_type) ?? content_type;
            return mime == "application/pdf" || mime == "application/x-pdf";
        }

        public async Gdk.Paintable? load_icon (File file, int size) {
            string? path = file.get_path ();
            if (path == null) return null;
            int pixels = int.min (MAX_SIZE, int.max (32, size * 2));
            int64 mtime = 0;
            try {
                var info = yield file.query_info_async (FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                mtime = info.get_modification_date_time ().to_unix ();
            } catch (Error e) {
                return null;
            }
            var job = new ThumbnailJob (file.get_uri (), path, pixels, mtime);
            SourceFunc callback = load_icon.callback;
            job.done.connect (() => callback ());
            try {
                if (pool == null) pool = new ThreadPool<ThumbnailJob>.with_owned_data ((j) => j.run (), 2, false);
                pool.add (job);
            } catch (ThreadError e) {
                return null;
            }
            yield;
            return job.texture;
        }
    }

    public class ThumbnailJob : Object {
        public string uri { get; construct; }
        public string path { get; construct; }
        public int pixels { get; construct; }
        public int64 mtime { get; construct; }
        public Gdk.Texture? texture = null;

        public signal void done ();

        public ThumbnailJob (string uri, string path, int pixels, int64 mtime) {
            Object (uri: uri, path: path, pixels: pixels, mtime: mtime);
        }

        public void run () {
            string cache = cache_path ();
            try {
                if (FileUtils.test (cache, FileTest.EXISTS)) {
                    texture = Gdk.Texture.from_filename (cache);
                } else {
                    texture = render (cache);
                }
            } catch (Error e) {
                texture = null;
            }
            Idle.add (() => {
                done ();
                return Source.REMOVE;
            });
        }

        private string cache_path () {
            string name = "%s-%lld-%d.png".printf (Checksum.compute_for_string (ChecksumType.MD5, uri), mtime, pixels);
            return Path.build_filename (Environment.get_user_cache_dir (), "singularity-reader", "thumbnails", name);
        }

        private Gdk.Texture? render (string cache) throws Error {
            uint8[] data;
            FileUtils.get_data (File.new_for_uri (uri).get_path (), out data);
            uint8[]? fixed_data = Singularity.Apps.Reader.HairlineFix.apply (data);
            var doc = new Poppler.Document.from_bytes (new Bytes (fixed_data ?? data), null);
            if (doc.get_n_pages () < 1) return null;
            var page = doc.get_page (0);
            double width, height;
            page.get_size (out width, out height);
            if (width <= 0 || height <= 0) return null;
            double scale = pixels / double.max (width, height);
            int w = int.max (1, (int) Math.round (width * scale));
            int h = int.max (1, (int) Math.round (height * scale));
            var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, w, h);
            var cr = new Cairo.Context (surface);
            cr.set_source_rgb (1, 1, 1);
            cr.paint ();
            cr.scale (scale, scale);
            page.render (cr);
            surface.flush ();
            DirUtils.create_with_parents (Path.get_dirname (cache), 0700);
            if (surface.write_to_png (cache) == Cairo.Status.SUCCESS)
                return Gdk.Texture.from_filename (cache);
            return null;
        }
    }
}
