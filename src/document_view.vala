using Gtk;

namespace Singularity.Apps.Reader {

    public enum Tool {
        SELECT,
        MARKUP,
        PEN,
        HIGHLIGHTER,
        NOTE,
        TEXT,
        SIGNATURE,
        AREA,
        POINT,
        POLYLINE
    }

    public enum ZoomMode {
        FIT_WIDTH,
        FIT_PAGE,
        CUSTOM
    }

    public class SearchHit : Object {
        public int page;
        public Poppler.Rectangle rect;

        public SearchHit (int page, Poppler.Rectangle rect) {
            this.page = page;
            this.rect = rect;
        }
    }

    public class DocumentView : Box {
        private const double MIN_ZOOM = 0.2;
        private const double MAX_ZOOM = 6.0;
        private const int GAP = 16;

        public ReaderDocument? document { get; private set; default = null; }
        public double zoom { get; private set; default = 1.0; }
        public ZoomMode zoom_mode { get; private set; default = ZoomMode.FIT_WIDTH; }
        public int current_page { get; private set; default = 0; }
        public Tool tool { get; set; default = Tool.SELECT; }
        public MarkupKind markup_kind { get; set; default = MarkupKind.HIGHLIGHT; }
        public Cairo.ImageSurface? signature { get; set; default = null; }
        public GLib.Settings settings;

        private ScrolledWindow scroll;
        private Box column;
        private PageWidget[] pages = {};
        private Gee.LinkedList<PageWidget> pending = new Gee.LinkedList<PageWidget> ();
        private RenderWorker? worker = null;
        private Gee.HashMap<string, Gdk.Texture> texture_cache = new Gee.HashMap<string, Gdk.Texture> ();
        private Gee.LinkedList<string> cache_order = new Gee.LinkedList<string> ();
        private Gee.HashSet<string> in_flight = new Gee.HashSet<string> ();
        private uint render_source = 0;
        private int selection_page = -1;
        private Poppler.Rectangle selection_rect;
        private Poppler.SelectionStyle selection_style = Poppler.SelectionStyle.GLYPH;
        private bool dragging = false;
        private bool drag_moved = false;
        private double drag_x;
        private double drag_y;
        private Gee.ArrayList<double?>? stroke = null;
        private int selected_page = -1;
        private Poppler.Annot? selected_annot = null;
        private Poppler.Rectangle selected_rect;
        private int stamp_mode = 0;
        private Poppler.Rectangle stamp_origin;
        private Gee.HashMap<string, Cairo.ImageSurface> stamp_images = new Gee.HashMap<string, Cairo.ImageSurface> ();

        private static string stamp_key (int page, Poppler.Rectangle area) {
            return "%d:%d:%d".printf (page, (int) Math.round (area.x1), (int) Math.round (area.y1));
        }

        private Cairo.ImageSurface? stamp_image (int page, Poppler.Rectangle area) {
            string key = stamp_key (page, area);
            return stamp_images.has_key (key) ? stamp_images[key] : null;
        }
        private Gee.ArrayList<SearchHit> hits = new Gee.ArrayList<SearchHit> ();
        private int hit_index = -1;
        private uint search_source = 0;
        private int pending_page = -1;
        private double restore_value = -1;
        private int pending_attempts = 0;
        private double pending_offset = 0;
        private double zoom_anchor_fraction = -1;
        private int zoom_anchor_page = 0;
        private int last_width = 0;
        private int last_height = 0;

        public signal void page_changed (int page);
        public signal void zoom_changed ();
        public signal void selection_changed (bool has_selection, int page, Poppler.Rectangle area);
        public signal void annotation_selected (int page, Poppler.Annot annot, Poppler.Rectangle area, Widget page_widget);
        public signal void note_requested (int page, double x, double y, Widget page_widget);
        public signal void text_requested (int page, Poppler.Rectangle area, Widget page_widget);
        public signal void search_updated (int count, int current);
        public signal void search_finished (Gee.List<SearchHit> results);
        public signal void link_activated (string uri);
        public signal void edited ();
        public signal void area_picked (int page, Poppler.Rectangle area, Widget page_widget);
        public signal void point_picked (int page, double x, double y, Widget page_widget);
        public signal void polyline_done (int page, double[] points, Widget page_widget);
        public signal void reloaded ();
        public signal void form_field_activated (int page, string name, Poppler.FormFieldType type, Poppler.Rectangle area, Widget page_widget);
        public string pick_cursor = "crosshair";
        public int poly_limit = 0;

        public DocumentView (GLib.Settings settings) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            this.settings = settings;
            add_css_class ("reader-view");
            scroll = new ScrolledWindow ();
            scroll.hexpand = true;
            scroll.vexpand = true;
            column = new Box (Orientation.VERTICAL, GAP);
            column.margin_top = GAP;
            column.margin_bottom = GAP * 3;
            column.margin_start = GAP;
            column.margin_end = GAP;
            column.halign = Align.CENTER;
            scroll.child = column;
            Singularity.Widgets.apply_titlebar_inset (column);
            append (scroll);
            scroll.vadjustment.value_changed.connect (on_scrolled);
            scroll.hadjustment.changed.connect (on_viewport_changed);
            scroll.vadjustment.changed.connect (on_viewport_changed);
            scroll.hadjustment.value_changed.connect (() => queue_visible ());

