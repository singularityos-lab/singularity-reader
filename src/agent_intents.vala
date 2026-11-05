namespace Singularity.Apps.Reader {

    internal class ReaderIntents : Object {
        private const string NONE = "{\"type\":\"object\",\"properties\":{}}";
        private const string[] MODES = { "normal", "dim", "dark", "sepia", "night" };
        private const int TEXT_LIMIT = 40000;

        private static string text (Json.Object args, string key) {
            return args.has_member (key) ? args.get_string_member (key) : "";
        }

        private static ReaderWindow window (ReaderApp app) throws Error {
            var w = app.get_active_window () as ReaderWindow;
            if (w == null) {
                foreach (var any in app.get_windows ()) {
                    w = any as ReaderWindow;
                    if (w != null) break;
                }
            }
            if (w == null || w.document == null) throw new IOError.NOT_FOUND ("no document is open; use reader_open first");
            return w;
        }

        private static Json.Node describe (ReaderApp app, ReaderWindow w) {
            var b = new Json.Builder ();
            b.begin_object ();
            var doc = w.document;
            b.set_member_name ("path").add_string_value (doc.file.get_path () ?? doc.file.get_uri ());
            b.set_member_name ("title").add_string_value (doc.title ());
            b.set_member_name ("pages").add_int_value (doc.n_pages);
            b.set_member_name ("page").add_int_value (w.document_view.current_page + 1);
            b.set_member_name ("zoom_percent").add_int_value ((int) Math.round (w.document_view.zoom * 100));
            b.set_member_name ("page_mode").add_string_value (app.settings.get_string ("page-mode"));
            b.set_member_name ("modified").add_boolean_value (doc.modified);
            b.end_object ();
            return b.get_root ();
        }

        private static int page_arg (Json.Object args, string key, int fallback) {
            return args.has_member (key) ? (int) args.get_int_member (key) : fallback;
        }

        internal static void install (ReaderApp app) {
            var agent = app.agent;
            agent.add_intent ("reader_documents", "List the open PDF documents with their path, title, page count, current page (from 1), zoom and page colors.", NONE,
                Singularity.AppIntentRisk.READ, (args) => {
                    var arr = new Json.Array ();
                    foreach (var any in app.get_windows ()) {
                        var w = any as ReaderWindow;
                        if (w != null && w.document != null) arr.add_element (describe (app, w));
                    }
                    var node = new Json.Node (Json.NodeType.ARRAY);
                    node.set_array (arr);
                    return node;
                });
            agent.add_intent ("reader_open", "Open a PDF file in Reader.",
                "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}",
                Singularity.AppIntentRisk.READ, (args) => {
                    var file = File.new_for_path (text (args, "path"));
                    if (!file.query_exists ()) throw new IOError.NOT_FOUND ("%s does not exist".printf (text (args, "path")));
                    app.open_file (file, null);
                    foreach (var any in app.get_windows ()) {
                        var w = any as ReaderWindow;
                        if (w != null && w.document != null && w.document.file.equal (file)) {
                            var node = describe (app, w);
                            node.get_object ().set_boolean_member ("verified", true);
                            return node;
                        }
                    }
                    var b = new Json.Builder ();
                    b.begin_object ();
                    b.set_member_name ("verified").add_boolean_value (false);
                    b.set_member_name ("reason").add_string_value ("the document did not open, it may be damaged or need a password");
                    b.end_object ();
                    return b.get_root ();
                });
            agent.add_intent ("reader_read", "Read the text of pages of the open document, from and to counted from 1. Long documents are cut, read them in ranges.",
                "{\"type\":\"object\",\"properties\":{\"from\":{\"type\":\"integer\"},\"to\":{\"type\":\"integer\"}}}",
                Singularity.AppIntentRisk.READ, (args) => {
                    var w = window (app);
                    var doc = w.document;
                    int from = page_arg (args, "from", 1).clamp (1, doc.n_pages);
                    int to = page_arg (args, "to", doc.n_pages).clamp (from, doc.n_pages);
                    var arr = new Json.Array ();
                    int used = 0;
                    int last = from - 1;
                    for (int i = from; i <= to && used < TEXT_LIMIT; i++) {
                        string t = doc.flowing_text (i - 1);
                        if (used + t.length > TEXT_LIMIT) t = t.substring (0, TEXT_LIMIT - used);
                        used += t.length;
                        var o = new Json.Object ();
                        o.set_int_member ("page", i);
                        o.set_string_member ("text", t);
                        arr.add_object_element (o);
                        last = i;
                    }
                    var node = describe (app, w);
                    node.get_object ().set_array_member ("text", arr);
                    if (last < to) node.get_object ().set_int_member ("continue_from", last + 1);
                    return node;
                });
            agent.add_intent ("reader_find", "Find text in the open document. Answers the pages that contain it and how many times.",
                "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}",
                Singularity.AppIntentRisk.READ, (args) => {
                    var w = window (app);
                    string query = text (args, "text");
                    if (query == "") throw new IOError.INVALID_ARGUMENT ("text is empty");
                    var arr = new Json.Array ();
                    int total = 0;
                    for (int i = 0; i < w.document.n_pages; i++) {
                        uint n = w.document.page (i).find_text_with_options (query, Poppler.FindFlags.MULTILINE).length ();
                        if (n == 0) continue;
                        var o = new Json.Object ();
                        o.set_int_member ("page", i + 1);
                        o.set_int_member ("count", n);
                        arr.add_object_element (o);
                        total += (int) n;
                    }
                    var node = describe (app, w);
                    node.get_object ().set_int_member ("total", total);
                    node.get_object ().set_array_member ("matches", arr);
                    return node;
                });
            agent.add_async_intent ("reader_go_to", "Show a page of the open document, counted from 1. Answers the page read back from the view.",
                "{\"type\":\"object\",\"properties\":{\"page\":{\"type\":\"integer\"}},\"required\":[\"page\"]}",
                Singularity.AppIntentRisk.READ, (args, reply) => {
                    ReaderWindow w;
                    try {
                        w = window (app);
                    } catch (Error e) {
                        reply (null, e);
                        return;
                    }
                    int target = page_arg (args, "page", 1);
                    if (target < 1 || target > w.document.n_pages) {
                        reply (null, new IOError.INVALID_ARGUMENT ("no page %d, the document has %d".printf (target, w.document.n_pages)));
                        return;
                    }
                    w.document_view.go_to (target - 1);
                    Timeout.add (400, () => {
                        var node = describe (app, w);
                        node.get_object ().set_boolean_member ("verified", w.document_view.current_page == target - 1);
                        reply (node, null);
                        return Source.REMOVE;
                    });
                });
            agent.add_intent ("reader_zoom", "Zoom the open document: mode fit-width, fit-page or actual, or percent for a value such as 150.",
                "{\"type\":\"object\",\"properties\":{\"mode\":{\"type\":\"string\",\"enum\":[\"fit-width\",\"fit-page\",\"actual\"]},\"percent\":{\"type\":\"integer\"}}}",
                Singularity.AppIntentRisk.READ, (args) => {
                    var w = window (app);
                    var v = w.document_view;
                    double want = -1;
                    switch (text (args, "mode")) {
                    case "fit-width": v.fit_width (); break;
                    case "fit-page": v.fit_page (); break;
                    case "actual": v.zoom_to (1); want = 1; break;
                    default:
                        if (!args.has_member ("percent")) throw new IOError.INVALID_ARGUMENT ("give mode or percent");
                        want = args.get_int_member ("percent") / 100.0;
                        v.zoom_to (want);
                        break;
                    }
                    var node = describe (app, w);
                    node.get_object ().set_boolean_member ("verified", want < 0 || Math.fabs (v.zoom - want) < 0.02);
                    return node;
                });
            agent.add_intent ("reader_page_colors", "Read or set how pages are tinted while reading: normal, dim (lower brightness), dark (dark page with light text, colors keep their hue), sepia or night (dark and warm). Without mode it only reads the current one.",
                "{\"type\":\"object\",\"properties\":{\"mode\":{\"type\":\"string\",\"enum\":[\"normal\",\"dim\",\"dark\",\"sepia\",\"night\"]}}}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    string mode = text (args, "mode");
                    if (mode != "") {
                        if (!(mode in MODES)) throw new IOError.INVALID_ARGUMENT ("mode must be one of %s".printf (string.joinv (", ", MODES)));
                        app.settings.set_string ("page-mode", mode);
                    }
                    var b = new Json.Builder ();
                    b.begin_object ();
                    string now = app.settings.get_string ("page-mode");
                    b.set_member_name ("page_mode").add_string_value (now);
                    if (mode != "") b.set_member_name ("verified").add_boolean_value (now == mode);
                    b.end_object ();
                    return b.get_root ();
                });
        }
    }
}
