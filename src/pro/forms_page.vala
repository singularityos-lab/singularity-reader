using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class FillFormPage : ToolPage {
        private Box fields_box;
        private string layout_key = "";
        private Gee.HashMap<string, string> current_values = new Gee.HashMap<string, string> ();
        private Gee.HashMap<string, Widget> rows = new Gee.HashMap<string, Widget> ();

        public FillFormPage () {
            base (_("Fill and Sign"), "document-edit-symbolic");
        }

        public override void build () {
            fields_box = new Box (Orientation.VERTICAL, 18);
            append (fields_box);
            var data = add_group (_("Form Data"));
            var reset = new ActionRow (_("Reset All Fields"), null, "edit-clear-all-symbolic");
            reset.activated.connect (() => ctx.run (_("Form reset"), (e) => {
                foreach (var f in Singularity.Pdf.Forms.list (e)) Singularity.Pdf.Forms.set_value (e, f, f.default_value);
            }));
            data.add_row (reset);
            var export_xfdf = new ActionRow (_("Export Data as XFDF…"), null, "document-send-symbolic");
            export_xfdf.activated.connect (() => export_data.begin ("xfdf"));
            data.add_row (export_xfdf);
            var export_fdf = new ActionRow (_("Export Data as FDF…"), null, "document-send-symbolic");
            export_fdf.activated.connect (() => export_data.begin ("fdf"));
            data.add_row (export_fdf);
            var export_csv = new ActionRow (_("Export Data as CSV…"), null, "x-office-spreadsheet-symbolic");
            export_csv.activated.connect (() => export_data.begin ("csv"));
            data.add_row (export_csv);
            var import = new ActionRow (_("Import Data…"), null, "document-open-symbolic");
            import.activated.connect (() => import_data.begin ());
            data.add_row (import);
            var sign = add_group (_("Signature"));
            var draw = new ActionRow (_("Place a Hand-Drawn Signature"), _("Draw or import, then click on the page"), "reader-signature-symbolic");
            draw.activated.connect (() => ((GLib.ActionGroup) ctx.window).activate_action ("sign", null));
            sign.add_row (draw);
            var flatten = new ActionRow (_("Flatten Signatures and Form"), _("Turn stamps and fields into page content"), "image-x-generic-symbolic");
            flatten.activated.connect (() => ctx.run (_("Flattened"), (e) => {
                Singularity.Pdf.Forms.flatten (e);
                flatten_stamps (e);
            }));
            sign.add_row (flatten);
        }

        public static void flatten_stamps (Singularity.Pdf.Document e) {
            for (int p = 0; p < e.page_count (); p++) {
                var ops = new StringBuilder ();
                var res = e.page_resources (p);
                foreach (var a in Singularity.Pdf.Annotations.list (e, p)) {
                    if (a.subtype != "Stamp" && a.subtype != "Ink") continue;
                    var ap = e.lookup (a.dict, "AP");
                    var n = ap.is_dict () ? ap.get ("N") : null;
                    var stream = e.resolve (n);
                    if (!stream.is_stream () || n == null) continue;
                    var xo = e.sub_dict (res, "XObject");
                    string name = Singularity.Pdf.Editor.unique_resource (xo, "Fs");
                    xo.set (name, n.is_ref () ? n : e.add_ref (stream));
                    var bbox = e.lookup (stream, "BBox");
                    var br = Singularity.Pdf.Rect.of (bbox.at (0).as_number (), bbox.at (1).as_number (), bbox.at (2).as_number (), bbox.at (3).as_number ());
                    double sx = br.width () > 0 ? a.rect.width () / br.width () : 1, sy = br.height () > 0 ? a.rect.height () / br.height () : 1;
                    ops.append ("q %s 0 0 %s %s %s cm /%s Do Q\n".printf (Singularity.Pdf.Obj.format_number (sx), Singularity.Pdf.Obj.format_number (sy),
                        Singularity.Pdf.Obj.format_number (a.rect.x1 - br.x1 * sx), Singularity.Pdf.Obj.format_number (a.rect.y1 - br.y1 * sy), name));
                    Singularity.Pdf.Annotations.remove (e, p, a.reference);
                }
                if (ops.len > 0) e.append_page_content (p, ops.str.data);
            }
        }

        public override void enter () {
            refresh ();
        }

        public override void document_changed () {
            refresh ();
        }

        private bool update_in_place (Gee.List<Singularity.Pdf.FieldInfo> fields) {
            var key = new StringBuilder ();
            foreach (var f in fields) key.append_printf ("%s:%d;", f.name, (int) f.type);
            if (key.str != layout_key || layout_key == "") {
                layout_key = key.str;
                return false;
            }
            foreach (var f in fields) {
                current_values[f.name] = f.value;
                if (!rows.has_key (f.name)) continue;
                var row = rows[f.name];
                var entry = row as EntryRow;
                if (entry != null) {
                    var root = entry.get_root () as Gtk.Window;
                    bool focused = root != null && root.get_focus () != null && root.get_focus ().is_ancestor (entry);
                    if (!focused && entry.text != f.value) entry.text = f.value;
                    entry.subtitle = f.value != "" && f.format_js != "" ? Singularity.Pdf.Forms.display_value (f, f.value) : "";
                    continue;
                }
                var sel = row as SelectionRow;
                if (sel != null) {
                    string[] opts = f.type == Singularity.Pdf.FieldType.RADIO ? f.options : f.option_labels;
                    string shown = f.value;
                    for (int i = 0; i < f.options.length && i < opts.length; i++) if (f.options[i] == f.value) shown = opts[i];
                    if (shown == "" || shown == "Off") shown = _("None");
                    if (sel.current_value != shown) sel.current_value = shown;
                    continue;
                }
                var sw = row as SwitchRow;
                if (sw != null) {
                    bool on = f.value != "" && f.value != "Off";
                    if (sw.active != on) {
                        sw.set_data<bool> ("syncing", true);
                        sw.active = on;
                        sw.set_data<bool> ("syncing", false);
                    }
                }
            }
            return true;
        }

        private void refresh () {
            if (fields_box == null) return;
            var e = ctx.engine ();
            if (e == null) return;
            var listed = Singularity.Pdf.Forms.list (e);
            if (!Singularity.Pdf.Forms.has_xfa (e) && update_in_place (listed)) return;
            foreach (var f in listed) current_values[f.name] = f.value;
            rows.clear ();
            Widget? child;
            while ((child = fields_box.get_first_child ()) != null) fields_box.remove (child);
            if (Singularity.Pdf.Forms.has_xfa (e)) {
                var values = Singularity.Pdf.Forms.xfa_values (e);
                var g = new PreferencesGroup (_("XFA"), _("This form also contains XFA data (%d values). Its static form fields are shown below; dynamic XFA layouts are not supported.").printf (values.size));
                if (values.size > 0) {
                    var xfa = new ActionRow (_("Copy XFA Values into the Fields"), null, "edit-paste-symbolic");
                    xfa.activated.connect (() => ctx.run (_("XFA values applied"), (en) => Singularity.Pdf.Forms.apply_xfa_to_acroform (en)));
                    g.add_row (xfa);
                }
                fields_box.append (g);
            }
            var fields = Singularity.Pdf.Forms.list (e);
            if (fields.size == 0) {
                var none = new PreferencesGroup (_("Fields"), _("This document has no form fields."));
                var prepare = new ActionRow (_("Prepare Form"), _("Add fields to fill in"), "insert-text-symbolic");
                prepare.activated.connect (() => ctx.window.open_tool ("prepare"));
                none.add_row (prepare);
                fields_box.append (none);
                return;
            }
            var by_page = new Gee.TreeMap<int, PreferencesGroup> ();
            foreach (var f in fields) {
                if (f.type == Singularity.Pdf.FieldType.PUSHBUTTON) continue;
                int page = f.widgets.size > 0 ? f.widgets[0].page : -1;
                if (!by_page.has_key (page)) by_page[page] = new PreferencesGroup (page >= 0 ? _("Page %d").printf (page + 1) : _("Other Fields"));
                var widget = field_row (f);
                rows[f.name] = widget;
                by_page[page].add_row (widget);
            }
            foreach (var g in by_page.values) fields_box.append (g);
        }

        private Widget field_row (Singularity.Pdf.FieldInfo f) {
            string label = f.tooltip != "" ? f.tooltip : f.name;
            if (f.required) label += " *";
            string name = f.name;
            switch (f.type) {
                case Singularity.Pdf.FieldType.CHECKBOX:
                    var sw = new SwitchRow (label, null, f.value != "" && f.value != "Off");
                    sw.sensitive = !f.read_only;
                    sw.switch_btn.notify["active"].connect (() => {
                        if (!sw.get_data<bool> ("syncing")) set_value (name, sw.active ? "true" : "");
                    });
                    return sw;
                case Singularity.Pdf.FieldType.RADIO:
                case Singularity.Pdf.FieldType.COMBO:
                case Singularity.Pdf.FieldType.LIST:
                    string[] opts = f.type == Singularity.Pdf.FieldType.RADIO ? f.options : f.option_labels;
                    string[] values = f.options;
                    string current = f.value;
                    for (int i = 0; i < values.length && i < opts.length; i++) if (values[i] == f.value) current = opts[i];
                    if (current == "" || current == "Off") current = _("None");
                    var sel = new SelectionRow (label, opts, current);
                    sel.sensitive = !f.read_only;
                    sel.selected.connect ((item) => {
                        sel.current_value = item;
                        sel.expanded = false;
                        for (int i = 0; i < opts.length; i++) if (opts[i] == item && i < values.length) set_value (name, values[i]);
                    });
                    return sel;
                case Singularity.Pdf.FieldType.SIGNATURE:
                    return new ActionRow (label, f.value != "" ? _("Signed") : _("Signature field, use Digital Signature"), "reader-signature-symbolic");
                default:
                    var entry = new EntryRow (label);
                    entry.text = f.value;
                    entry.sensitive = !f.read_only;
                    var info = f;
                    entry.entry_activated.connect (() => {
                        string msg;
                        if (!Singularity.Pdf.Forms.validate (info, entry.text, out msg)) {
                            ctx.toast (msg);
                            return;
                        }
                        current_values[name] = entry.text;
                        set_value (name, entry.text);
                    });
                    var focus = new EventControllerFocus ();
                    focus.leave.connect (() => {
                        string known = current_values.has_key (name) ? current_values[name] : "";
                        if (entry.text != known) {
                            string msg;
                            if (Singularity.Pdf.Forms.validate (info, entry.text, out msg)) {
                                current_values[name] = entry.text;
                                set_value (name, entry.text);
                            }
                            else ctx.toast (msg);
                        }
                    });
                    entry.add_controller (focus);
                    if (f.value != "" && f.format_js != "") entry.subtitle = Singularity.Pdf.Forms.display_value (f, f.value);
                    return entry;
            }
        }

        private void set_value (string name, string value) {
            Idle.add (() => {
                apply_value (name, value);
                return Source.REMOVE;
            });
        }

        private void apply_value (string name, string value) {
            ctx.run ("", (e) => {
                var f = Singularity.Pdf.Forms.find (e, name);
                if (f == null) return;
                Singularity.Pdf.Forms.set_value (e, f, value);
                Singularity.Pdf.Forms.recalculate (e);
            });
        }

        private async void export_data (string kind) {
            var file = yield ctx.choose_save (_("Export Form Data"), ctx.base_name () + "." + kind);
            if (file == null) return;
            try {
                var e = ctx.document.open_engine ();
                string name = ctx.document.file.get_basename () ?? "form.pdf";
                if (kind == "xfdf") FileUtils.set_contents (file.get_path (), Singularity.Pdf.Annotations.export_xfdf (e, name));
                else if (kind == "fdf") FileUtils.set_data (file.get_path (), Singularity.Pdf.Annotations.export_fdf (e, name));
                else FileUtils.set_contents (file.get_path (), Singularity.Pdf.Forms.export_csv (e));
                ctx.toast (_("Form data exported"));
            } catch (Error err) {
                ctx.error_dialog (_("The form data could not be exported"), err.message);
            }
        }

        private async void import_data () {
            var file = yield ctx.choose_open (_("Import Form Data"));
            if (file == null) return;
            int count = 0;
            ctx.run ("", (e) => {
                uint8[] data;
                FileUtils.get_data (file.get_path (), out data);
                string lower = (file.get_basename () ?? "").down ();
                var text = new uint8[data.length + 1];
                Memory.copy (text, data, data.length);
                if (lower.has_suffix (".csv")) count = Singularity.Pdf.Forms.import_csv (e, (string) text);
                else if (lower.has_suffix (".xfdf") || lower.has_suffix (".xml")) count = Singularity.Pdf.Annotations.import_xfdf (e, (string) text);
                else count = Singularity.Pdf.Annotations.import_fdf (e, data);
            });
            ctx.toast (ngettext ("%d item imported", "%d items imported", count).printf (count));
        }
    }

    public class PrepareFormPage : ToolPage {
        private Singularity.Pdf.FieldType pending = Singularity.Pdf.FieldType.TEXT;
        private ulong area_handler = 0;
        private PreferencesGroup? fields_group = null;
        private PreferencesGroup detect;
        private Gee.ArrayList<Singularity.Pdf.DetectedField> detected = new Gee.ArrayList<Singularity.Pdf.DetectedField> ();
        private Button create_detected;

        public PrepareFormPage () {
            base (_("Prepare Form"), "insert-text-symbolic");
        }

        public override void build () {
            detect = add_group (_("Automatic Detection"));
            var run = new ActionRow (_("Detect Fields on This Page"), _("Finds lines and boxes meant to be filled"), "edit-find-symbolic");
            run.activated.connect (() => detect_fields (false));
            detect.add_row (run);
            var run_all = new ActionRow (_("Detect Fields on All Pages"), null, "edit-find-symbolic");
            run_all.activated.connect (() => detect_fields (true));
            detect.add_row (run_all);
            create_detected = header_button (detect, _("Create"), true);
            create_detected.visible = false;
            create_detected.clicked.connect (() => {
                var list = detected;
                ctx.run (ngettext ("%d field created", "%d fields created", list.size).printf (list.size), (e) => {
                    foreach (var d in list) Singularity.Pdf.Forms.create_field (e, d.page, d.type, d.name != "" ? d.name : "Field", d.rect);
                });
                detected = new Gee.ArrayList<Singularity.Pdf.DetectedField> ();
                create_detected.visible = false;
                detect.description = "";
                ctx.view.clear_overlays ();
            });
            var add = add_group (_("Add Field"), _("Pick a field type, then drag on the page where it goes."));
            string[] labels = { _("Text Field"), _("Check Box"), _("Radio Button"), _("Drop-Down List"), _("List Box"), _("Signature Field"), _("Button") };
            Singularity.Pdf.FieldType[] types = { Singularity.Pdf.FieldType.TEXT, Singularity.Pdf.FieldType.CHECKBOX, Singularity.Pdf.FieldType.RADIO,
                Singularity.Pdf.FieldType.COMBO, Singularity.Pdf.FieldType.LIST, Singularity.Pdf.FieldType.SIGNATURE, Singularity.Pdf.FieldType.PUSHBUTTON };
            for (int i = 0; i < labels.length; i++) {
                var t = types[i];
                var row = mode_row (labels[i], null, "list-add-symbolic");
                row.activated.connect (() => {
                    start_add (t);
                    set_active_mode (row);
                });
                add.add_row (row);
            }
            fields_group = add_group (_("Fields"));
            fields_group.visible = false;
        }

        private void start_add (Singularity.Pdf.FieldType t) {
            pending = t;
            if (area_handler != 0) ctx.view.disconnect (area_handler);
            ctx.view.tool = Tool.AREA;
            area_handler = ctx.view.area_picked.connect ((page, area, widget) => {
                var type = pending;
                ctx.run (_("Field added"), (e) => {
                    var r = PageMap.to_pdf (e, page, area);
                    string base_name = type == Singularity.Pdf.FieldType.RADIO ? "Group" : (type == Singularity.Pdf.FieldType.CHECKBOX ? "Check" : "Field");
                    string[] opts = {};
                    if (type == Singularity.Pdf.FieldType.COMBO || type == Singularity.Pdf.FieldType.LIST) opts = { _("Option 1"), _("Option 2"), _("Option 3") };
                    Singularity.Pdf.Forms.create_field (e, page, type, base_name, r, opts);
                });
            });
        }

        private void detect_fields (bool all) {
            var e = ctx.engine ();
            if (e == null) return;
            ctx.view.clear_overlays ();
            detected = new Gee.ArrayList<Singularity.Pdf.DetectedField> ();
            int first = all ? 0 : ctx.current_page;
            int last = all ? e.page_count () - 1 : ctx.current_page;
            for (int p = first; p <= last; p++) {
                foreach (var d in Singularity.Pdf.Forms.detect (e, p)) {
                    detected.add (d);
                    ctx.view.add_overlay (p, PageMap.to_view (e, p, d.rect), "#26a269", true, d.name);
                }
            }
            create_detected.tooltip_text = ngettext ("Create %d Detected Field", "Create %d Detected Fields", detected.size).printf (detected.size);
            detect.description = detected.size > 0 ? ngettext ("%d field found", "%d fields found", detected.size).printf (detected.size) : "";
            create_detected.visible = detected.size > 0;
            if (detected.size == 0) ctx.toast (_("No fillable areas were found"));
        }

        public override void enter () {
            refresh ();
        }

        public override void leave () {
            if (area_handler != 0) ctx.view.disconnect (area_handler);
            area_handler = 0;
            if (ctx.view.tool == Tool.AREA) ctx.view.tool = Tool.SELECT;
            ctx.view.clear_overlays ();
        }

        public override void document_changed () {
            refresh ();
        }

        private void refresh () {
            if (fields_group == null) return;
            fields_group.clear ();
            var e = ctx.engine ();
            if (e == null) return;
            var fields = Singularity.Pdf.Forms.list (e);
            fields_group.visible = fields.size > 0;
            foreach (var f in fields) fields_group.add_row (field_editor (f));
        }

        private Widget field_editor (Singularity.Pdf.FieldInfo f) {
            string name = f.name;
            var exp = new ExpanderRow (f.name, type_name (f.type));
            var rename = new EntryRow (_("Name"));
            rename.text = f.partial;
            exp.add_row (rename);
            var tip = new EntryRow (_("Tooltip"));
            tip.text = f.tooltip;
            exp.add_row (tip);
            var required = new SwitchRow (_("Required"), null, f.required);
            exp.add_row (required);
            var readonly = new SwitchRow (_("Read Only"), null, f.read_only);
            exp.add_row (readonly);
            SwitchRow? multi = null;
            SpinRow? maxlen = null;
            EntryRow? options = null;
            EntryRow? calc = null;
            SelectionRow? format = null;
            if (f.type == Singularity.Pdf.FieldType.TEXT) {
                multi = new SwitchRow (_("Multiple Lines"), null, f.multiline);
                exp.add_row (multi);
                maxlen = new SpinRow (_("Maximum Characters"), _("0 means no limit"), 0, 10000, 1, f.max_len);
                exp.add_row (maxlen);
                format = new SelectionRow (_("Format"), { _("None"), _("Number"), _("Currency"), _("Percent"), _("Date") }, format_label (f.format_js));
                exp.add_row (format);
                calc = new HintEntryRow (_("Calculation"), _("For example Qty * Price"));
                calc.text = calc_summary (f.calculate_js);
                exp.add_row (calc);
            }
            if (f.type == Singularity.Pdf.FieldType.COMBO || f.type == Singularity.Pdf.FieldType.LIST) {
                options = new HintEntryRow (_("Options"), _("Separated by commas"));
                options.text = string.joinv (", ", f.option_labels);
                exp.add_row (options);
            }
            var apply = new ActionRow (_("Apply Changes"), null, "object-select-symbolic");
            apply.activated.connect (() => {
                string new_name = rename.text.strip ();
                string tooltip = tip.text;
                bool req = required.active, ro = readonly.active;
                bool? ml = multi != null ? (bool?) multi.active : null;
                int ml_len = maxlen != null ? (int) maxlen.value : -1;
                string[]? opts = null;
                if (options != null) {
                    string[] parts = {};
                    foreach (var p in options.text.split (",")) if (p.strip () != "") parts += p.strip ();
                    opts = parts;
                }
                string fmt = format != null ? format.current_value : "";
                string formula = calc != null ? calc.text.strip () : "";
                ctx.run (_("Field updated"), (e) => {
                    var fi = Singularity.Pdf.Forms.find (e, name);
                    if (fi == null) return;
                    Singularity.Pdf.Forms.set_properties (e, fi, new_name != fi.partial ? new_name : null, tooltip, req, ro, ml, ml_len, opts);
                    if (format != null) Singularity.Pdf.Forms.set_script (e, fi, "F", format_js (fmt));
                    if (calc != null) Singularity.Pdf.Forms.set_script (e, fi, "C", formula == "" ? "" : calc_js (formula));
                    var refreshed = Singularity.Pdf.Forms.find (e, new_name != "" ? rename_full (name, new_name) : name);
                    if (refreshed != null) Singularity.Pdf.Forms.generate_appearance (e, refreshed);
                    Singularity.Pdf.Forms.recalculate (e);
                });
            });
            exp.add_row (apply);
            var del = new ActionRow (_("Delete Field"), null, "user-trash-symbolic");
            del.activated.connect (() => ctx.run (_("Field deleted"), (e) => {
                var fi = Singularity.Pdf.Forms.find (e, name);
                if (fi != null) Singularity.Pdf.Forms.remove_field (e, fi);
            }));
            exp.add_row (del);
            return exp;
        }

        private static string rename_full (string old_full, string partial) {
            int dot = old_full.last_index_of_char ('.');
            return dot >= 0 ? old_full.substring (0, dot + 1) + partial : partial;
        }

        private static string type_name (Singularity.Pdf.FieldType t) {
            switch (t) {
                case Singularity.Pdf.FieldType.TEXT: return _("Text Field");
                case Singularity.Pdf.FieldType.CHECKBOX: return _("Check Box");
                case Singularity.Pdf.FieldType.RADIO: return _("Radio Buttons");
                case Singularity.Pdf.FieldType.COMBO: return _("Drop-Down List");
                case Singularity.Pdf.FieldType.LIST: return _("List Box");
                case Singularity.Pdf.FieldType.SIGNATURE: return _("Signature Field");
                case Singularity.Pdf.FieldType.PUSHBUTTON: return _("Button");
                default: return _("Field");
            }
        }

        private static string format_label (string js) {
            if (js.contains ("AFPercent_Format")) return _("Percent");
            if (js.contains ("AFDate")) return _("Date");
            if (js.contains ("AFNumber_Format") && js.contains ("\"€\"")) return _("Currency");
            if (js.contains ("AFNumber_Format")) return _("Number");
            return _("None");
        }

        private static string format_js (string label) {
            if (label == _("Number")) return "AFNumber_Format(2, 0, 0, 0, \"\", true);";
            if (label == _("Currency")) return "AFNumber_Format(2, 0, 0, 0, \"€\", true);";
            if (label == _("Percent")) return "AFPercent_Format(0, 0);";
            if (label == _("Date")) return "AFDate_FormatEx(\"dd/mm/yyyy\");";
            return "";
        }

        private static string calc_summary (string js) {
            if (js == "") return "";
            int i = js.index_of ("event.value =");
            if (i < 0) return js;
            string expr = js.substring (i + 13).strip ();
            if (expr.has_suffix (";")) expr = expr.substring (0, expr.length - 1);
            try {
                var re = new Regex ("this\\.getField\\(\"([^\"]+)\"\\)\\.value");
                expr = re.replace (expr, -1, 0, "\\1");
            } catch (RegexError e) {
            }
            return expr;
        }

        public static string calc_js (string formula) {
            string f = formula.strip ();
            string up = f.up ();
            foreach (var fn in new string[] { "SUM", "AVG", "PRD", "MIN", "MAX" }) {
                if (up.has_prefix (fn + "(") && f.has_suffix (")")) {
                    string inner = f.substring (fn.length + 1, f.length - fn.length - 2);
                    string[] names = {};
                    foreach (var p in inner.split (",")) names += "\"" + p.strip ().replace ("\"", "") + "\"";
                    return "AFSimple_Calculate(\"%s\", new Array(%s));".printf (fn, string.joinv (", ", names));
                }
            }
            try {
                var re = new Regex ("([A-Za-z_][A-Za-z0-9_.]*)");
                string expr = re.replace_eval (f, -1, 0, 0, (info, result) => {
                    string word = info.fetch (1);
                    if (word.has_prefix ("Math.")) result.append (word);
                    else result.append ("this.getField(\"%s\").value".printf (word));
                    return false;
                });
                return "event.value = %s;".printf (expr);
            } catch (RegexError e) {
                return "";
            }
        }
    }
}