            var wheel = new EventControllerScroll (EventControllerScrollFlags.VERTICAL);
            wheel.propagation_phase = PropagationPhase.CAPTURE;
            wheel.scroll.connect ((dx, dy) => {
                var state = wheel.get_current_event_state ();
                if ((state & Gdk.ModifierType.CONTROL_MASK) == 0) return false;
                zoom_to (zoom * (dy < 0 ? 1.1 : 1 / 1.1));
                return true;
            });
            scroll.add_controller (wheel);

            var pinch = new GestureZoom ();
            double pinch_start = 1;
            pinch.begin.connect (() => pinch_start = zoom);
            pinch.scale_changed.connect ((s) => zoom_to (pinch_start * s));
            scroll.add_controller (pinch);
        }

        public PageWidget? page_widget (int index) {
            return index >= 0 && index < pages.length ? pages[index] : null;
        }

        private void restart_worker () {
            if (worker != null) worker.stop ();
            worker = null;
            texture_cache.clear ();
            cache_order.clear ();
            in_flight.clear ();
            if (document == null) return;
            try {
                worker = new RenderWorker (document.render_source_bytes (), document.password);
                worker.rendered.connect (on_rendered);
            } catch (Error e) {
                worker = null;
            }
        }

        private string cache_key (int page, double z) {
            return "%d:%d".printf (page, (int) Math.round (z * 1000));
        }

        private void remember_texture (string key, Gdk.Texture texture) {
            if (!texture_cache.has_key (key)) cache_order.add (key);
            texture_cache[key] = texture;
            while (cache_order.size > 48) texture_cache.unset (cache_order.poll_head ());
        }

        private void on_rendered (RenderJob job) {
            if (document == null || job.pixels == null) return;
            int factor = int.max (1, get_scale_factor ());
            double z = job.scale / factor;
            string key = cache_key (job.page, z);
            in_flight.remove (key);
            var texture = new Gdk.MemoryTexture (job.width, job.height, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, new Bytes (job.pixels), job.stride);
            remember_texture (key, texture);
            if (job.page >= pages.length || document.is_touched (job.page)) return;
            if ((z - zoom).abs () > 0.0005) return;
            var pw = pages[job.page];
            pw.texture = texture;
            pw.texture_zoom = zoom;
            pw.queue_draw ();
        }

        public void unload () {
            if (worker != null) worker.stop ();
            worker = null;
            texture_cache.clear ();
            cache_order.clear ();
            clear_selection ();
            deselect_annotation ();
            hits.clear ();
            hit_index = -1;
            Widget? child;
            while ((child = column.get_first_child ()) != null) column.remove (child);
            pending.clear ();
            pages = new PageWidget[0];
            document = null;
        }

        public void load (ReaderDocument doc, int page = 0) {
            clear_selection ();
            deselect_annotation ();
            hits.clear ();
            hit_index = -1;
            Widget? child;
            while ((child = column.get_first_child ()) != null) column.remove (child);
            pending.clear ();
            document = doc;
            pages = new PageWidget[doc.n_pages];
            for (int i = 0; i < doc.n_pages; i++) {
                var pw = new PageWidget (this, i);
                attach_input (pw);
                pages[i] = pw;
                column.append (pw);
            }
            doc.page_changed.connect ((index) => {
                if (index >= 0 && index < pages.length) pages[index].invalidate ();
                edited ();
            });
            doc.saved.connect (() => {
                if (document == doc) restart_worker ();
            });
            doc.reloaded.connect (() => {
                if (document != doc) return;
                bool settling = pending_page >= 0 && restore_value >= 0;
                int keep = settling ? pending_page : current_page;
                double offset = settling ? restore_value : scroll.vadjustment.value;
                var mode = zoom_mode;
                double z = zoom;
                int count = pages.length;
                load (doc, keep.clamp (0, doc.n_pages - 1));
                if (count == doc.n_pages) {
                    if (mode == ZoomMode.CUSTOM) change_zoom (z, mode);
                    else if (mode == ZoomMode.FIT_PAGE) fit_page ();
                    restore_value = offset;
                }
                reloaded ();
                edited ();
            });
            restart_worker ();
            zoom_mode = ZoomMode.FIT_WIDTH;
            apply_fit ();
            go_to (page.clamp (0, doc.n_pages - 1));
        }

        private void on_viewport_changed () {
            int width = (int) scroll.hadjustment.page_size;
            int height = (int) scroll.vadjustment.page_size;
            if (width == last_width && height == last_height) return;
            last_width = width;
            last_height = height;
            if (zoom_mode != ZoomMode.CUSTOM) apply_fit ();
        }

        private void apply_fit () {
            if (document == null || document.n_pages == 0) return;
            int width = (int) scroll.hadjustment.page_size;
            int height = (int) scroll.vadjustment.page_size;
            if (width <= 1) return;
            int available_w = int.max (100, width - GAP * 2 - 14);
            int available_h = int.max (100, height - GAP * 2);
            double widest = 0, tallest = 0;
            for (int i = 0; i < document.n_pages; i++) {
                widest = double.max (widest, document.width (i));
                tallest = double.max (tallest, document.height (i));
            }
            double z = available_w / widest;
            if (zoom_mode == ZoomMode.FIT_PAGE) z = double.min (z, available_h / document.height (current_page));
            change_zoom (z, zoom_mode);
        }

        public void fit_width () {
            zoom_mode = ZoomMode.FIT_WIDTH;
            apply_fit ();
        }

