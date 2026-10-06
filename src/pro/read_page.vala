using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Reader {

    public class ReadAloud : Object {
        private static Subprocess? proc = null;

        public static string? program () {
            string? env = Environment.get_variable ("SINGULARITY_TTS");
            if (env != null && env != "") return env;
            foreach (string p in new string[] { "spd-say", "espeak-ng", "espeak", "festival" }) {
                string? path = Environment.find_program_in_path (p);
                if (path != null) return path;
            }
            return null;
        }

        public static bool speaking {
            get { return proc != null; }
        }

        public static void stop () {
            if (proc != null) {
                proc.force_exit ();
                proc = null;
            }
        }

        public static void speak (string text) throws Error {
            stop ();
            string? prog = program ();
            if (prog == null) throw new IOError.NOT_FOUND (_("No speech synthesizer is installed, for example speech-dispatcher or espeak-ng."));
            string name = Path.get_basename (prog);
            string[] argv;
            if (name == "spd-say") argv = { prog, "-w", "-e" };
            else if (name == "festival") argv = { prog, "--tts" };
            else argv = { prog, "--stdin" };
            proc = new Subprocess.newv (argv, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
            var input = proc.get_stdin_pipe ();
            input.write_all (text.data, null);
            input.close ();
            var mine = proc;
            proc.wait_async.begin (null, (o, res) => {
                if (proc == mine) proc = null;
            });
        }
    }

    public class Summarizer : Object {
        public static string[] sentences (string text) {
            string[] result = {};
            var cur = new StringBuilder ();
            int i = 0;
            unichar c;
            string t = text.replace ("-\n", "").replace ("\n", " ");
            while (t.get_next_char (ref i, out c)) {
                cur.append_unichar (c);
                if ((c == '.' || c == '!' || c == '?') && (i >= t.length || t[i] == ' ')) {
                    string s = cur.str.strip ();
                    if (s.char_count () > 25) result += s;
                    cur.truncate ();
                }
            }
            if (cur.str.strip ().char_count () > 25) result += cur.str.strip ();
            return result;
        }

        private static string[] words (string s) {
            string[] w = {};
            foreach (var part in s.down ().split_set (" ,.;:!?()[]\"'«»")) {
                if (part.char_count () > 3) w += part;
            }
            return w;
        }

        public static string[] summarize (string text, int count) {
            var all = sentences (text);
            if (all.length <= count) return all;
            var freq = new Gee.HashMap<string, int> ();
            foreach (var s in all) foreach (var w in words (s)) freq[w] = (freq.has_key (w) ? freq[w] : 0) + 1;
            var scores = new double[all.length];
            for (int i = 0; i < all.length; i++) {
                var ws = words (all[i]);
                double sum = 0;
                foreach (var w in ws) sum += freq[w];
                scores[i] = ws.length > 0 ? sum / Math.sqrt (ws.length) : 0;
                if (i < 3) scores[i] *= 1.2;
            }
            var chosen = new Gee.ArrayList<int> ();
            for (int k = 0; k < count; k++) {
                int best = -1;
                for (int i = 0; i < all.length; i++) {
                    if (chosen.contains (i)) continue;
                    if (best < 0 || scores[i] > scores[best]) best = i;
                }
                if (best >= 0) chosen.add (best);
            }
            chosen.sort ((a, b) => a - b);
            string[] result = {};
            foreach (int i in chosen) result += all[i];
            return result;
        }
    }

    public class ReadPage : ToolPage {
        private Label summary;
        private Button speak_button;

        public ReadPage () {
            base (_("Read and Review"), "audio-speakers-symbolic");
        }

        public override void build () {
            var aloud = add_group (_("Read Aloud"));
            var page = new ActionRow (_("Read This Page"), null, "media-playback-start-symbolic");
            page.activated.connect (() => speak (ctx.document.text (ctx.current_page)));
            aloud.add_row (page);
            var from = new ActionRow (_("Read from This Page to the End"), null, "media-playback-start-symbolic");
            from.activated.connect (() => {
                var sb = new StringBuilder ();
                for (int p = ctx.current_page; p < ctx.document.n_pages; p++) sb.append (ctx.document.text (p)).append ("\n");
                speak (sb.str);
            });
            aloud.add_row (from);
            var selection = new ActionRow (_("Read the Selection"), null, "media-playback-start-symbolic");
            selection.activated.connect (() => speak (ctx.view.selection_text ()));
            aloud.add_row (selection);
            speak_button = header_button (aloud, _("Stop"));
            speak_button.tooltip_text = _("Stop Reading");
            speak_button.clicked.connect (() => {
                ReadAloud.stop ();
                speak_button.sensitive = false;
            });
            speak_button.sensitive = false;
            var mode = add_group (_("Reading Mode"));
            var reflow = new ActionRow (_("Show as Flowing Text"), _("One column that adapts to the window, easier on small screens"), "view-paged-symbolic");
            reflow.activated.connect (() => ctx.window.show_reflow ());
            mode.add_row (reflow);
            var sum = add_group (_("Summary"), _("Picks the key sentences on this computer, nothing is sent anywhere."));
            var make = new ActionRow (_("Summarize the Document"), null, "view-list-symbolic");
            sum.add_row (make);
            summary = text_row (sum);
            summary.get_parent ().visible = false;
            make.activated.connect (() => {
                var sb = new StringBuilder ();
                for (int p = 0; p < ctx.document.n_pages; p++) sb.append (ctx.document.text (p)).append ("\n");
                int n = (int) double.max (3, double.min (10, ctx.document.n_pages * 1.5));
                var lines = Summarizer.summarize (sb.str, n);
                summary.label = lines.length == 0 ? _("There is not enough text to summarize.") : "• " + string.joinv ("\n• ", lines);
                summary.get_parent ().visible = true;
            });
            var review = add_group (_("Shared Review"));
            var send = new ActionRow (_("Send for Review to an Online Account…"), _("Nextcloud, Google Drive, OneDrive and others set up in Settings"), "document-send-symbolic");
            send.activated.connect (() => CloudActions.save_document (ctx.window));
            review.add_row (send);
            var merge = new ActionRow (_("Merge Comments from a Reviewer's Copy…"), null, "edit-paste-symbolic");
            merge.activated.connect (() => merge_copy.begin ());
            review.add_row (merge);
        }

        private void speak (string text) {
            if (text.strip () == "") {
                ctx.toast (_("There is no text to read here"));
                return;
            }
            try {
                ReadAloud.speak (text);
                speak_button.sensitive = true;
            } catch (Error e) {
                ctx.error_dialog (_("The text cannot be read aloud"), e.message);
            }
        }

        private async void merge_copy () {
            var file = yield ctx.choose_open (_("Choose the Reviewer's Copy"), "application/pdf");
            if (file == null) return;
            int count = 0;
            ctx.run ("", (e) => {
                var other = Singularity.Pdf.Document.open_file (file.get_path ());
                string? other_name = file.get_basename ();
                string xfdf = Singularity.Pdf.Annotations.export_xfdf (other, other_name != null ? other_name : "");
                count = Singularity.Pdf.Annotations.import_xfdf (e, xfdf);
            });
            ctx.toast (ngettext ("%d comment merged", "%d comments merged", count).printf (count));
        }

        public override void leave () {
        }
    }
}
