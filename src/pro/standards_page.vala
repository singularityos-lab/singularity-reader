using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class StandardsPage : ToolPage {
        private Box report_box;
        private SelectionRow standard;

        public StandardsPage () {
            base (_("Standards and Preflight"), "emblem-ok-symbolic");
        }

        private string code () {
            string v = standard.current_value;
            if (v.has_prefix ("PDF/A-1b")) return "a1b";
            if (v.has_prefix ("PDF/A-2b")) return "a2b";
            if (v.has_prefix ("PDF/A-3b")) return "a3b";
            if (v.has_prefix ("PDF/X-1a")) return "x1a";
            if (v.has_prefix ("PDF/X-3")) return "x3";
            if (v.has_prefix ("PDF/X-4")) return "x4";
            return "ua";
        }

        public override void build () {
            var group = add_group (_("Standard"), _("PDF/A is for long-term archiving, PDF/X for commercial printing, PDF/UA for accessibility. Converting embeds fonts, adds color profiles and metadata, and removes what the standard forbids."));
            standard = new SelectionRow (_("Check Against"), { "PDF/A-1b", "PDF/A-2b", "PDF/A-3b", "PDF/X-1a", "PDF/X-3", "PDF/X-4", "PDF/UA-1" }, "PDF/A-2b");
            group.add_row (standard);
            var check = footer_button (_("Check"));
            check.clicked.connect (run_check);
            var convert = footer_button (_("Convert"), true);
            convert.clicked.connect (run_convert);
            report_box = new Box (Orientation.VERTICAL, 8);
            append (report_box);
        }

        private Gee.ArrayList<Singularity.Pdf.Issue> check_with (Singularity.Pdf.Document e, string c) {
            switch (c) {
                case "a1b": return Singularity.Pdf.Standards.check_pdfa (e, "1b");
                case "a2b": return Singularity.Pdf.Standards.check_pdfa (e, "2b");
                case "a3b": return Singularity.Pdf.Standards.check_pdfa (e, "3b");
                case "x1a": return Singularity.Pdf.Standards.check_pdfx (e, "PDF/X-1a");
                case "x3": return Singularity.Pdf.Standards.check_pdfx (e, "PDF/X-3");
                case "x4": return Singularity.Pdf.Standards.check_pdfx (e, "PDF/X-4");
                default: return Singularity.Pdf.Standards.check_pdfua (e);
            }
        }

        private void run_check () {
            var e = ctx.engine ();
            if (e == null) return;
            show (check_with (e, code ()), _("The document meets %s.").printf (standard.current_value));
        }

        private void run_convert () {
            string c = code ();
            if (c == "ua") {
                var e = ctx.engine ();
                if (e == null) return;
                string title = e.lookup (e.info (), "Title").text_value ();
                if (title == "") title = ctx.document.title ();
                ctx.run (_("Tags added"), (en) => Singularity.Pdf.Tags.auto_tag (en, default_language (), title));
                var after = ctx.engine ();
                if (after != null) show (Singularity.Pdf.Standards.check_pdfua (after), _("The document meets PDF/UA-1."));
                return;
            }
            var e = ctx.engine ();
            if (e == null) return;
            try {
                Singularity.Pdf.SaveOptions opts;
                Gee.ArrayList<Singularity.Pdf.Issue> remaining;
                if (c.has_prefix ("a")) remaining = Singularity.Pdf.Standards.convert_pdfa (e, c.substring (1), out opts);
                else remaining = Singularity.Pdf.Standards.convert_pdfx (e, c == "x1a" ? "PDF/X-1a" : (c == "x3" ? "PDF/X-3" : "PDF/X-4"), out opts);
                ctx.document.replace_bytes (e.save (opts), "");
                show (remaining, _("Converted: the document now meets %s.").printf (standard.current_value));
            } catch (Error err) {
                ctx.error_dialog (_("The document could not be converted"), err.message);
            }
        }

        public static string default_language () {
            foreach (var name in Intl.get_language_names ()) {
                if (name == "C" || name == "POSIX") continue;
                string l = name.split (".")[0].split ("@")[0].replace ("_", "-");
                if (l != "") return l;
            }
            return "en";
        }

        private void show (Gee.List<Singularity.Pdf.Issue> issues, string ok) {
            Widget? child;
            while ((child = report_box.get_first_child ()) != null) report_box.remove (child);
            if (issues.size == 0) {
                var row = new ActionRow (ok, null, "emblem-ok-symbolic");
                var g = new PreferencesGroup (_("Result"));
                g.add_row (row);
                report_box.append (g);
                return;
            }
            var g = new PreferencesGroup (ngettext ("%d Problem", "%d Problems", issues.size).printf (issues.size));
            foreach (var issue in issues) {
                string sub = issue.rule;
                if (issue.page >= 0) sub += ", " + _("page %d").printf (issue.page + 1);
                if (issue.fixable) sub += ", " + _("fixed by converting");
                var row = new ActionRow (issue.message, sub, issue.severity == Singularity.Pdf.Severity.ERROR ? "dialog-error-symbolic" : "dialog-warning-symbolic");
                int page = issue.page;
                if (page >= 0) row.activated.connect (() => ctx.view.go_to (page));
                g.add_row (row);
            }
            report_box.append (g);
        }
    }

    public class AccessibilityPage : ToolPage {
        private PreferencesGroup? order_group = null;
        private EntryRow lang_row;
        private EntryRow title_row;
        private Gee.ArrayList<Singularity.Pdf.TagNode> nodes = new Gee.ArrayList<Singularity.Pdf.TagNode> ();

        public AccessibilityPage () {
            base (_("Accessibility"), "preferences-desktop-accessibility-symbolic");
        }

        public override void build () {
            var doc_group = add_group (_("Document"));
            title_row = new EntryRow (_("Title"));
            doc_group.add_row (title_row);
            lang_row = new HintEntryRow (_("Language"), _("For example it-IT"));
            lang_row.text = StandardsPage.default_language ();
            doc_group.add_row (lang_row);
            var tag = new ActionRow (_("Add Tags Automatically"), _("Finds headings, paragraphs and figures and sets the reading order"), "format-justify-left-symbolic");
            tag.activated.connect (() => {
                string lang = lang_row.text.strip ();
                string title = title_row.text.strip ();
                ctx.run (_("Tags added"), (e) => Singularity.Pdf.Tags.auto_tag (e, lang, title));
            });
            doc_group.add_row (tag);
            var check = new ActionRow (_("Check Accessibility"), null, "emblem-ok-symbolic");
            check.activated.connect (() => {
                var e = ctx.engine ();
                if (e == null) return;
                var issues = Singularity.Pdf.Standards.check_pdfua (e);
                if (issues.size == 0) ctx.toast (_("No accessibility problems found"));
                else ctx.toast (ngettext ("%d accessibility problem found, see Standards and Preflight", "%d accessibility problems found, see Standards and Preflight", issues.size).printf (issues.size));
            });
            doc_group.add_row (check);
            order_group = add_group (_("Reading Order"), _("Screen readers follow this order. Move items to fix it, change what each item is, and describe every figure."));
        }

        public override void enter () {
            refresh ();
        }

        public override void document_changed () {
            refresh ();
        }

        private void refresh () {
            if (order_group == null) return;
            order_group.clear ();
            var e = ctx.engine ();
            if (e == null) return;
            title_row.text = e.lookup (e.info (), "Title").text_value ();
            string lang = e.lookup (e.catalog (), "Lang").text_value ();
            if (lang != "") lang_row.text = lang;
            nodes = new Gee.ArrayList<Singularity.Pdf.TagNode> ();
            foreach (var n in Singularity.Pdf.Tags.read (e)) if (n.role != "Document") nodes.add (n);
            if (nodes.size == 0) {
                text_row (order_group, _("The document has no tags yet."));
                return;
            }
            for (int i = 0; i < nodes.size && i < 400; i++) order_group.add_row (node_row (i));
        }

        private Widget node_row (int index) {
            var n = nodes[index];
            string text = n.text.strip ().replace ("\n", " ");
            if (text.char_count () > 60) text = text.substring (0, text.index_of_nth_char (60)) + "…";
            if (text == "") text = n.role == "Figure" ? (n.alt != "" ? n.alt : _("Figure without description")) : n.role;
            var exp = new ExpanderRow ("%d. %s".printf (index + 1, text), "%s, %s".printf (n.role, _("page %d").printf (n.page + 1)));
            var role = new SelectionRow (_("Kind"), { "P", "H1", "H2", "H3", "Figure", "Caption", "L", "LI", "Table", "Quote", "Note", "Artifact" }, n.role);
            int num = n.reference.num;
            role.selected.connect ((v) => apply_to (num, (e, node) => Singularity.Pdf.Tags.set_role (e, node, v)));
            exp.add_row (role);
            if (n.role == "Figure") {
                var alt = new EntryRow (_("Description of the Figure"));
                alt.text = n.alt;
                alt.entry_activated.connect (() => {
                    string a = alt.text;
                    apply_to (num, (e, node) => Singularity.Pdf.Tags.set_alt (e, node, a));
                });
                exp.add_row (alt);
            }
            var up = new ActionRow (_("Move Up"), null, "go-up-symbolic");
            up.activated.connect (() => move (index, -1));
            exp.add_row (up);
            var down = new ActionRow (_("Move Down"), null, "go-down-symbolic");
            down.activated.connect (() => move (index, 1));
            exp.add_row (down);
            var go = new ActionRow (_("Show in Document"), null, "find-location-symbolic");
            int page = n.page;
            go.activated.connect (() => ctx.view.go_to (page));
            exp.add_row (go);
            return exp;
        }

        private delegate void NodeOp (Singularity.Pdf.Document e, Singularity.Pdf.TagNode node);

        private void apply_to (int num, owned NodeOp op) {
            ctx.run (_("Tag updated"), (e) => {
                foreach (var n in Singularity.Pdf.Tags.read (e)) {
                    if (n.reference.num == num) {
                        op (e, n);
                        return;
                    }
                }
            });
        }

        private void move (int index, int delta) {
            int target = index + delta;
            if (target < 0 || target >= nodes.size) return;
            var order_nums = new Gee.ArrayList<int> ();
            foreach (var n in nodes) if (n.depth <= 1) order_nums.add (n.reference.num);
            int a = order_nums.index_of (nodes[index].reference.num), b = order_nums.index_of (nodes[target].reference.num);
            if (a < 0 || b < 0) return;
            int tmp = order_nums[a];
            order_nums[a] = order_nums[b];
            order_nums[b] = tmp;
            ctx.run (_("Reading order changed"), (e) => {
                var all = Singularity.Pdf.Tags.read (e);
                var ordered = new Gee.ArrayList<Singularity.Pdf.TagNode> ();
                foreach (int num in order_nums) {
                    foreach (var n in all) if (n.reference.num == num) ordered.add (n);
                }
                Singularity.Pdf.Tags.reorder (e, ordered);
            });
        }
    }
}