        public void fit_page () {
            zoom_mode = ZoomMode.FIT_PAGE;
            apply_fit ();
        }

        public void zoom_to (double value) {
            change_zoom (value, ZoomMode.CUSTOM);
        }

        private void change_zoom (double value, ZoomMode mode) {
            double z = value.clamp (MIN_ZOOM, MAX_ZOOM);
            zoom_mode = mode;
            if ((z - zoom).abs () < 0.001) {
                zoom_changed ();
                return;
            }
            remember_anchor ();
            zoom = z;
            foreach (var pw in pages) pw.queue_resize ();
            zoom_changed ();
            Idle.add (() => {
                restore_anchor ();
                queue_visible ();
                return Source.REMOVE;
            });
        }

        private void remember_anchor () {
            if (pages.length == 0 || pending_page >= 0) {
                zoom_anchor_fraction = -1;
                return;
            }
            zoom_anchor_page = current_page;
            Graphene.Rect b;
            if (pages[current_page].compute_bounds (column, out b) && b.size.height > 0) {
                double view_top = scroll.vadjustment.value - column.margin_top;
                zoom_anchor_fraction = (view_top - b.origin.y) / b.size.height;
            } else {
                zoom_anchor_fraction = 0;
            }
        }

        private void restore_anchor () {
            if (zoom_anchor_fraction < -0.5 || pages.length == 0 || pending_page >= 0) return;
            Graphene.Rect b;
            if (pages[zoom_anchor_page].compute_bounds (column, out b)) {
                scroll.vadjustment.value = b.origin.y + column.margin_top + zoom_anchor_fraction * b.size.height;
            }
            zoom_anchor_fraction = -1;
        }

        public void go_to (int index, double y_pt = -1) {
            if (document == null || pages.length == 0) return;
            pending_page = index.clamp (0, pages.length - 1);
            pending_offset = y_pt;
            Idle.add (() => {
                apply_pending_scroll ();
                return Source.REMOVE;
            });
        }

        private void apply_pending_scroll () {
            if (pending_page < 0) return;
            Graphene.Rect b;
            if (!pages[pending_page].compute_bounds (column, out b)) {
                Timeout.add (30, () => {
                    apply_pending_scroll ();
                    return Source.REMOVE;
                });
                return;
            }
            double target = b.origin.y + column.margin_top - GAP / 2;
            if (pending_offset >= 0) target += pending_offset * zoom - scroll.vadjustment.page_size * 0.25;
            double limit = scroll.vadjustment.upper - scroll.vadjustment.page_size;
            if (target > limit + 1 && pending_attempts++ < 40) {
                Timeout.add (25, () => {
                    apply_pending_scroll ();
                    return Source.REMOVE;
                });
                return;
            }
            pending_attempts = 0;
            if (restore_value >= 0) {
                target = restore_value;
                restore_value = -1;
            }
            scroll.vadjustment.value = target.clamp (0, limit);
            current_page = pending_page;
            pending_page = -1;
            page_changed (current_page);
            queue_visible ();
        }

        private void on_scrolled () {
            if (pages.length == 0) return;
            double probe = scroll.vadjustment.value + scroll.vadjustment.page_size * 0.3;
            int best = current_page;
            for (int i = 0; i < pages.length; i++) {
                Graphene.Rect b;
                if (!pages[i].compute_bounds (column, out b)) continue;
                double top = b.origin.y + column.margin_top;
                if (probe >= top - GAP && probe <= top + b.size.height) {
                    best = i;
                    break;
                }
            }
            if (best != current_page && pending_page < 0) {
                current_page = best;
                page_changed (best);
            }
            queue_visible ();
        }

        private bool is_near_view (PageWidget pw, double margin_screens) {
            Graphene.Rect b;
            if (!pw.compute_bounds (column, out b)) return false;
            double top = b.origin.y + column.margin_top;
            double view_top = scroll.vadjustment.value;
            double view_h = scroll.vadjustment.page_size;
            return top + b.size.height >= view_top - view_h * margin_screens && top <= view_top + view_h * (1 + margin_screens);
        }

        private void queue_visible () {
            foreach (var pw in pages) {
                if (is_near_view (pw, 0.5)) {
                    if (pw.texture == null || pw.texture_zoom != zoom) request_render (pw);
                } else if (pw.texture != null && !is_near_view (pw, 3)) {
                    pw.texture = null;
                    pw.texture_zoom = 0;
                }
            }
        }

        public void request_render (PageWidget pw) {
            if (!pending.contains (pw)) pending.add (pw);
            if (render_source == 0) render_source = Idle.add_full (Priority.DEFAULT_IDLE, render_next);
        }

        private bool render_next () {
            while (pending.size > 0) {
                var pw = pending.poll_head ();
                if (document == null || !is_near_view (pw, 0.6)) continue;
                if (pw.texture != null && pw.texture_zoom == zoom) continue;
                render_page (pw);
                return Source.CONTINUE;
            }
            render_source = 0;
            return Source.REMOVE;
        }

