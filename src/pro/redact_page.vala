using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class RedactPage : ToolPage {
        private ulong area_handler = 0;
        private Gee.ArrayList<Poppler.Rectangle?> marks_view = new Gee.ArrayList<Poppler.Rectangle?> ();
        private Gee.ArrayList<int> marks_page = new Gee.ArrayList<int> ();
        private PreferencesGroup marks_group;
        private PreferencesGroup report_group;
        private Label report;
        private EntryRow search;
        private EntryRow overlay_text;

        public RedactPage () {
            base (_("Redact"), "edit-clear-symbolic");
        }

        public override void build () {
            var mark = add_group (_("Mark for Redaction"), _("Redaction removes the text, images and drawings under the marked areas from the file, then checks the result. It cannot be undone after saving."));
            var draw = mode_row (_("Mark Areas"), _("Drag over what must disappear"), "edit-select-all-symbolic");
            draw.activated.connect (() => {
                if (area_handler == 0) area_handler = ctx.view.area_picked.connect ((page, area, widget) => add_mark (page, area));
                ctx.view.tool = Tool.AREA;
                set_active_mode (draw);
            });
            mark.add_row (draw);
            search = new HintEntryRow (_("Find Text"), _("A word or phrase, then press Enter"));
            search.entry_activated.connect (() => find (Regex.escape_string (search.text.strip ())));
            mark.add_row (search);
            overlay_text = new HintEntryRow (_("Text on the Black Boxes"), _("Optional"));
            mark.add_row (overlay_text);
            var common = add_group (_("Find Personal Data"), _("Marks every match in the document."));
            string[] names = { _("Email Addresses"), _("Phone Numbers"), _("Card Numbers"), _("IBAN Codes"), _("Italian Tax Codes"), _("Dates") };
            string[] patterns = {
                "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
                "\\+?\\d[\\d\\s().-]{7,}\\d",
                "\\b(?:\\d[ -]?){13,19}\\b",
                "\\b[A-Z]{2}\\d{2}(?:\\s?[A-Z0-9]{4}){3,7}(?:\\s?[A-Z0-9]{1,3})?\\b",
                "\\b[A-Z]{6}\\d{2}[A-Z]\\d{2}[A-Z]\\d{3}[A-Z]\\b",
                "\\b\\d{1,2}[/.-]\\d{1,2}[/.-]\\d{2,4}\\b"
            };
            for (int i = 0; i < names.length; i++) {
                string p = patterns[i];
                var row = new ActionRow (names[i], null, "edit-find-symbolic");
                row.activated.connect (() => find (p));
                common.add_row (row);
            }

            marks_group = add_group (_("Marked Areas"));
            var clear = new ActionRow (_("Clear Marks"), null, "edit-clear-all-symbolic");
            clear.activated.connect (clear_marks);
            marks_group.add_row (clear);
            var mark_only = new ActionRow (_("Save Marks for Later Review"), _("Adds redaction marks others can check"), "document-save-symbolic");
            mark_only.activated.connect (() => {
                var pages = marks_page;
                var areas = marks_view;
                string text = overlay_text.text;
                ctx.run (_("Redaction marks added"), (e) => {
                    for (int i = 0; i < areas.size; i++) Singularity.Pdf.Redaction.mark (e, pages[i], PageMap.to_pdf (e, pages[i], areas[i]), text, ctx.author);
                });
                clear_marks ();
            });
            marks_group.add_row (mark_only);
            var saved = new ActionRow (_("Apply Saved Marks"), _("Redacts the marks already stored in the file"), "object-select-symbolic");
            saved.activated.connect (() => {
                Gee.ArrayList<Singularity.Pdf.RedactionReport>? reports = null;
                ctx.run ("", (e) => reports = Singularity.Pdf.Redaction.apply_marked (e));
                if (reports != null) show_report (reports);
            });
            marks_group.add_row (saved);
            report_group = add_group (_("Result"));
            report_group.visible = false;
            report = text_row (report_group);
            update_count ();
            var go = footer_button (_("Apply Redactions"));
            go.add_css_class ("destructive-action");
            go.clicked.connect (apply);

            var hidden = add_group (_("Hidden Information"), _("Removes what the page does not show but the file still contains."));
            string[] labels = { _("Metadata"), _("Scripts and Actions"), _("Attachments"), _("Comments"), _("Hidden Layers"), _("Hidden Text"), _("Links to Other Files and Sites"), _("Private Application Data"), _("Bookmarks") };
            Singularity.Pdf.HiddenInfo[] flags = { Singularity.Pdf.HiddenInfo.METADATA, Singularity.Pdf.HiddenInfo.JAVASCRIPT | Singularity.Pdf.HiddenInfo.FORM_ACTIONS,
                Singularity.Pdf.HiddenInfo.ATTACHMENTS, Singularity.Pdf.HiddenInfo.COMMENTS, Singularity.Pdf.HiddenInfo.HIDDEN_LAYERS, Singularity.Pdf.HiddenInfo.HIDDEN_TEXT,
                Singularity.Pdf.HiddenInfo.EXTERNAL_LINKS, Singularity.Pdf.HiddenInfo.PRIVATE_DATA, Singularity.Pdf.HiddenInfo.BOOKMARKS };
            var switches = new Gee.ArrayList<SwitchRow> ();
            for (int i = 0; i < labels.length; i++) {
                var sw = new SwitchRow (labels[i], null, i < 8 && i != 6);
                switches.add (sw);
                hidden.add_row (sw);
            }
            var inspect = new ActionRow (_("Examine Document"), _("Counts what each item would remove"), "edit-find-symbolic");
            hidden.add_row (inspect);
            var inspect_label = text_row (hidden);
            inspect_label.get_parent ().visible = false;
            inspect.activated.connect (() => {
                var e = ctx.engine ();
                if (e == null) return;
                var r = Singularity.Pdf.Sanitizer.inspect (e);
                inspect_label.label = _("Metadata entries: %d. Scripts: %d. Attachments: %d. Comments: %d. Hidden layers: %d. Hidden text runs: %d. External links: %d. Private data: %d. Bookmarks: %d.").printf (
                    r.metadata, r.scripts, r.attachments, r.comments, r.layers, r.hidden_text, r.links, r.private_data, r.bookmarks);
                inspect_label.get_parent ().visible = true;
            });
            var remove = header_button (hidden, _("Remove"), true);
            remove.tooltip_text = _("Remove the Selected Items");
            remove.clicked.connect (() => {
                Singularity.Pdf.HiddenInfo what = 0;
                for (int i = 0; i < switches.size; i++) if (switches[i].active) what |= flags[i];
                Singularity.Pdf.SanitizeReport? r = null;
                var opts = new Singularity.Pdf.SaveOptions ();
                opts.mode = Singularity.Pdf.SaveMode.FULL;
                opts.garbage_collect = true;
                ctx.run ("", (e) => r = Singularity.Pdf.Sanitizer.apply (e, what), opts);
                if (r != null) ctx.toast (ngettext ("%d hidden item removed", "%d hidden items removed", r.total).printf (r.total));
            });
        }

        private void add_mark (int page, Poppler.Rectangle area) {
            marks_view.add (area);
            marks_page.add (page);
            ctx.view.add_overlay (page, area, "#1a1a1a", true);
            update_count ();
        }

        private void update_count () {
            marks_group.description = marks_view.size == 0 ? _("Nothing is marked yet.") : ngettext ("%d area marked", "%d areas marked", marks_view.size).printf (marks_view.size);
        }

        private void clear_marks () {
            marks_view.clear ();
            marks_page.clear ();
            ctx.view.clear_overlays ();
            update_count ();
        }

        private void find (string pattern) {
            if (pattern == "") return;
            var e = ctx.engine ();
            if (e == null) return;
            Regex re;
            try {
                re = new Regex (pattern, RegexCompileFlags.CASELESS);
            } catch (RegexError err) {
                ctx.error_dialog (_("The search is not valid"), err.message);
                return;
            }
            int found = 0;
            for (int p = 0; p < e.page_count (); p++) {
                foreach (var r in Singularity.Pdf.Redaction.find_text (e, p, re)) {
                    var grown = Singularity.Pdf.Rect.of (r.x1 - 1, r.y1 - 1, r.x2 + 1, r.y2 + 1);
                    add_mark (p, PageMap.to_view (e, p, grown));
                    found++;
                }
            }
            ctx.toast (ngettext ("%d match marked", "%d matches marked", found).printf (found));
        }

        private void apply () {
            if (marks_view.size == 0) {
                ctx.toast (_("Mark at least one area first"));
                return;
            }
            var pages = new Gee.ArrayList<int> ();
            pages.add_all (marks_page);
            var areas = new Gee.ArrayList<Poppler.Rectangle?> ();
            areas.add_all (marks_view);
            string text = overlay_text.text;
            var reports = new Gee.ArrayList<Singularity.Pdf.RedactionReport> ();
            var opts = new Singularity.Pdf.SaveOptions ();
            opts.mode = Singularity.Pdf.SaveMode.FULL;
            opts.garbage_collect = true;
            ctx.run ("", (e) => {
                var by_page = new Gee.TreeMap<int, Gee.ArrayList<Singularity.Pdf.Rect?>> ();
                for (int i = 0; i < areas.size; i++) {
                    if (!by_page.has_key (pages[i])) by_page[pages[i]] = new Gee.ArrayList<Singularity.Pdf.Rect?> ();
                    by_page[pages[i]].add (PageMap.to_pdf (e, pages[i], areas[i]));
                }
                foreach (var entry in by_page.entries) {
                    Singularity.Pdf.Rect[] list = {};
                    foreach (var r in entry.value) list += r;
                    reports.add (Singularity.Pdf.Redaction.apply (e, entry.key, list, null, text));
                }
            }, opts);
            clear_marks ();
            show_report (reports);
        }

        private void show_report (Gee.List<Singularity.Pdf.RedactionReport> reports) {
            int glyphs = 0, images = 0, cleaned = 0, paths = 0, annots = 0;
            bool verified = true;
            var left = new StringBuilder ();
            foreach (var r in reports) {
                glyphs += r.glyphs_removed;
                images += r.images_removed;
                cleaned += r.images_cleaned;
                paths += r.paths_removed;
                annots += r.annotations_removed;
                if (!r.verified) verified = false;
                foreach (var l in r.leftovers) left.append (l + "\n");
            }
            string summary = _("Removed %d characters, %d images, %d drawings and %d annotations; %d images were blacked out in place.").printf (glyphs, images, paths, annots, cleaned);
            if (verified) summary += " " + _("Check passed: nothing readable is left under the marked areas.");
            else summary += " " + _("Check failed, still present: %s").printf (left.str);
            report.label = summary;
            report_group.visible = true;
            ctx.toast (verified ? _("Redactions applied and verified") : _("Redactions applied, but the check found leftovers"));
        }

        public override void leave () {
            if (area_handler != 0) ctx.view.disconnect (area_handler);
            area_handler = 0;
            if (ctx.view.tool == Tool.AREA) ctx.view.tool = Tool.SELECT;
            if (marks_group != null) clear_marks ();
        }
    }
}
