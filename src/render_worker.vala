namespace Singularity.Apps.Reader {

    public class RenderJob {
        public int page;
        public double scale;
        public uint generation;
        public int width;
        public int height;
        public int stride;
        public uint8[]? pixels = null;
    }

    public class RenderWorker : Object {
        private AsyncQueue<RenderJob> queue = new AsyncQueue<RenderJob> ();
        private Thread<void*>? thread = null;
        private Poppler.Document? doc = null;
        private bool running = true;
        public uint generation = 1;

        public signal void rendered (RenderJob job);

        public RenderWorker (uint8[] data, string? password) throws Error {
            doc = new Poppler.Document.from_bytes (new Bytes (data), password);
            thread = new Thread<void*> ("reader-render", run);
        }

        public void request (int page, double scale) {
            var job = new RenderJob ();
            job.page = page;
            job.scale = scale;
            job.generation = generation;
            queue.push (job);
        }

        public void cancel_pending () {
            generation++;
        }

        public void stop () {
            running = false;
            generation++;
            var poison = new RenderJob ();
            poison.page = -1;
            queue.push (poison);
        }

        private void* run () {
            while (running) {
                var job = queue.pop ();
                if (job.page < 0 || !running) break;
                if (job.generation != generation) continue;
                var page = doc.get_page (job.page);
                if (page == null) continue;
                double w, h;
                page.get_size (out w, out h);
                int pw = int.max (1, (int) Math.ceil (w * job.scale));
                int ph = int.max (1, (int) Math.ceil (h * job.scale));
                double scale = job.scale;
                if ((int64) pw * ph > 60000000) {
                    double shrink = Math.sqrt (60000000.0 / ((double) pw * ph));
                    scale *= shrink;
                    pw = (int) (pw * shrink);
                    ph = (int) (ph * shrink);
                }
                var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, pw, ph);
                var cr = new Cairo.Context (surface);
                cr.set_source_rgb (1, 1, 1);
                cr.paint ();
                cr.scale (scale, scale);
                page.render (cr);
                surface.flush ();
                job.width = pw;
                job.height = ph;
                job.stride = surface.get_stride ();
                job.pixels = surface.get_data ()[0 : surface.get_stride () * ph];
                if (job.generation != generation) continue;
                Idle.add (() => {
                    rendered (job);
                    return Source.REMOVE;
                });
            }
            return null;
        }
    }
}
