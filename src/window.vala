using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    [GtkTemplate (ui = "/dev/sinty/reader/ui/main.ui")]
    public class ReaderWindow : Singularity.Widgets.Window {
        [GtkChild] unowned Box main_box;
        [GtkChild] unowned Stack content_stack;

        private ReaderApp app;
        private DocumentView view;
        private ReaderSidebar sidebar;
        private SignatureStore signatures;
        private Label page_total;
        private Label search_status;
        private Button save_button;
        private Button color_button;
        private Box color_dot;
        private CssProvider color_provider;
        private Box recent_list;
        private Label recent_empty;
        private Popover? selection_popover = null;
        private bool closing_confirmed = false;

        public ReaderDocument? document { get { return view.document; } }
        public PageGrid page_grid;
        private ToolPanel tool_panel;
        private Revealer tool_revealer;
        private ProContext pro;
        private ReflowView reflow;
        private Recovery recovery;

        public ReaderWindow (ReaderApp app) {
            Object (application: app);
            this.app = app;
            set_default_size (1180, 860);
            set_title (_("Reader"));
            signatures = app.signatures;

            view = new DocumentView (app.settings);
            sidebar = new ReaderSidebar (view);
            content_stack.add_named (build_welcome (), "welcome");
            content_stack.add_named (view, "document");
            page_grid = new PageGrid ();
            content_stack.add_named (page_grid, "organize");
            reflow = new ReflowView ();
            reflow.closed.connect (() => show_document_view ());
            content_stack.add_named (reflow, "reflow");
            content_stack.visible_child_name = "welcome";
            pro = new ProContext (this, app, view);
            recovery = new Recovery ();
            tool_panel = new ToolPanel (pro);
            register_tools ();
            tool_panel.close_requested.connect (() => set_tools_visible (false));
            tool_revealer = new Revealer ();
            tool_revealer.transition_type = RevealerTransitionType.SLIDE_LEFT;
            tool_revealer.child = tool_panel;
            tool_revealer.reveal_child = false;
            tool_revealer.visible = false;
            tool_revealer.notify["child-revealed"].connect (() => {
                if (!tool_revealer.child_revealed && !tool_revealer.reveal_child) tool_revealer.visible = false;
            });
            main_box.remove (content_stack);
            var split = new Box (Orientation.HORIZONTAL, 0);
            split.vexpand = true;
            content_stack.hexpand = true;
            split.append (content_stack);
            split.append (tool_revealer);
            main_box.append (split);
            view.reloaded.connect (() => {
                if (document == null) return;
                sidebar.load (document);
                page_total.label = "%d / %d".printf (view.current_page + 1, document.n_pages);
                if (content_stack.visible_child_name == "organize") page_grid.load (document);
                tool_panel.document_changed ();
                recovery.schedule (document);
                update_title ();
            });

            build_bubbles ();
            set_content (main_box);
            set_sidebar (sidebar);
            set_sidebar_width (220);
            set_sidebar_visible (false);

            view.page_changed.connect ((page) => {
                if (document != null) page_total.label = "%d / %d".printf (page + 1, document.n_pages);
            });
            view.zoom_changed.connect (() => zoom_bubble.tooltip_text = _("Zoom %d%%").printf ((int) Math.round (view.zoom * 100)));
            view.search_updated.connect ((count, current) => {
                search_status.visible = true;
                search_status.label = count == 0 ? _("No results") : "%d / %d".printf (current + 1, count);
            });
            view.link_activated.connect ((uri) => {
                var launcher = new UriLauncher (uri);
                launcher.launch.begin (this, null);
            });
            view.edited.connect (update_title);
            view.selection_changed.connect (on_selection_changed);
            view.annotation_selected.connect ((page, annot, area, widget) => {
                var pop = new AnnotationPopover (view.document, view, page, annot, area);
                show_popover (pop, widget, area);
            });
            view.note_requested.connect ((page, x, y, widget) => {
                var prompt = new TextPrompt (_("New Note"), "", _("Add"));
                prompt.submitted.connect ((text) => {
                    Annotations.note (view.document, page, x, y, text, app.settings.get_string ("note-color"), app.settings.get_string ("author"));
                });
                show_popover (prompt, widget, Geometry.rect (x, y, x + 1, y + 1));
            });
            view.text_requested.connect ((page, area, widget) => {
                var prompt = new TextPrompt (_("Text"), "", _("Add"));
                prompt.submitted.connect ((text) => {
                    double size = double.max (9, double.min (28, (area.y2 - area.y1) * 0.45));
                    Annotations.text_box (view.document, page, area, text, app.settings.get_string ("text-color"), size, app.settings.get_string ("author"));
                });
                prompt.closed.connect (() => view.clear_ghost (page));
                show_popover (prompt, widget, area);
            });
            view.notify["tool"].connect (sync_tool_buttons);
            view.form_field_activated.connect (edit_form_field);

            var keys = new EventControllerKey ();
            keys.key_pressed.connect (on_key);
            ((Widget) this).add_controller (keys);

            var drop = new DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
            drop.drop.connect ((value, x, y) => {
                var list = (Gdk.FileList) value.get_boxed ();
                foreach (var file in list.get_files ()) {
                    app.open_file (file, this);
                    break;
                }
                return true;
            });
            ((Widget) this).add_controller (drop);

            close_request.connect (on_close_request);
            install_actions ();
            update_title ();
        }

        private void register_tools () {
            tool_panel.register ("edit", new EditPage (), _("Edit and Organize"));
            tool_panel.register ("organize", new OrganizePage (), _("Edit and Organize"));
            tool_panel.register ("marks", new PageMarksPage (), _("Edit and Organize"));
            tool_panel.register ("bookmarks", new BookmarksPage (), _("Edit and Organize"));
            tool_panel.register ("attachments", new AttachmentsPage (), _("Edit and Organize"));
            tool_panel.register ("comment", new CommentPage (), _("Review"));
            tool_panel.register ("compare", new ComparePage (), _("Review"));
            tool_panel.register ("measure", new MeasurePage (), _("Review"));
            tool_panel.register ("read", new ReadPage (), _("Review"));
            tool_panel.register ("fill", new FillFormPage (), _("Forms and Signatures"));
            tool_panel.register ("prepare", new PrepareFormPage (), _("Forms and Signatures"));
            tool_panel.register ("sign", new SignPage (), _("Forms and Signatures"));
            tool_panel.register ("redact", new RedactPage (), _("Protect"));
            tool_panel.register ("protect", new ProtectPage (), _("Protect"));
            tool_panel.register ("ocr", new OcrPage (), _("Scan and Convert"));
            tool_panel.register ("export", new ExportPage (), _("Scan and Convert"));
            tool_panel.register ("optimize", new OptimizePage (), _("Scan and Convert"));
            tool_panel.register ("standards", new StandardsPage (), _("Standards"));
            tool_panel.register ("accessibility", new AccessibilityPage (), _("Standards"));
            tool_panel.register ("batch", new BatchPage (), _("Standards"));
            tool_panel.finish_registration ();
        }

        public void set_tools_visible (bool visible) {
            if (!visible) {
                tool_panel.leave_active ();
                tool_panel.show_hub ();
                view.tool = Tool.SELECT;
                view.clear_overlays ();
            }
            if (visible) tool_revealer.visible = true;
            tool_revealer.reveal_child = visible;
        }

        public void open_tool (string id) {
            if (document == null) return;
            set_tools_visible (true);
            tool_panel.open (id);
        }

        public void show_page_grid () {
            if (document == null) return;
            page_grid.load (document);
            content_stack.visible_child_name = "organize";
        }

        public void show_document_view () {
            if (document != null) content_stack.visible_child_name = "document";
        }

        public bool page_grid_visible () {
            return content_stack.visible_child_name == "organize";
        }

        public void show_reflow () {
            if (document == null) return;
            reflow.load (document, view.current_page);
            content_stack.visible_child_name = "reflow";
        }

        private void edit_form_field (int page, string name, Poppler.FormFieldType type, Poppler.Rectangle area, Widget widget) {
            var engine = pro.engine ();
            if (engine == null || name == "") return;
            var info = Singularity.Pdf.Forms.find (engine, name);
            if (info == null) return;
            if (info.type == Singularity.Pdf.FieldType.CHECKBOX || info.type == Singularity.Pdf.FieldType.RADIO) {
                string next = info.value;
                if (info.type == Singularity.Pdf.FieldType.CHECKBOX) {
                    next = info.value != "" && info.value != "Off" ? "" : "true";
                } else {
                    foreach (var w in info.widgets) {
                        if (w.page != page) continue;
                        var r = PageMap.to_view (engine, page, w.rect);
                        if (Geometry.contains (Geometry.rect (r.x1 - 1, r.y1 - 1, r.x2 + 1, r.y2 + 1), (area.x1 + area.x2) / 2, (area.y1 + area.y2) / 2)) next = w.on_state;
                    }
                }
                pro.run ("", (e) => {
                    var f = Singularity.Pdf.Forms.find (e, name);
                    if (f == null) return;
                    Singularity.Pdf.Forms.set_value (e, f, next);
                    Singularity.Pdf.Forms.recalculate (e);
                });
                return;
            }
            if (info.type == Singularity.Pdf.FieldType.SIGNATURE) {
                open_tool ("sign");
                return;
            }
            var pop = new Popover ();
            var box = new Box (Orientation.VERTICAL, 6);
            box.margin_top = 8;
            box.margin_bottom = 8;
            box.margin_start = 8;
            box.margin_end = 8;
            var label = new Label (info.tooltip != "" ? info.tooltip : info.name);
            label.add_css_class ("heading");
            label.xalign = 0;
            box.append (label);
            var error = new Label ("");
            error.add_css_class ("error");
            error.visible = false;
            if (info.type == Singularity.Pdf.FieldType.COMBO || info.type == Singularity.Pdf.FieldType.LIST) {
                foreach (var i in Singularity.Pdf.Pages.range (0, info.options.length)) {
                    string value = info.options[i];
                    var b = new Button.with_label (i < info.option_labels.length ? info.option_labels[i] : value);
                    b.add_css_class ("flat");
                    if (value == info.value) b.add_css_class ("suggested-action");
                    b.clicked.connect (() => {
                        pop.popdown ();
                        pro.run ("", (e) => {
                            var f = Singularity.Pdf.Forms.find (e, name);
                            if (f == null) return;
                            Singularity.Pdf.Forms.set_value (e, f, value);
                            Singularity.Pdf.Forms.recalculate (e);
                        });
                    });
                    box.append (b);
                }
            } else {
                Widget editor;
                TextView? tv = null;
                Entry? entry = null;
                if (info.multiline) {
                    tv = new TextView ();
                    tv.buffer.text = info.value;
                    tv.wrap_mode = WrapMode.WORD_CHAR;
                    tv.set_size_request (280, 90);
                    editor = tv;
                } else {
                    entry = new Entry ();
                    entry.text = info.value;
                    entry.width_chars = 28;
                    entry.visibility = !info.password;
                    if (info.max_len > 0) entry.max_length = info.max_len;
                    editor = entry;
                }
                box.append (editor);
                box.append (error);
                var apply = new Button.with_label (_("Done"));
                apply.add_css_class ("suggested-action");
                apply.halign = Align.END;
                var check = info;
                apply.clicked.connect (() => {
                    string value = tv != null ? tv.buffer.text : entry.text;
                    string msg;
                    if (!Singularity.Pdf.Forms.validate (check, value, out msg)) {
                        error.label = msg;
                        error.visible = true;
                        return;
                    }
                    pop.popdown ();
                    pro.run ("", (e) => {
                        var f = Singularity.Pdf.Forms.find (e, name);
                        if (f == null) return;
                        Singularity.Pdf.Forms.set_value (e, f, value);
                        Singularity.Pdf.Forms.recalculate (e);
                    });
                });
                if (entry != null) entry.activate.connect (() => apply.clicked ());
                box.append (apply);
                Idle.add (() => {
                    editor.grab_focus ();
                    return Source.REMOVE;
                });
            }
            pop.child = box;
            show_popover (pop, widget, area);
        }

        public void show_popover_at (Popover pop, Widget widget, Poppler.Rectangle area) {
            show_popover (pop, widget, area);
        }

        private void show_popover (Popover pop, Widget widget, Poppler.Rectangle area) {
            double z = view.zoom;
            var rect = Gdk.Rectangle ();
            rect.x = (int) (area.x1 * z);
            rect.y = (int) (area.y1 * z);
            rect.width = int.max (1, (int) ((area.x2 - area.x1) * z));
            rect.height = int.max (1, (int) ((area.y2 - area.y1) * z));
            pop.set_parent (widget);
            pop.pointing_to = rect;
            pop.closed.connect (() => Idle.add (() => {
                pop.unparent ();
                return Source.REMOVE;
            }));
            pop.popup ();
        }

        private Widget build_welcome () {
            var wp = new WelcomePage ();
            wp.app_icon_name = "dev.sinty.reader";
            wp.title = _("Reader");
            wp.subtitle = _("Read, annotate and sign PDF documents");
            wp.add_action ("folder-open", _("Open Document"),
                _("Choose a PDF from disk,\nor drop one on this window."), () => app.choose_file (this));
            var recent_wrap = new Box (Orientation.VERTICAL, 12);
            var recent_title = new Label (_("Recent"));
            recent_title.add_css_class ("title-2");
            recent_title.halign = Align.START;
            recent_list = new Box (Orientation.VERTICAL, 0);
            recent_list.add_css_class ("reader-recent-list");
            recent_wrap.append (recent_title);
            recent_wrap.append (recent_list);
            recent_empty = new Label (_("Documents you open appear here."));
            recent_empty.add_css_class ("dim-label");
            recent_empty.halign = Align.START;
            recent_wrap.append (recent_empty);
            wp.set_extra_widget (recent_wrap);
            fill_recent ();
            return wp;
        }

        private static string friendly_folder (File file) {
            var parent = file.get_parent ();
            if (parent == null) return "";
            string path = parent.get_path () ?? parent.get_parse_name ();
            string home = Environment.get_home_dir ();
            int sandbox = path.index_of ("/application-data/");
            if (sandbox >= 0) {
                int inner = path.index_of ("/home", sandbox + 18);
                if (inner >= 0) return "~" + path.substring (inner + 5);
            }
            if (path == home) return "~";
            if (path.has_prefix (home + "/")) return "~" + path.substring (home.length);
            return path;
        }

        private static string recent_date (DateTime dt) {
            var now = new DateTime.now_local ();
            var diff = now.difference (dt);
            if (diff < TimeSpan.DAY && now.get_day_of_month () == dt.get_day_of_month ()) return _("Today");
            if (diff < 2 * TimeSpan.DAY) return _("Yesterday");
            if (diff < 7 * TimeSpan.DAY) return dt.format ("%A");
            return dt.format ("%d %b %Y");
        }

        private void fill_recent () {
            Widget? child;
            while ((child = recent_list.get_first_child ()) != null) recent_list.remove (child);
            int count = 0;
            var items = RecentManager.get_default ().get_items ();
            items.sort ((a, b) => (int) (b.get_modified ().to_unix () - a.get_modified ().to_unix ()));
            foreach (var info in items) {
                if (info.get_mime_type () != "application/pdf" || !info.exists ()) continue;
                var file = File.new_for_uri (info.get_uri ());
                var row = new Button ();
                row.has_frame = false;
                row.add_css_class ("reader-recent-row");
                var hbox = new Box (Orientation.HORIZONTAL, 12);
                hbox.margin_top = 8;
                hbox.margin_bottom = 8;
                hbox.margin_start = 12;
                hbox.margin_end = 12;
                var icon = new Image.from_icon_name ("x-office-document-symbolic");
                icon.pixel_size = 20;
                hbox.append (icon);
                var labels = new Box (Orientation.VERTICAL, 2);
                labels.hexpand = true;
                var name = new Label (info.get_display_name ());
                name.xalign = 0;
                name.ellipsize = Pango.EllipsizeMode.END;
                labels.append (name);
                var path = new Label (friendly_folder (file));
                path.xalign = 0;
                path.ellipsize = Pango.EllipsizeMode.MIDDLE;
                path.add_css_class ("caption");
                path.add_css_class ("dim-label");
                labels.append (path);
                hbox.append (labels);
                var date = new Label (recent_date (info.get_modified ().to_local ()));
                date.add_css_class ("caption");
                date.add_css_class ("dim-label");
                date.valign = Align.CENTER;
                hbox.append (date);
                row.child = hbox;
                string uri = info.get_uri ();
                row.clicked.connect (() => app.open_file (File.new_for_uri (uri), this));
                recent_list.append (row);
                if (++count >= 8) break;
            }
            recent_list.visible = count > 0;
            recent_empty.visible = count == 0;
        }

        private Gee.ArrayList<Widget> doc_bubbles = new Gee.ArrayList<Widget> ();
        private Button tool_bubble;
        private Button zoom_bubble;
        private Button find_bubble;
        private Button sign_bubble;
        private Popover? find_popover = null;

        private Widget track (Widget w) {
            doc_bubbles.add (w);
            return w;
        }

        private void set_doc_bubbles_visible (bool visible) {
            foreach (var w in doc_bubbles) w.visible = visible;
            if (visible) sync_tool_buttons ();
        }

        private void build_bubbles () {
            track (add_bubble_icon ("go-previous-symbolic", _("Close Document"), () => close_document ()));
            track (add_bubble_icon ("sidebar-show-symbolic", _("Pages and Outline (F9)"), () => {
                set_sidebar_visible (!get_sidebar_visible ());
                app.settings.set_boolean ("show-sidebar", get_sidebar_visible ());
            }));
            track (add_bubble_icon ("document-open-symbolic", _("Open (Ctrl+O)"), () => app.choose_file (this)));
            save_button = add_bubble_icon ("document-save-symbolic", _("Save (Ctrl+S)"), () => { });
            save_button.clicked.connect (() => {
                var menu = bubble_menu (save_button);
                menu.add_item (_("Save"), "document-save-symbolic", () => save.begin ());
                menu.add_item (_("Save As"), "document-save-as-symbolic", () => save_as.begin ());
                menu.add_item (_("Save to Online Account…"), "document-send-symbolic", () => CloudActions.save_document (this));
                menu.add_separator ();
                menu.add_item (_("Print"), "document-print-symbolic", () => print_document ());
                popup_menu (menu);
            });
            track (save_button);
            track (add_bubble_icon ("singularity-share-symbolic", _("Share"), () => ((GLib.ActionGroup) this).activate_action ("share", null)));
            find_bubble = add_bubble_icon ("edit-find-symbolic", _("Find (Ctrl+F)"), () => open_find ());
            track (find_bubble);

            track (add_bubble_icon ("applications-utilities-symbolic", _("All Tools"), () => set_tools_visible (!tool_revealer.reveal_child)));
            tool_bubble = add_bubble_icon ("reader-select-symbolic", _("Tool"), () => show_tool_menu ());
            track (tool_bubble);
            sign_bubble = add_bubble_icon ("reader-signature-symbolic", _("Sign"), () => { });
            sign_bubble.clicked.connect (() => show_signatures (sign_bubble));
            track (sign_bubble);

            color_button = new Button ();
            color_button.add_css_class ("flat");
            color_button.tooltip_text = _("Color");
            color_dot = new Box (Orientation.HORIZONTAL, 0);
            color_dot.add_css_class ("reader-color-dot");
            color_dot.halign = Align.CENTER;
            color_dot.valign = Align.CENTER;
            color_provider = new CssProvider ();
            color_dot.get_style_context ().add_provider (color_provider, STYLE_PROVIDER_PRIORITY_USER + 10);
            color_button.child = color_dot;
            color_button.clicked.connect (show_color_picker);
            add_bubble_widget (color_button);

            zoom_bubble = add_bubble_icon ("zoom-fit-best-symbolic", _("Zoom"), () => show_zoom_menu ());
            track (zoom_bubble);

            page_total = add_bubble_label ("", force_ssd);
            track (page_total);
            var page_click = new GestureClick ();
            page_click.released.connect (() => show_page_jump ());
            page_total.add_controller (page_click);
            page_total.tooltip_text = _("Go to Page");

            search_status = new Label ("");
            set_doc_bubbles_visible (false);
            color_button.visible = false;
        }

        private void anchor_to_bubble (Popover pop, Widget bubble) {
            if (pop.get_parent () == null) pop.set_parent (content_stack);
            Graphene.Rect bounds;
            if (bubble.compute_bounds (content_stack, out bounds)) {
                var rect = Gdk.Rectangle ();
                rect.x = (int) bounds.origin.x;
                rect.y = (int) bounds.origin.y;
                rect.width = (int) bounds.size.width;
                rect.height = (int) bounds.size.height;
                pop.pointing_to = rect;
            }
            pop.position = PositionType.BOTTOM;
        }

        private ContextMenu bubble_menu (Widget bubble) {
            var menu = new ContextMenu (content_stack);
            anchor_to_bubble (menu, bubble);
            return menu;
        }

        private void popup_menu (ContextMenu menu) {
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        private struct ToolItem {
            public string label;
            public string icon;
            public int tool;
            public int kind;
        }

        private ToolItem[] tool_items () {
            ToolItem[] items = {
                { _("Select Text"), "reader-select-symbolic", Tool.SELECT, -1 },
                { _("Highlight"), "reader-highlighter-symbolic", Tool.MARKUP, MarkupKind.HIGHLIGHT },
                { _("Underline"), "format-text-underline-symbolic", Tool.MARKUP, MarkupKind.UNDERLINE },
                { _("Strikeout"), "format-text-strikethrough-symbolic", Tool.MARKUP, MarkupKind.STRIKEOUT },
                { _("Squiggly"), "format-text-underline-symbolic", Tool.MARKUP, MarkupKind.SQUIGGLY }
            };
            if (Annotations.ink_supported ()) {
                items += ToolItem () { label = _("Pen"), icon = "reader-pen-symbolic", tool = Tool.PEN, kind = -1 };
                items += ToolItem () { label = _("Highlighter Pen"), icon = "reader-highlighter-symbolic", tool = Tool.HIGHLIGHTER, kind = -1 };
            }
            items += ToolItem () { label = _("Note"), icon = "reader-note-symbolic", tool = Tool.NOTE, kind = -1 };
            items += ToolItem () { label = _("Text Box"), icon = "insert-text-symbolic", tool = Tool.TEXT, kind = -1 };
            return items;
        }

        private void show_tool_menu () {
            var menu = bubble_menu (tool_bubble);
            foreach (var item in tool_items ()) {
                int tool = item.tool;
                int kind = item.kind;
                bool current = view.tool == tool && (kind < 0 || view.markup_kind == (MarkupKind) kind);
                menu.add_item (item.label, current ? "object-select-symbolic" : item.icon, () => {
                    if (kind >= 0) view.markup_kind = (MarkupKind) kind;
                    set_tool ((Tool) tool);
                    sync_tool_buttons ();
                });
            }
            popup_menu (menu);
        }

        private void show_zoom_menu () {
            var menu = bubble_menu (zoom_bubble);
            var current = new Label (_("Zoom %d%%").printf ((int) Math.round (view.zoom * 100)));
            current.add_css_class ("dim-label");
            current.xalign = 0;
            current.margin_start = 12;
            current.margin_top = 6;
            current.margin_bottom = 4;
            menu.add_widget (current);
            menu.add_item (_("Zoom In"), "zoom-in-symbolic", () => view.zoom_to (view.zoom * 1.2));
            menu.add_item (_("Zoom Out"), "zoom-out-symbolic", () => view.zoom_to (view.zoom / 1.2));
            menu.add_separator ();
            menu.add_item (_("Fit Width"), "zoom-fit-best-symbolic", () => view.fit_width ());
            menu.add_item (_("Fit Page"), "view-fullscreen-symbolic", () => view.fit_page ());
            menu.add_item (_("Actual Size"), "zoom-original-symbolic", () => view.zoom_to (1));
            popup_menu (menu);
        }

        private void show_page_jump () {
            if (document == null) return;
            var pop = new Popover ();
            var box = new Box (Orientation.HORIZONTAL, 8);
            box.margin_top = 8;
            box.margin_bottom = 8;
            box.margin_start = 10;
            box.margin_end = 10;
            box.append (new Label (_("Page")));
            var entry = new Entry ();
            entry.width_chars = 5;
            entry.xalign = 1;
            entry.input_purpose = InputPurpose.DIGITS;
            entry.text = (view.current_page + 1).to_string ();
            box.append (entry);
            box.append (new Label (_("of %d").printf (document.n_pages)));
            entry.activate.connect (() => {
                int n = int.parse (entry.text);
                if (n >= 1 && n <= document.n_pages) view.go_to (n - 1);
                pop.popdown ();
                view.grab_focus ();
            });
            pop.child = box;
            anchor_to_bubble (pop, page_total);
            pop.closed.connect (() => Idle.add (() => {
                pop.unparent ();
                return Source.REMOVE;
            }));
            pop.popup ();
            entry.grab_focus ();
            entry.select_region (0, -1);
        }

        private void open_find () {
            if (document == null) return;
            if (find_popover != null) {
                anchor_to_bubble (find_popover, find_bubble);
                find_popover.popup ();
                return;
            }
            find_popover = new Popover ();
            find_popover.autohide = true;
            var box = new Box (Orientation.HORIZONTAL, 6);
            box.margin_top = 8;
            box.margin_bottom = 8;
            box.margin_start = 10;
            box.margin_end = 10;
            var entry = new Gtk.SearchEntry ();
            entry.width_chars = 24;
            entry.placeholder_text = _("Find in Document");
            entry.search_changed.connect (() => view.search (entry.text));
            entry.activate.connect (() => view.next_hit ());
            box.append (entry);
            search_status = new Label ("");
            search_status.add_css_class ("dim-label");
            search_status.add_css_class ("caption");
            search_status.width_chars = 9;
            box.append (search_status);
            var prev = new Button.from_icon_name ("go-up-symbolic");
            prev.add_css_class ("flat");
            prev.tooltip_text = _("Previous (Shift+F3)");
            prev.clicked.connect (() => view.previous_hit ());
            box.append (prev);
            var next = new Button.from_icon_name ("go-down-symbolic");
            next.add_css_class ("flat");
            next.tooltip_text = _("Next (F3)");
            next.clicked.connect (() => view.next_hit ());
            box.append (next);
            var outer = new Box (Orientation.VERTICAL, 0);
            outer.append (box);
            var results = new ListBox ();
            results.add_css_class ("navigation-sidebar");
            results.selection_mode = SelectionMode.NONE;
            var results_scroll = new ScrolledWindow ();
            results_scroll.hscrollbar_policy = PolicyType.NEVER;
            results_scroll.max_content_height = 320;
            results_scroll.propagate_natural_height = true;
            results_scroll.child = results;
            results_scroll.visible = false;
            outer.append (results_scroll);
            results.row_activated.connect ((row) => view.focus_result (row.get_index ()));
            view.search_finished.connect ((hits) => {
                Widget? c;
                while ((c = results.get_first_child ()) != null) results.remove (c);
                int n = 0;
                foreach (var hit in hits) {
                    var row = new Box (Orientation.VERTICAL, 2);
                    row.margin_start = 10;
                    row.margin_end = 10;
                    row.margin_top = 4;
                    row.margin_bottom = 4;
                    var page_label = new Label (_("Page %d").printf (hit.page + 1));
                    page_label.add_css_class ("caption");
                    page_label.add_css_class ("dim-label");
                    page_label.xalign = 0;
                    var context = new Label (view.hit_context (hit));
                    context.xalign = 0;
                    context.ellipsize = Pango.EllipsizeMode.END;
                    context.max_width_chars = 42;
                    row.append (page_label);
                    row.append (context);
                    results.append (row);
                    if (++n >= 300) break;
                }
                results_scroll.visible = n > 0;
            });
            find_popover.child = outer;
            anchor_to_bubble (find_popover, find_bubble);
            find_popover.popup ();
            entry.grab_focus ();
        }

        private void close_document () {
            if (document != null && document.modified) {
                var dlg = new ConfirmDialog (app, _("Save Changes?"), "application-pdf",
                    _("Your annotations to \"%s\" will be lost if you close without saving.").printf (document.title ()),
                    _("Save"), ConfirmDialog.ActionStyle.SUGGESTED);
                dlg.transient_for = this;
                dlg.set_secondary (_("Discard"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
                dlg.response.connect ((r) => {
                    if (r == ConfirmDialog.Response.SECONDARY) show_welcome ();
                    else if (r == ConfirmDialog.Response.PRIMARY) save.begin ((obj, res) => {
                        if (save.end (res)) show_welcome ();
                    });
                });
                dlg.present ();
                return;
            }
            show_welcome ();
        }

        private void show_welcome () {
            set_tools_visible (false);
            if (document != null) recovery.discard (document.file);
            view.unload ();
            if (find_popover != null) {
                find_popover.unparent ();
                find_popover = null;
            }
            fill_recent ();
            content_stack.visible_child_name = "welcome";
            set_sidebar_visible (false);
            set_doc_bubbles_visible (false);
            color_button.visible = false;
            update_title ();
        }

        private string color_key () {
            switch (view.tool) {
                case Tool.PEN: return "pen-color";
                case Tool.NOTE: return "note-color";
                case Tool.TEXT: return "text-color";
                case Tool.MARKUP: return view.markup_kind == MarkupKind.HIGHLIGHT ? "highlight-color" : "markup-color";
                default: return "highlight-color";
            }
        }

        private void sync_color () {
            string hex = app.settings.get_string (color_key ());
            color_provider.load_from_string ("box { background-color: %s; }".printf (hex));
            color_button.tooltip_text = _("Color for %s").printf (tool_name ());
        }

        private string tool_name () {
            switch (view.tool) {
                case Tool.PEN: return _("Pen");
                case Tool.NOTE: return _("Notes");
                case Tool.TEXT: return _("Text Boxes");
                case Tool.MARKUP: return view.markup_kind == MarkupKind.HIGHLIGHT ? _("Highlights") : _("Marks");
                case Tool.HIGHLIGHTER: return _("Highlighter Pen");
                default: return _("Highlights");
            }
        }

        private void show_color_picker () {
            var pop = new Popover ();
            var box = new Box (Orientation.VERTICAL, 8);
            box.margin_top = 10;
            box.margin_bottom = 10;
            box.margin_start = 10;
            box.margin_end = 10;
            var title = new Label (_("Default color for %s").printf (tool_name ()));
            title.add_css_class ("heading");
            title.xalign = 0;
            box.append (title);
            string key = color_key ();
            var palette = new Palette (app.settings.get_string (key));
            palette.picked.connect ((hex) => {
                app.settings.set_string (key, hex);
                sync_color ();
            });
            box.append (palette);
            var custom = new ColorDialogButton (new ColorDialog ());
            var rgba = Gdk.RGBA ();
            rgba.parse (app.settings.get_string (key));
            custom.rgba = rgba;
            custom.notify["rgba"].connect (() => {
                var value = Value (typeof (Gdk.RGBA));
                custom.get_property ("rgba", ref value);
                Gdk.RGBA* c = (Gdk.RGBA*) value.get_boxed ();
                if (c == null) return;
                app.settings.set_string (key, "#%02x%02x%02x".printf ((int) (c.red * 255), (int) (c.green * 255), (int) (c.blue * 255)));
                sync_color ();
            });
            var custom_row = new Box (Orientation.HORIZONTAL, 8);
            var custom_label = new Label (_("Custom"));
            custom_label.hexpand = true;
            custom_label.xalign = 0;
            custom_row.append (custom_label);
            custom_row.append (custom);
            box.append (custom_row);
            pop.child = box;
            anchor_to_bubble (pop, color_button);
            pop.closed.connect (() => Idle.add (() => {
                pop.unparent ();
                return Source.REMOVE;
            }));
            pop.popup ();
        }

        private void set_tool (Tool tool) {
            view.tool = tool;
            if (tool != Tool.SELECT) {
                view.clear_selection ();
                view.deselect_annotation ();
            }
        }

        private void sync_tool_buttons () {
            if (tool_bubble == null) return;
            foreach (var item in tool_items ()) {
                if (item.tool != view.tool) continue;
                if (item.kind >= 0 && view.markup_kind != (MarkupKind) item.kind) continue;
                tool_bubble.icon_name = item.icon;
                tool_bubble.tooltip_text = _("Tool: %s").printf (item.label);
                break;
            }
            color_button.visible = document != null && view.tool != Tool.SELECT && view.tool != Tool.SIGNATURE;
            sync_color ();
        }

        private void show_signatures (Widget anchor) {
            var pop = new Popover ();
            var box = new Box (Orientation.VERTICAL, 8);
            box.margin_top = 10;
            box.margin_bottom = 10;
            box.margin_start = 10;
            box.margin_end = 10;
            var title = new Label (_("Signatures"));
            title.add_css_class ("heading");
            title.xalign = 0;
            box.append (title);
            var list = signatures.list ();
            if (list.size == 0) {
                var empty = new Label (_("Create a signature, then click where it goes."));
                empty.add_css_class ("dim-label");
                empty.wrap = true;
                empty.max_width_chars = 28;
                box.append (empty);
            }
            foreach (string path in list) {
                var row = new Box (Orientation.HORIZONTAL, 6);
                var pick = new Button ();
                pick.add_css_class ("reader-signature-choice");
                pick.hexpand = true;
                var picture = new Picture ();
                picture.paintable = signature_thumbnail (path, 220, 64);
                picture.can_shrink = true;
                picture.content_fit = ContentFit.CONTAIN;
                picture.set_size_request (220, 64);
                pick.child = picture;
                pick.tooltip_text = _("Click on the page to place this signature");
                string chosen = path;
                pick.clicked.connect (() => {
                    pop.popdown ();
                    var surface = SignatureStore.load (chosen);
                    if (surface == null) return;
                    view.signature = surface;
                    set_tool (Tool.SIGNATURE);
                });
                var remove = new Button.from_icon_name ("user-trash-symbolic");
                remove.add_css_class ("flat");
                remove.valign = Align.CENTER;
                remove.tooltip_text = _("Delete Signature");
                remove.clicked.connect (() => {
                    pop.popdown ();
                    signatures.remove (chosen);
                });
                row.append (pick);
                row.append (remove);
                box.append (row);
            }
            var create = new Button.with_label (_("New Signature"));
            create.clicked.connect (() => {
                pop.popdown ();
                var dialog = new SignatureDialog (app, signatures);
                dialog.transient_for = this;
                dialog.created.connect ((path) => {
                    var surface = SignatureStore.load (path);
                    if (surface == null) return;
                    view.signature = surface;
                    set_tool (Tool.SIGNATURE);
                });
                dialog.present ();
            });
            box.append (create);
            pop.child = box;
            anchor_to_bubble (pop, anchor);
            pop.closed.connect (() => Idle.add (() => {
                pop.unparent ();
                return Source.REMOVE;
            }));
            pop.popup ();
        }

        private Gdk.Texture? signature_thumbnail (string path, int max_w, int max_h) {
            var source = SignatureStore.load (path);
            if (source == null) return null;
            int factor = int.max (1, get_scale_factor ());
            double scale = double.min ((double) max_w * factor / source.get_width (), (double) max_h * factor / source.get_height ());
            int w = int.max (1, (int) (source.get_width () * scale)), h = int.max (1, (int) (source.get_height () * scale));
            var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, w, h);
            var cr = new Cairo.Context (surface);
            cr.scale (scale, scale);
            cr.set_source_surface (source, 0, 0);
            cr.get_source ().set_filter (Cairo.Filter.GOOD);
            cr.paint ();
            surface.flush ();
            var bytes = new Bytes (surface.get_data ()[0 : surface.get_stride () * h]);
            return new Gdk.MemoryTexture (w, h, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, bytes, surface.get_stride ());
        }

        private void on_selection_changed (bool has, int page, Poppler.Rectangle area) {
            enable_action ("copy", has);
            if (selection_popover != null) {
                selection_popover.popdown ();
                selection_popover = null;
            }
            if (!has || view.tool != Tool.SELECT) return;
            var pw = view.page_widget (page);
            if (pw == null) return;
            var pop = new Popover ();
            pop.autohide = false;
            pop.has_arrow = true;
            pop.position = PositionType.TOP;
            pop.add_css_class ("reader-selection-actions");
            var row = new Box (Orientation.HORIZONTAL, 2);
            row.margin_top = 2;
            row.margin_bottom = 2;
            row.margin_start = 2;
            row.margin_end = 2;
            string[] icons = { "edit-copy-symbolic", "reader-highlighter-symbolic", "format-text-underline-symbolic", "format-text-strikethrough-symbolic", "reader-note-symbolic" };
            string[] tips = { _("Copy"), _("Highlight"), _("Underline"), _("Strikeout"), _("Highlight and Comment") };
            for (int i = 0; i < icons.length; i++) {
                var btn = new Button.from_icon_name (icons[i]);
                btn.add_css_class ("flat");
                btn.tooltip_text = tips[i];
                int action = i;
                btn.clicked.connect (() => {
                    pop.popdown ();
                    selection_popover = null;
                    switch (action) {
                        case 0:
                            copy_selection ();
                            break;
                        case 4:
                            comment_selection (page, area, pw);
                            break;
                        default:
                            view.markup_selection ((MarkupKind) (action - 1));
                            break;
                    }
                });
                row.append (btn);
            }
            pop.child = row;
            selection_popover = pop;
            show_popover (pop, pw, area);
        }

        private void comment_selection (int page, Poppler.Rectangle area, Widget widget) {
            var line_starts = new Gee.ArrayList<int> ();
            var glyphs = Annotations.selected_glyphs (view.document, page, area, Poppler.SelectionStyle.GLYPH, line_starts);
            var prompt = new TextPrompt (_("Comment"), "", _("Add"));
            prompt.submitted.connect ((text) => {
                var annot = Annotations.markup (view.document, page, glyphs, MarkupKind.HIGHLIGHT,
                    app.settings.get_string ("highlight-color"), app.settings.get_double ("highlight-opacity"), app.settings.get_string ("author"), line_starts);
                if (annot != null) Annotations.set_text (view.document, page, annot, text);
                view.clear_selection ();
            });
            show_popover (prompt, widget, area);
        }

        private void copy_selection () {
            string text = view.selection_text ();
            if (text != "") get_clipboard ().set_text (text);
        }

        private bool on_key (uint keyval, uint code, Gdk.ModifierType state) {
            if (document == null) return false;
            if (get_focus () is Editable || get_focus () is TextView) return false;
            bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
            switch (keyval) {
                case Gdk.Key.Escape:
                    view.clear_selection ();
                    view.deselect_annotation ();
                    set_tool (Tool.SELECT);
                    return true;
                case Gdk.Key.Home:
                    if (ctrl) { view.go_to (0); return true; }
                    return false;
                case Gdk.Key.End:
                    if (ctrl) { view.go_to (document.n_pages - 1); return true; }
                    return false;
                case Gdk.Key.Page_Down:
                case Gdk.Key.n:
                    if (keyval == Gdk.Key.n && ctrl) return false;
                    view.go_to (view.current_page + 1);
                    return true;
                case Gdk.Key.Page_Up:
                case Gdk.Key.p:
                    if (keyval == Gdk.Key.p && ctrl) return false;
                    view.go_to (view.current_page - 1);
                    return true;
                default:
                    return false;
            }
        }

        private void install_actions () {
            ActionMap actions = this;
            add_action_entry (actions, "save", () => save.begin ());
            add_action_entry (actions, "save-as", () => save_as.begin ());
            add_action_entry (actions, "save-online", () => CloudActions.save_document (this));
            add_action_entry (actions, "print", print_document);
            Singularity.Share.add_action (actions, this, () => {
                return document != null ? new Singularity.ShareContent.for_files ({ document.file }) : null;
            });
            add_action_entry (actions, "copy", copy_selection);
            add_action_entry (actions, "zoom-in", () => view.zoom_to (view.zoom * 1.2));
            add_action_entry (actions, "zoom-out", () => view.zoom_to (view.zoom / 1.2));
            add_action_entry (actions, "zoom-fit", () => view.fit_width ());
            add_action_entry (actions, "zoom-page", () => view.fit_page ());
            add_action_entry (actions, "zoom-reset", () => view.zoom_to (1));
            add_action_entry (actions, "sidebar", () => {
                set_sidebar_visible (!get_sidebar_visible ());
                app.settings.set_boolean ("show-sidebar", get_sidebar_visible ());
            });
            add_action_entry (actions, "find", () => open_find ());
            add_action_entry (actions, "tools", () => {
                if (document != null) set_tools_visible (!tool_revealer.reveal_child);
            });
            add_action_entry (actions, "find-next", () => view.next_hit ());
            add_action_entry (actions, "find-previous", () => view.previous_hit ());
            add_action_entry (actions, "tool-select", () => set_tool (Tool.SELECT));
            add_action_entry (actions, "tool-highlight", () => {
                view.markup_kind = MarkupKind.HIGHLIGHT;
                set_tool (Tool.MARKUP);
            });
            add_action_entry (actions, "tool-underline", () => {
                view.markup_kind = MarkupKind.UNDERLINE;
                set_tool (Tool.MARKUP);
            });
            add_action_entry (actions, "tool-strikeout", () => {
                view.markup_kind = MarkupKind.STRIKEOUT;
                set_tool (Tool.MARKUP);
            });
            add_action_entry (actions, "tool-squiggly", () => {
                view.markup_kind = MarkupKind.SQUIGGLY;
                set_tool (Tool.MARKUP);
            });
            add_action_entry (actions, "tool-note", () => set_tool (Tool.NOTE));
            add_action_entry (actions, "tool-text", () => set_tool (Tool.TEXT));
            add_action_entry (actions, "tool-pen", () => {
                if (Annotations.ink_supported ()) set_tool (Tool.PEN);
            });
            add_action_entry (actions, "tool-highlighter-pen", () => {
                if (Annotations.ink_supported ()) set_tool (Tool.HIGHLIGHTER);
            });
            add_action_entry (actions, "sign", () => show_signatures (sign_bubble));
            add_action_entry (actions, "close-document", () => close_document ());
            add_action_entry (actions, "close", () => close ());
            add_action_entry (actions, "next-page", () => view.go_to (view.current_page + 1));
            add_action_entry (actions, "previous-page", () => view.go_to (view.current_page - 1));
            add_action_entry (actions, "first-page", () => view.go_to (0));
            add_action_entry (actions, "last-page", () => {
                if (document != null) view.go_to (document.n_pages - 1);
            });
            add_action_entry (actions, "go-to-page", () => show_page_jump ());
            sync_actions ();
        }

        private void sync_actions () {
            bool open = document != null;
            string[] doc_actions = { "save", "tools", "save-as", "save-online", "print", "find", "find-next", "find-previous", "zoom-in", "zoom-out", "zoom-fit", "zoom-page", "zoom-reset", "sidebar", "tool-select", "tool-highlight", "tool-underline", "tool-strikeout", "tool-squiggly", "tool-note", "tool-text", "sign", "close-document", "next-page", "previous-page", "first-page", "last-page", "go-to-page" };
            foreach (string name in doc_actions) enable_action (name, open);
            enable_action ("tool-pen", open && Annotations.ink_supported ());
            enable_action ("tool-highlighter-pen", open && Annotations.ink_supported ());
            if (!open) enable_action ("copy", false);
            enable_action ("share", open && document.file.query_exists (null));
        }

        private void enable_action (string name, bool on) {
            var a = lookup_action (name) as SimpleAction;
            if (a != null) a.set_enabled (on);
        }

        public delegate void ActionHandler ();

        private void add_action_entry (ActionMap group, string name, owned ActionHandler handler) {
            var action = new SimpleAction (name, null);
            action.activate.connect (() => handler ());
            group.add_action (action);
        }

        public void show_document (ReaderDocument doc) {
            int page = app.history.page_for (doc.file);
            view.load (doc, page);
            sidebar.load (doc);
            content_stack.visible_child_name = "document";
            page_total.label = "%d / %d".printf (page + 1, doc.n_pages);
            set_doc_bubbles_visible (true);
            set_sidebar_visible (app.settings.get_boolean ("show-sidebar"));
            doc.notify["modified"].connect (update_title);
            doc.notify["modified"].connect (() => {
                if (doc.modified) recovery.schedule (doc);
            });
            doc.page_changed.connect (() => recovery.schedule (doc));
            recovery.offer (this, doc);
            view.page_changed.connect ((p) => {
                app.history.remember (doc.file, p);
                schedule_recent (doc.file, p);
            });
            update_title ();
            add_recent (doc.file, page);
        }

        private uint recent_timeout = 0;

        private void schedule_recent (File file, int page) {
            if (recent_timeout != 0) Source.remove (recent_timeout);
            recent_timeout = Timeout.add_seconds (1, () => {
                recent_timeout = 0;
                add_recent (file, page);
                return Source.REMOVE;
            });
        }

        private static void add_recent (File file, int page) {
            RecentManager.get_default ().add_full (file.get_uri (), RecentData () {
                display_name = file.get_basename (),
                description = _("page %d").printf (page + 1),
                mime_type = "application/pdf",
                app_name = "Reader",
                app_exec = "singularity-reader %u"
            });
        }

        private void update_title () {
            sync_actions ();
            if (document == null) {
                set_title (_("Reader"));
                return;
            }
            set_title ((document.modified ? "• " : "") + document.title ());
            if (document.modified) save_button.add_css_class ("reader-unsaved");
            else save_button.remove_css_class ("reader-unsaved");
        }

        public async bool save () {
            if (document == null) return true;
            if (!document.file.query_exists ()) return yield save_as ();
            if (!document.can_overwrite ()) {
                return yield save_as (_("\"%s\" is read-only here. Choose where to save your copy.").printf (document.title ()));
            }
            try {
                document.save (document.file);
                recovery.discard (document.file);
                update_title ();
                CloudActions.sync_back (this, document.file);
                return true;
            } catch (Error e) {
                show_error (_("The document could not be saved"), e.message);
                return false;
            }
        }

        public async bool save_as (string? reason = null) {
            if (document == null) return true;
            var dialog = new FileDialog ();
            dialog.title = reason ?? _("Save Document");
            var folder = document.file.get_parent ();
            if (folder != null && folder.query_exists ()) dialog.initial_folder = folder;
            string name = document.file.get_basename () ?? "document.pdf";
            if (reason != null && name.down ().has_suffix (".pdf")) name = _("%s (annotated).pdf").printf (name.substring (0, name.length - 4));
            dialog.initial_name = name;
            try {
                var target = yield dialog.save (this, null);
                if (target == null) return false;
                document.save (target);
                recovery.discard (target);
                update_title ();
                CloudActions.sync_back (this, target);
                return true;
            } catch (Error e) {
                if (!(e is Gtk.DialogError.DISMISSED)) show_error (_("The document could not be saved"), e.message);
                return false;
            }
        }

        private void show_error (string title, string detail) {
            var dlg = new ConfirmDialog.message (app, title, "dialog-error", detail, _("Close"));
            dlg.transient_for = this;
            dlg.present ();
        }

        private void print_document () {
            if (document == null) return;
            var op = new PrintOperation ();
            op.n_pages = document.n_pages;
            op.job_name = document.title ();
            op.current_page = view.current_page;
            var setup = new PageSetup ();
            double first_w = document.width (0), first_h = document.height (0);
            setup.set_paper_size (new PaperSize.custom ("document", document.title (), double.min (first_w, first_h), double.max (first_w, first_h), Unit.POINTS));
            setup.set_orientation (first_w > first_h ? PageOrientation.LANDSCAPE : PageOrientation.PORTRAIT);
            op.default_page_setup = setup;
            op.draw_page.connect ((context, index) => {
                var cr = context.get_cairo_context ();
                double pw = document.width (index), ph = document.height (index);
                double scale = double.min (context.get_width () / pw, context.get_height () / ph);
                cr.translate ((context.get_width () - pw * scale) / 2, (context.get_height () - ph * scale) / 2);
                cr.scale (scale, scale);
                document.page (index).render_for_printing (cr);
            });
            Singularity.Print.run.begin (this, op);
        }

        private bool on_close_request () {
            if (closing_confirmed || document == null || !document.modified) return false;
            var dlg = new ConfirmDialog (app, _("Save Changes?"), "application-pdf",
                _("Your annotations to \"%s\" will be lost if you close without saving.").printf (document.title ()),
                _("Save"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.set_secondary (_("Discard"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.SECONDARY) {
                    closing_confirmed = true;
                    if (document != null) recovery.discard (document.file);
                    close ();
                } else if (r == ConfirmDialog.Response.PRIMARY) {
                    save.begin ((obj, res) => {
                        if (save.end (res)) {
                            closing_confirmed = true;
                            close ();
                        }
                    });
                }
            });
            dlg.present ();
            return true;
        }
    }
}
