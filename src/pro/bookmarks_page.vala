using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class BookmarksPage : ToolPage {
        private PreferencesGroup? tree_group = null;
        private PreferencesGroup links_group;
        private Gee.ArrayList<Singularity.Pdf.OutlineItem> items = new Gee.ArrayList<Singularity.Pdf.OutlineItem> ();
        private ulong area_handler = 0;
        private EntryRow link_target;

        public BookmarksPage () {
            base (_("Bookmarks and Links"), "user-bookmarks-symbolic");
        }

        public override void build () {
            var add = add_group (_("Add Bookmark"));
            var title = new HintEntryRow (_("Title"), _("Type a title, then press Enter"));
            title.entry_activated.connect (() => {
                if (title.text.strip () == "") return;
                var item = new Singularity.Pdf.OutlineItem ();
                item.title = title.text.strip ();
                item.page = ctx.current_page;
                items.add (item);
                save ();
                title.text = "";
            });
            add.add_row (title);
            var from_text = new ActionRow (_("Add Bookmark for the Current Page"), null, "bookmark-new-symbolic");
            from_text.activated.connect (() => {
                var item = new Singularity.Pdf.OutlineItem ();
                string sel = ctx.view.selection_text ().strip ();
                item.title = sel != "" ? sel : _("Page %d").printf (ctx.current_page + 1);
                item.page = ctx.current_page;
                items.add (item);
                save ();
            });
            add.add_row (from_text);
            var auto = new ActionRow (_("Create from Headings"), _("Uses the large text of every page"), "view-list-symbolic");
            auto.activated.connect (() => {
                var e = ctx.engine ();
                if (e == null) return;
                items = headings (e);
                save ();
            });
            add.add_row (auto);
            tree_group = add_group (_("Bookmarks in This Document"));

            var links = add_group (_("Add Link"));
            link_target = new HintEntryRow (_("Link To"), _("Web address, page number or file"));
            links.add_row (link_target);
            var draw = mode_row (_("Draw a Link Area"), _("Drag over the text or picture to link"), "insert-link-symbolic");
            draw.activated.connect (() => {
                if (link_target.text.strip () == "") {
                    ctx.toast (_("Type where the link goes first"));
                    return;
                }
                if (area_handler != 0) ctx.view.disconnect (area_handler);
                ctx.view.tool = Tool.AREA;
                set_active_mode (draw);
                area_handler = ctx.view.area_picked.connect ((page, area, widget) => {
                    string target = link_target.text.strip ();
                    ctx.run (_("Link added"), (e) => {
                        string? uri, file;
                        int tp;
                        parse_target (target, e.page_count (), out uri, out tp, out file);
                        Singularity.Pdf.Annotations.link (e, page, PageMap.to_pdf (e, page, area), uri, tp, -1, file);
                    });
                });
            });
            links.add_row (draw);
            links_group = add_group (_("Links in This Document"));
        }

        private static void parse_target (string target, int pages, out string? uri, out int page, out string? file) {
            uri = null;
            file = null;
            page = -1;
            int n = int.parse (target);
            if (n.to_string () == target && n >= 1 && n <= pages) {
                page = n - 1;
            } else if (target.contains ("://") || target.has_prefix ("mailto:") || target.has_prefix ("www.")) {
                uri = target.has_prefix ("www.") ? "https://" + target : target;
            } else if (target.contains ("@") && !target.contains (" ")) {
                uri = "mailto:" + target;
            } else {
                file = target;
            }
        }

        private Gee.ArrayList<Singularity.Pdf.OutlineItem> headings (Singularity.Pdf.Document e) {
            var result = new Gee.ArrayList<Singularity.Pdf.OutlineItem> ();
            var sizes = new Gee.ArrayList<double?> ();
            var all = new Gee.ArrayList<Singularity.Pdf.TextBlock> ();
            for (int p = 0; p < e.page_count (); p++) {
                foreach (var b in Singularity.Pdf.Editor.blocks (e, p)) {
                    all.add (b);
                    sizes.add (b.size);
                }
            }
            if (sizes.size == 0) return result;
            sizes.sort ((a, b) => a < b ? -1 : (a > b ? 1 : 0));
            double body = sizes[sizes.size / 2];
            Singularity.Pdf.OutlineItem? parent = null;
            foreach (var b in all) {
                if (b.lines.size > 3 || b.size < body * 1.18) continue;
                string text = b.text ().replace ("\n", " ").strip ();
                if (text.char_count () < 2 || text.char_count () > 120) continue;
                var item = new Singularity.Pdf.OutlineItem ();
                item.title = text;
                item.page = b.page;
                item.top = b.box.y2 + 4;
                if (b.size >= body * 1.5 || parent == null) {
                    result.add (item);
                    parent = item;
                } else {
                    parent.children.add (item);
                }
            }
            return result;
        }

        private void save () {
            var copy = items;
            ctx.run (_("Bookmarks saved"), (e) => Singularity.Pdf.Outline.write (e, copy));
        }

        public override void enter () {
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
            if (tree_group == null) return;
            var e = ctx.engine ();
            if (e == null) return;
            items = Singularity.Pdf.Outline.tree (e);
            tree_group.clear ();
            add_rows (tree_group, items, 0);
            tree_group.description = items.size == 0 ? _("This document has no bookmarks.") : "";
            links_group.clear ();
            var lg = links_group;
            int count = 0;
            foreach (var a in Singularity.Pdf.Annotations.list (e)) {
                if (a.subtype != "Link") continue;
                int page;
                double top;
                string uri;
                Singularity.Pdf.Outline.target_of (e, a.dict, out page, out top, out uri);
                string target = uri != "" ? uri : (page >= 0 ? _("Page %d").printf (page + 1) : _("No target"));
                var exp = new ExpanderRow (target, _("On page %d").printf (a.page + 1), "insert-link-symbolic");
                var edit = new HintEntryRow (_("Link To"), _("Web address, page number or file"));
                edit.text = uri != "" ? uri : (page >= 0 ? (page + 1).to_string () : "");
                int lp = a.page;
                int num = a.reference.num;
                edit.entry_activated.connect (() => {
                    string t = edit.text.strip ();
                    ctx.run (_("Link updated"), (en) => {
                        string? u, f;
                        int tp;
                        parse_target (t, en.page_count (), out u, out tp, out f);
                        Singularity.Pdf.Annotations.set_link_target (en, en.resolve (Singularity.Pdf.Obj.reference (num)), u, tp, -1, f);
                    });
                });
                exp.add_row (edit);
                var del = new ActionRow (_("Remove Link"), null, "user-trash-symbolic");
                del.activated.connect (() => ctx.run (_("Link removed"), (en) => Singularity.Pdf.Annotations.remove (en, lp, Singularity.Pdf.Obj.reference (num))));
                exp.add_row (del);
                lg.add_row (exp);
                if (++count >= 300) break;
            }
            links_group.description = count == 0 ? _("This document has no links.") : "";
        }

        private void add_rows (PreferencesGroup group, Gee.ArrayList<Singularity.Pdf.OutlineItem> list, int depth) {
            for (int i = 0; i < list.size; i++) {
                var item = list[i];
                var exp = new ExpanderRow (string.nfill (depth * 2, ' ') + item.title, item.page >= 0 ? _("Page %d").printf (item.page + 1) : item.uri);
                var rename = new EntryRow (_("Title"));
                rename.text = item.title;
                rename.entry_activated.connect (() => {
                    item.title = rename.text;
                    save ();
                });
                exp.add_row (rename);
                var here = new ActionRow (_("Point to the Current Page"), null, "find-location-symbolic");
                here.activated.connect (() => {
                    item.page = ctx.current_page;
                    item.top = -1;
                    item.uri = "";
                    save ();
                });
                exp.add_row (here);
                int index = i;
                var owner = list;
                var up = new ActionRow (_("Move Up"), null, "go-up-symbolic");
                up.activated.connect (() => {
                    if (index == 0) return;
                    var t = owner[index - 1];
                    owner[index - 1] = owner[index];
                    owner[index] = t;
                    save ();
                });
                exp.add_row (up);
                var down = new ActionRow (_("Move Down"), null, "go-down-symbolic");
                down.activated.connect (() => {
                    if (index + 1 >= owner.size) return;
                    var t = owner[index + 1];
                    owner[index + 1] = owner[index];
                    owner[index] = t;
                    save ();
                });
                exp.add_row (down);
                var indent = new ActionRow (_("Make Child of Previous"), null, "go-next-symbolic");
                indent.activated.connect (() => {
                    if (index == 0) return;
                    owner.remove_at (index);
                    owner[index - 1].children.add (item);
                    save ();
                });
                exp.add_row (indent);
                var del = new ActionRow (_("Delete Bookmark"), null, "user-trash-symbolic");
                del.activated.connect (() => {
                    owner.remove_at (index);
                    owner.insert_all (index, item.children);
                    save ();
                });
                exp.add_row (del);
                group.add_row (exp);
                if (item.children.size > 0) add_rows (group, item.children, depth + 1);
            }
        }
    }
}