        private void render_page (PageWidget pw) {
            int factor = int.max (1, get_scale_factor ());
            string key = cache_key (pw.index, zoom);
            if (!document.is_touched (pw.index)) {
                if (texture_cache.has_key (key)) {
                    pw.texture = texture_cache[key];
                    pw.texture_zoom = zoom;
                    pw.queue_draw ();
                    return;
                }
                if (worker != null) {
                    if (!in_flight.contains (key)) {
                        in_flight.add (key);
                        worker.request (pw.index, zoom * factor);
                    }
                    return;
                }
            }
            double scale = zoom * factor;
            int w = int.max (1, (int) Math.ceil (document.width (pw.index) * scale));
            int h = int.max (1, (int) Math.ceil (document.height (pw.index) * scale));
            if ((int64) w * h > 60000000) {
                double shrink = Math.sqrt (60000000.0 / ((double) w * h));
                scale *= shrink;
                w = (int) (w * shrink);
                h = (int) (h * shrink);
            }
            var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, w, h);
            var cr = new Cairo.Context (surface);
            cr.set_source_rgb (1, 1, 1);
            cr.paint ();
            cr.scale (scale, scale);
            document.render_page (pw.index, cr);
            surface.flush ();
            var bytes = new Bytes (surface.get_data ()[0 : surface.get_stride () * h]);
            pw.texture = new Gdk.MemoryTexture (w, h, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, bytes, surface.get_stride ());
            pw.texture_zoom = zoom;
            pw.queue_draw ();
        }

        public void refresh_page (int index) {
            var pw = page_widget (index);
            if (pw != null) pw.invalidate ();
        }

        public void use_main_thread () {
            if (worker != null) worker.stop ();
            worker = null;
            refresh_all ();
        }

        public void refresh_all () {
            texture_cache.clear ();
            cache_order.clear ();
            in_flight.clear ();
            if (worker != null) worker.cancel_pending ();
            foreach (var pw in pages) pw.invalidate ();
        }

        private Poppler.Rectangle point_rect (double x, double y) {
            return Geometry.rect (x, y, x, y);
        }

        private Poppler.Annot? annotation_at (int index, double x, double y, out Poppler.Rectangle area) {
            area = Geometry.rect (0, 0, 0, 0);
            Poppler.Annot? found = null;
            foreach (var mapping in document.annotations (index)) {
                var r = mapping.area;
                var t = mapping.annot.get_annot_type ();
                if (t == Poppler.AnnotType.TEXT) {
                    r = Geometry.rect (r.x1, r.y1, r.x1 + 24, r.y1 + 24);
                }
                if (Geometry.contains (r, x, y)) {
                    found = mapping.annot;
                    area = r;
                }
            }
            return found;
        }

        private Poppler.LinkMapping? link_at (int index, double x, double y) {
            double h = document.height (index);
            foreach (var mapping in document.page (index).get_link_mapping ()) {
                var r = Geometry.to_view (mapping.area, h);
                if (Geometry.contains (r, x, y)) return mapping.copy ();
            }
            return null;
        }

        private bool text_at (int index, double x, double y) {
            var region = document.page (index).get_selected_region (1.0, Poppler.SelectionStyle.WORD, point_rect (x, y));
            return region != null && !region.is_empty ();
        }

        private static bool from_popup (EventController controller, Widget widget) {
            var ev = controller.get_current_event ();
            var native = widget.get_native ();
            if (ev == null || native == null) return false;
            return ev.get_surface () != native.get_surface ();
        }

        private void attach_input (PageWidget pw) {
            var drag = new GestureDrag ();
            drag.button = Gdk.BUTTON_PRIMARY;
            drag.drag_begin.connect ((x, y) => {
                if (from_popup (drag, pw)) {
                    drag.set_state (EventSequenceState.DENIED);
                    return;
                }
                on_drag_begin (pw, x / zoom, y / zoom);
            });
            drag.drag_update.connect ((dx, dy) => {
                double sx, sy;
                drag.get_start_point (out sx, out sy);
                on_drag_update (pw, (sx + dx) / zoom, (sy + dy) / zoom);
            });
            drag.drag_end.connect ((dx, dy) => {
                double sx, sy;
                drag.get_start_point (out sx, out sy);
                on_drag_end (pw, (sx + dx) / zoom, (sy + dy) / zoom);
            });
            pw.add_controller (drag);

            var click = new GestureClick ();
            click.button = Gdk.BUTTON_PRIMARY;
            click.pressed.connect ((n, x, y) => {
                if (from_popup (click, pw)) {
                    click.set_state (EventSequenceState.DENIED);
                    return;
                }
                if (tool == Tool.POLYLINE && n == 2) {
                    finish_polyline ();
                    return;
                }
                if (tool == Tool.SELECT && (n == 2 || n == 3)) {
                    selection_style = n == 2 ? Poppler.SelectionStyle.WORD : Poppler.SelectionStyle.LINE;
                    select_area (pw, point_rect (x / zoom, y / zoom));
                    emit_selection ();
                }
            });
            click.released.connect ((n, x, y) => {
                if (from_popup (click, pw)) return;
                if (n == 1 && !drag_moved) on_click (pw, x / zoom, y / zoom);
            });
            pw.add_controller (click);

            var motion = new EventControllerMotion ();
            motion.motion.connect ((x, y) => {
                if (from_popup (motion, pw)) return;
                update_cursor (pw, x / zoom, y / zoom);
            });
            pw.add_controller (motion);
        }

        private void update_cursor (PageWidget pw, double x, double y) {
            if (document == null) return;
            string name = "default";
            switch (tool) {
                case Tool.PEN:
                case Tool.HIGHLIGHTER:
                    name = "crosshair";
                    break;
                case Tool.NOTE:
                case Tool.SIGNATURE:
                    name = "copy";
                    break;
                case Tool.TEXT:
                    name = "cell";
                    break;
                case Tool.AREA:
                case Tool.POINT:
                case Tool.POLYLINE:
                    name = pick_cursor;
                    break;
                default:
                    Poppler.Rectangle area;
                    if (selected_annot != null && selected_page == pw.index && selected_annot is Poppler.AnnotStamp
                            && Geometry.contains (Geometry.rect (selected_rect.x1 - 8 / zoom, selected_rect.y1 - 8 / zoom,
                                selected_rect.x2 + 8 / zoom, selected_rect.y2 + 8 / zoom), x, y)) {
                        name = corner_at (x, y) >= 0 ? "nwse-resize" : "move";
                    } else if (link_at (pw.index, x, y) != null || annotation_at (pw.index, x, y, out area) != null) {
                        name = "pointer";
                    } else if (text_at (pw.index, x, y)) {
                        name = "text";
                    }
                    break;
            }
            pw.set_cursor_from_name (name);
        }

        private int corner_at (double x, double y) {
            double tolerance = 10 / zoom;
            double[] cx = { selected_rect.x1, selected_rect.x2, selected_rect.x1, selected_rect.x2 };
            double[] cy = { selected_rect.y1, selected_rect.y1, selected_rect.y2, selected_rect.y2 };
            for (int i = 0; i < 4; i++) {
                if ((x - cx[i]).abs () <= tolerance && (y - cy[i]).abs () <= tolerance) return i;
            }
            return -1;
        }

        private void on_drag_begin (PageWidget pw, double x, double y) {
            dragging = true;
            drag_moved = false;
            drag_x = x;
            drag_y = y;
            stamp_mode = 0;
            switch (tool) {
                case Tool.SELECT:
                    if (selected_annot is Poppler.AnnotStamp && selected_page == pw.index && stamp_image (pw.index, selected_rect) != null) {
                        int corner = corner_at (x, y);
                        if (corner >= 0) {
                            stamp_mode = 2 + corner;
                            stamp_origin = selected_rect;
                            return;
                        }
                        if (Geometry.contains (selected_rect, x, y)) {
                            stamp_mode = 1;
                            stamp_origin = selected_rect;
                            return;
                        }
                    }
                    break;
                case Tool.PEN:
                case Tool.HIGHLIGHTER:
                    stroke = new Gee.ArrayList<double?> ();
                    stroke.add (x);
                    stroke.add (y);
                    pw.strokes.clear ();
                    pw.strokes.add (stroke);
                    bool marker = tool == Tool.HIGHLIGHTER;
                    pw.stroke_color = marker ? settings.get_string ("highlight-color") : settings.get_string ("pen-color");
                    pw.stroke_width = marker ? 12 : settings.get_double ("pen-width");
                    pw.stroke_alpha = marker ? settings.get_double ("highlight-opacity") : 1;
                    break;
                default:
                    break;
            }
        }

        private void on_drag_update (PageWidget pw, double x, double y) {
            if (!dragging || document == null) return;
            if (!drag_moved && ((x - drag_x) * zoom).abs () < 3 && ((y - drag_y) * zoom).abs () < 3) return;
            drag_moved = true;
            double w = document.width (pw.index), h = document.height (pw.index);
            x = x.clamp (0, w);
            y = y.clamp (0, h);
            if (stamp_mode == 1) {
                double dx = x - drag_x, dy = y - drag_y;
                double rw = stamp_origin.x2 - stamp_origin.x1, rh = stamp_origin.y2 - stamp_origin.y1;
                double nx = (stamp_origin.x1 + dx).clamp (0, w - rw), ny = (stamp_origin.y1 + dy).clamp (0, h - rh);
                selected_rect = Geometry.rect (nx, ny, nx + rw, ny + rh);
                pw.outline = selected_rect;
                pw.queue_draw ();
                return;
            }
            if (stamp_mode >= 2) {
                int corner = stamp_mode - 2;
                double ax = corner == 0 || corner == 2 ? stamp_origin.x2 : stamp_origin.x1;
                double ay = corner == 0 || corner == 1 ? stamp_origin.y2 : stamp_origin.y1;
                double ratio = (stamp_origin.y2 - stamp_origin.y1) / double.max (1, stamp_origin.x2 - stamp_origin.x1);
                double nw = double.max (24, (x - ax).abs ());
                double nh = nw * ratio;
                double nx = x < ax ? ax - nw : ax, ny = y < ay ? ay - nh : ay;
                selected_rect = Geometry.rect (nx, ny, nx + nw, ny + nh);
                pw.outline = selected_rect;
                pw.queue_draw ();
                return;
            }
            switch (tool) {
                case Tool.SELECT:
                case Tool.MARKUP:
                    selection_style = Poppler.SelectionStyle.GLYPH;
                    select_area (pw, Geometry.rect (drag_x, drag_y, x, y), drag_x, drag_y, x, y);
                    break;
                case Tool.PEN:
                case Tool.HIGHLIGHTER:
                    if (stroke != null) {
                        stroke.add (x);
                        stroke.add (y);
                        pw.queue_draw ();
                    }
                    break;
                case Tool.TEXT:
                case Tool.AREA:
                    pw.ghost = Geometry.rect (drag_x, drag_y, x, y);
                    pw.queue_draw ();
                    break;
                default:
                    break;
            }
        }

        private void on_drag_end (PageWidget pw, double x, double y) {
            if (!dragging || document == null) return;
            dragging = false;
            if (stamp_mode > 0) {
                var image = stamp_image (pw.index, stamp_origin);
                if (drag_moved && selected_annot is Poppler.AnnotStamp && image != null) {
                    try {
                        Annotations.move_stamp (document, pw.index, (Poppler.AnnotStamp) selected_annot, image, selected_rect);
                        stamp_images.unset (stamp_key (pw.index, stamp_origin));
                        stamp_images[stamp_key (pw.index, selected_rect)] = image;
                    } catch (Error e) {
                        warning ("Cannot move signature: %s", e.message);
                    }
                }
                stamp_mode = 0;
                return;
            }
            if (!drag_moved) {
                if (tool == Tool.PEN || tool == Tool.HIGHLIGHTER) pw.strokes.clear ();
                return;
            }
            switch (tool) {
                case Tool.MARKUP:
                    commit_markup ();
                    break;
                case Tool.SELECT:
                    emit_selection ();
                    break;
                case Tool.PEN:
                case Tool.HIGHLIGHTER:
                    commit_stroke (pw);
                    break;
                case Tool.TEXT:
                    var area = pw.ghost ?? Geometry.rect (drag_x, drag_y, drag_x + 220, drag_y + 40);
                    if (area.x2 - area.x1 < 40 || area.y2 - area.y1 < 16) {
                        area = Geometry.rect (area.x1, area.y1, area.x1 + 220, area.y1 + 40);
                    }
                    text_requested (pw.index, area, pw);
                    break;
                case Tool.AREA:
                    var picked = pw.ghost ?? Geometry.rect (drag_x, drag_y, x, y);
                    pw.ghost = null;
                    pw.queue_draw ();
                    if (picked.x2 - picked.x1 >= 3 && picked.y2 - picked.y1 >= 3) {
                        int picked_page = pw.index;
                        Idle.add (() => {
                            if (picked_page < pages.length) area_picked (picked_page, picked, pages[picked_page]);
                            return Source.REMOVE;
                        });
                    }
                    break;
                default:
                    break;
            }
        }

        private void commit_stroke (PageWidget pw) {
            if (stroke == null || stroke.size < 4) {
                pw.strokes.clear ();
                pw.queue_draw ();
                return;
            }
            var strokes = new Gee.ArrayList<Gee.List<double?>> ();
            strokes.add (simplify (stroke));
            bool marker = tool == Tool.HIGHLIGHTER;
            Annotations.ink (document, pw.index, strokes, pw.stroke_color, pw.stroke_width,
                marker ? settings.get_double ("highlight-opacity") : 1, marker, settings.get_string ("author"));
            stroke = null;
            pw.strokes.clear ();
        }

        private Gee.ArrayList<double?> simplify (Gee.List<double?> points) {
            var result = new Gee.ArrayList<double?> ();
            double min_step = 0.6;
            for (int i = 0; i + 1 < points.size; i += 2) {
                if (result.size >= 2) {
                    double px = result[result.size - 2], py = result[result.size - 1];
                    double dx = points[i] - px, dy = points[i + 1] - py;
                    if (Math.sqrt (dx * dx + dy * dy) < min_step && i + 2 < points.size) continue;
                }
                result.add (points[i]);
                result.add (points[i + 1]);
            }
            return result;
        }

        private void select_area (PageWidget pw, Poppler.Rectangle area, double ax = -1, double ay = -1, double bx = -1, double by = -1) {
            if (selection_page >= 0 && selection_page != pw.index) clear_selection ();
            selection_page = pw.index;
            var rect = Poppler.Rectangle ();
            if (ax >= 0) {
                rect.x1 = ax; rect.y1 = ay; rect.x2 = bx; rect.y2 = by;
            } else {
                rect = area;
            }
            selection_rect = rect;
            const double SCALE = 2.0;
            pw.selection = document.page (pw.index).get_selected_region (SCALE, selection_style, rect);
            pw.selection_scale = SCALE;
            pw.queue_draw ();
        }

        private void emit_selection () {
            bool has = selection_page >= 0 && pages[selection_page].selection != null && !pages[selection_page].selection.is_empty ();
            if (!has) {
                clear_selection ();
                selection_changed (false, -1, Geometry.rect (0, 0, 0, 0));
                return;
            }
            var extents = pages[selection_page].selection.get_extents ();
            double k = 1.0 / pages[selection_page].selection_scale;
            selection_changed (true, selection_page, Geometry.rect (extents.x * k, extents.y * k,
                (extents.x + extents.width) * k, (extents.y + extents.height) * k));
        }

        public void clear_selection () {
            if (selection_page >= 0 && selection_page < pages.length) {
                pages[selection_page].selection = null;
                pages[selection_page].queue_draw ();
            }
            selection_page = -1;
        }

        public bool has_selection () {
            return selection_page >= 0 && pages[selection_page].selection != null;
        }

        public string selection_text () {
            if (!has_selection ()) return "";
            return Annotations.selected_text (document, selection_page, selection_rect, selection_style);
        }

        public void markup_selection (MarkupKind kind) {
            if (!has_selection ()) return;
            var line_starts = new Gee.ArrayList<int> ();
            var glyphs = Annotations.selected_glyphs (document, selection_page, selection_rect, selection_style, line_starts);
            string color = kind == MarkupKind.HIGHLIGHT ? settings.get_string ("highlight-color") : settings.get_string ("markup-color");
            Annotations.markup (document, selection_page, glyphs, kind, color, settings.get_double ("highlight-opacity"),
                settings.get_string ("author"), line_starts);
            clear_selection ();
        }

        private void commit_markup () {
            markup_selection (markup_kind);
        }

        private void on_click (PageWidget pw, double x, double y) {
            if (document == null) return;
            switch (tool) {
                case Tool.NOTE:
                    note_requested (pw.index, x, y, pw);
                    return;
                case Tool.SIGNATURE:
                    place_signature (pw, x, y);
                    return;
                case Tool.POINT:
                    int point_page = pw.index;
                    Idle.add (() => {
                        if (point_page < pages.length) point_picked (point_page, x, y, pages[point_page]);
                        return Source.REMOVE;
                    });
                    return;
                case Tool.POLYLINE:
                    if (poly_page >= 0 && poly_page != pw.index) finish_polyline ();
                    poly_page = pw.index;
                    pw.poly.add (x);
                    pw.poly.add (y);
                    pw.queue_draw ();
                    if (poly_limit > 0 && pw.poly.size >= poly_limit * 2) finish_polyline ();
                    return;
                case Tool.AREA:
                    return;
                case Tool.PEN:
                case Tool.HIGHLIGHTER:
                case Tool.TEXT:
                    if (tool == Tool.TEXT) text_requested (pw.index, Geometry.rect (x, y, x + 220, y + 40), pw);
                    return;
                default:
                    break;
            }
            clear_selection ();
            selection_changed (false, -1, Geometry.rect (0, 0, 0, 0));
            Poppler.Rectangle area;
            var annot = annotation_at (pw.index, x, y, out area);
            if (annot != null) {
                select_annotation (pw.index, annot, area);
                return;
            }
            deselect_annotation ();
            double h = document.height (pw.index);
            foreach (var mapping in document.page (pw.index).get_form_field_mapping ()) {
                var r = Geometry.to_view (mapping.area, h);
                if (!Geometry.contains (r, x, y)) continue;
                var field = mapping.field;
                if (field.is_read_only ()) break;
                var type = field.get_field_type ();
                if (type == Poppler.FormFieldType.TEXT || type == Poppler.FormFieldType.CHOICE || type == Poppler.FormFieldType.BUTTON) {
                    string? fname = field.get_name ();
                    string field_name = fname != null ? fname : "";
                    int field_page = pw.index;
                    Idle.add (() => {
                        if (field_page < pages.length) form_field_activated (field_page, field_name, type, r, pages[field_page]);
                        return Source.REMOVE;
                    });
                    return;
                }
            }
            var link = link_at (pw.index, x, y);
            if (link != null) follow (link.action);
        }

        public void select_annotation (int index, Poppler.Annot annot, Poppler.Rectangle area) {
            deselect_annotation ();
            selected_page = index;
            selected_annot = annot;
            selected_rect = area;
            var pw = pages[index];
            pw.outline = area;
            pw.outline_handles = annot is Poppler.AnnotStamp && stamp_image (index, area) != null;
            pw.queue_draw ();
            annotation_selected (index, annot, area, pw);
        }

        public void deselect_annotation () {
            if (selected_page >= 0 && selected_page < pages.length) {
                pages[selected_page].outline = null;
                pages[selected_page].queue_draw ();
            }
            selected_page = -1;
            selected_annot = null;
        }

        public void clear_ghost (int index) {
            var pw = page_widget (index);
            if (pw == null) return;
            pw.ghost = null;
            pw.queue_draw ();
        }

        private void place_signature (PageWidget pw, double x, double y) {
            if (signature == null) return;
            double width = settings.get_double ("signature-width");
            double height = width * signature.get_height () / double.max (1, signature.get_width ());
            double pw_w = document.width (pw.index), pw_h = document.height (pw.index);
            if (width > pw_w * 0.9) {
                width = pw_w * 0.9;
                height = width * signature.get_height () / double.max (1, signature.get_width ());
            }
            double x1 = (x - width / 2).clamp (0, pw_w - width), y1 = (y - height / 2).clamp (0, pw_h - height);
            var rect = Geometry.rect (x1, y1, x1 + width, y1 + height);
            try {
                var annot = Annotations.stamp (document, pw.index, rect, signature, settings.get_string ("author"));
                stamp_images[stamp_key (pw.index, rect)] = signature;
                tool = Tool.SELECT;
                Idle.add (() => {
                    select_annotation (pw.index, annot, rect);
                    return Source.REMOVE;
                });
            } catch (Error e) {
                warning ("Cannot place signature: %s", e.message);
            }
        }

        private int poly_page = -1;

        public void finish_polyline () {
            if (poly_page < 0 || poly_page >= pages.length) return;
            var pw = pages[poly_page];
            double[] pts = {};
            foreach (var v in pw.poly) pts += v;
            pw.poly.clear ();
            pw.queue_draw ();
            int page = poly_page;
            poly_page = -1;
            if (pts.length >= 4) {
                Idle.add (() => {
                    if (page < pages.length) polyline_done (page, pts, pages[page]);
                    return Source.REMOVE;
                });
            }
        }

        public void cancel_polyline () {
            if (poly_page >= 0 && poly_page < pages.length) {
                pages[poly_page].poly.clear ();
                pages[poly_page].queue_draw ();
            }
            poly_page = -1;
        }

        public void clear_overlays () {
            foreach (var pw in pages) {
                if (pw.overlays.size == 0) continue;
                pw.overlays.clear ();
                pw.queue_draw ();
            }
        }

        public void add_overlay (int page, Poppler.Rectangle area, string color, bool filled, string label = "") {
            var pw = page_widget (page);
            if (pw == null) return;
            pw.overlays.add (new PageOverlay (area, color, filled, label));
            pw.queue_draw ();
        }

        public bool annotation_movable (int page, Poppler.Rectangle area) {
            return stamp_image (page, area) != null;
        }

        public void follow (Poppler.Action action) {
            switch (action.type) {
                case Poppler.ActionType.GOTO_DEST:
                    go_to_dest (action.goto_dest.dest);
                    break;
                case Poppler.ActionType.URI:
                    if (action.uri.uri != null) link_activated (action.uri.uri);
                    break;
                case Poppler.ActionType.NAMED:
                    string name = action.named.named_dest ?? "";
                    if (name == "NextPage") go_to (current_page + 1);
                    else if (name == "PrevPage") go_to (current_page - 1);
                    else if (name == "FirstPage") go_to (0);
                    else if (name == "LastPage") go_to (pages.length - 1);
                    break;
                default:
                    break;
            }
        }

        public void go_to_dest (Poppler.Dest? dest) {
            if (dest == null || document == null) return;
            Poppler.Dest? target = dest;
            if (dest.type == Poppler.DestType.NAMED && dest.named_dest != null) target = document.doc.find_dest (dest.named_dest);
            if (target == null) return;
            int index = target.page_num - 1;
            if (index < 0 || index >= pages.length) return;
            double y = -1;
            if (target.change_top != 0) y = document.height (index) - target.top;
            go_to (index, y);
        }

        public void search (string text) {
            if (search_source != 0) {
                Source.remove (search_source);
                search_source = 0;
            }
            foreach (var pw in pages) {
                pw.hits.clear ();
                pw.current_hit = -1;
                pw.queue_draw ();
            }
            hits.clear ();
            hit_index = -1;
            if (document == null || text.strip () == "") {
                search_updated (0, -1);
                return;
            }
            string query = text.strip ();
            int next_page = 0;
            int start = current_page;
            search_source = Idle.add (() => {
                for (int n = 0; n < 8 && next_page < pages.length; n++, next_page++) {
                    int index = (start + next_page) % pages.length;
                    double h = document.height (index);
                    foreach (var r in document.page (index).find_text_with_options (query, Poppler.FindFlags.MULTILINE)) {
                        var view = Geometry.to_view (r, h);
                        pages[index].hits.add (view);
                        hits.add (new SearchHit (index, view));
                    }
                    pages[index].queue_draw ();
                }
                if (hit_index < 0 && hits.size > 0) {
                    hits.sort ((a, b) => a.page != b.page ? a.page - b.page : (int) (a.rect.y1 - b.rect.y1));
                    focus_hit (first_hit_from (start));
                }
                search_updated (hits.size, hit_index);
                if (next_page >= pages.length) {
                    hits.sort ((a, b) => a.page != b.page ? a.page - b.page : (a.rect.y1 < b.rect.y1 ? -1 : (a.rect.y1 > b.rect.y1 ? 1 : 0)));
                    if (hit_index >= 0) hit_index = index_of_current ();
                    search_updated (hits.size, hit_index);
                    search_finished (hits);
                    search_source = 0;
                    return Source.REMOVE;
                }
                return Source.CONTINUE;
            });
        }

        private int first_hit_from (int page) {
            for (int i = 0; i < hits.size; i++) if (hits[i].page >= page) return i;
            return 0;
        }

        private int index_of_current () {
            for (int p = 0; p < pages.length; p++) {
                if (pages[p].current_hit >= 0) {
                    var r = pages[p].hits[pages[p].current_hit];
                    for (int i = 0; i < hits.size; i++) {
                        if (hits[i].page == p && hits[i].rect.x1 == r.x1 && hits[i].rect.y1 == r.y1) return i;
                    }
                }
            }
            return 0;
        }

        private void focus_hit (int i) {
            if (hits.size == 0) return;
            hit_index = (i + hits.size) % hits.size;
            var hit = hits[hit_index];
            foreach (var pw in pages) {
                if (pw.current_hit >= 0) {
                    pw.current_hit = -1;
                    pw.queue_draw ();
                }
            }
            var pw = pages[hit.page];
            for (int k = 0; k < pw.hits.size; k++) {
                if (pw.hits[k].x1 == hit.rect.x1 && pw.hits[k].y1 == hit.rect.y1) pw.current_hit = k;
            }
            pw.queue_draw ();
            go_to (hit.page, hit.rect.y1);
            search_updated (hits.size, hit_index);
        }

        public void focus_result (int i) { focus_hit (i); }

        public string hit_context (SearchHit hit) {
            string line = document.page (hit.page).get_selected_text (Poppler.SelectionStyle.LINE, hit.rect) ?? "";
            return line.replace ("\n", " ").strip ();
        }

        public void next_hit () { focus_hit (hit_index + 1); }
        public void previous_hit () { focus_hit (hit_index - 1); }
    }
}
