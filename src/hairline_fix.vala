namespace Singularity.Apps.Reader {

    public class HairlineFix {
        private class FillColor {
            public string space = "";
            public string color = "0 g";

            public FillColor copy () {
                var c = new FillColor ();
                c.space = space;
                c.color = color;
                return c;
            }
        }

        private class Token {
            public int start;
            public int end;
            public string text;
            public bool is_number;
        }

        public static uint8[]? apply (uint8[] data, string? password = null) {
            try {
                var doc = Singularity.Pdf.Document.open_bytes (data, password ?? "");
                bool changed = false;
                int pages = doc.page_count ();
                for (int i = 0; i < pages; i++) {
                    uint8[] content = doc.page_content (i);
                    uint8[]? fixed_content = rewrite (content);
                    if (fixed_content != null) {
                        doc.set_page_content (i, fixed_content);
                        changed = true;
                    }
                }
                if (!changed) return null;
                return doc.save ();
            } catch (Error e) {
                debug ("Reader: hairline fix skipped: %s", e.message);
                return null;
            }
        }

        public static uint8[]? rewrite (uint8[] content) {
            var tokens = tokenize (content);
            var output = new ByteArray ();
            var stack = new Gee.ArrayList<FillColor> ();
            var fill = new FillColor ();
            int copied = 0;
            bool changed = false;
            for (int i = 0; i < tokens.size; i++) {
                var t = tokens[i];
                if (t.is_number) continue;
                switch (t.text) {
                    case "q":
                        stack.add (fill.copy ());
                        break;
                    case "Q":
                        if (stack.size > 0) fill = stack.remove_at (stack.size - 1);
                        break;
                    case "g":
                    case "rg":
                    case "k":
                        fill.space = "";
                        fill.color = operands (content, tokens, i) + t.text.up ();
                        break;
                    case "cs":
                        fill.space = operands (content, tokens, i) + "CS";
                        fill.color = "";
                        break;
                    case "sc":
                    case "scn":
                        fill.color = operands (content, tokens, i) + t.text.up ();
                        break;
                    case "re":
                        if (i < 4 || i + 1 >= tokens.size) break;
                        var next = tokens[i + 1];
                        if (next.is_number || !(next.text == "f" || next.text == "F" || next.text == "f*")) break;
                        bool numbers = true;
                        for (int k = i - 4; k < i; k++) if (!tokens[k].is_number) numbers = false;
                        if (!numbers) break;
                        double x = double.parse (tokens[i - 4].text);
                        double y = double.parse (tokens[i - 3].text);
                        double w = double.parse (tokens[i - 2].text);
                        double h = double.parse (tokens[i - 1].text);
                        if (w != 0 && h != 0) break;
                        if (w == 0 && h == 0) break;
                        output.append (content[copied:tokens[i - 4].start]);
                        var line = "q %s %s [] 0 d 0 J 0 w %s %s m %s %s l S Q".printf (
                            fill.space, fill.color, num (x), num (y), num (x + w), num (y + h));
                        output.append (line.data);
                        copied = next.end;
                        i++;
                        changed = true;
                        break;
                    default:
                        break;
                }
            }
            if (!changed) return null;
            output.append (content[copied:content.length]);
            return output.steal ();
        }

        private static string num (double v) {
            char[] buf = new char[double.DTOSTR_BUF_SIZE];
            return v.format (buf, "%.4f");
        }

        private static string operands (uint8[] content, Gee.ArrayList<Token> tokens, int index) {
            int first = index;
            while (first > 0 && (tokens[first - 1].is_number || tokens[first - 1].text.has_prefix ("/"))) first--;
            if (first == index) return "";
            var sb = new StringBuilder ();
            for (int k = first; k < index; k++) sb.append (tokens[k].text).append_c (' ');
            return sb.str;
        }

        private static bool is_space (uint8 c) {
            return c == ' ' || c == '\n' || c == '\r' || c == '\t' || c == '\f' || c == 0;
        }

        private static bool is_delimiter (uint8 c) {
            return c == '(' || c == ')' || c == '<' || c == '>' || c == '[' || c == ']' || c == '{' || c == '}' || c == '/' || c == '%';
        }

        private static Gee.ArrayList<Token> tokenize (uint8[] s) {
            var list = new Gee.ArrayList<Token> ();
            int n = s.length;
            int i = 0;
            while (i < n) {
                uint8 c = s[i];
                if (is_space (c)) {
                    i++;
                    continue;
                }
                int start = i;
                if (c == '%') {
                    while (i < n && s[i] != '\n' && s[i] != '\r') i++;
                    continue;
                }
                if (c == '(') {
                    int depth = 0;
                    while (i < n) {
                        if (s[i] == '\\') {
                            i += 2;
                            continue;
                        }
                        if (s[i] == '(') depth++;
                        else if (s[i] == ')') {
                            depth--;
                            if (depth == 0) {
                                i++;
                                break;
                            }
                        }
                        i++;
                    }
                    add (list, s, start, i, false);
                    continue;
                }
                if (c == '<' && i + 1 < n && s[i + 1] == '<') {
                    i += 2;
                    add (list, s, start, i, false);
                    continue;
                }
                if (c == '>' && i + 1 < n && s[i + 1] == '>') {
                    i += 2;
                    add (list, s, start, i, false);
                    continue;
                }
                if (c == '<') {
                    while (i < n && s[i] != '>') i++;
                    i++;
                    add (list, s, start, int.min (i, n), false);
                    continue;
                }
                if (c == '[' || c == ']' || c == '{' || c == '}') {
                    i++;
                    add (list, s, start, i, false);
                    continue;
                }
                i++;
                while (i < n && !is_space (s[i]) && !is_delimiter (s[i])) i++;
                string text = slice (s, start, i);
                bool number = text.length > 0 && (text[0].isdigit () || text[0] == '-' || text[0] == '+' || text[0] == '.');
                add (list, s, start, i, number);
                if (text == "ID") {
                    i++;
                    while (i + 2 < n && !(is_space (s[i]) && s[i + 1] == 'E' && s[i + 2] == 'I' && (i + 3 >= n || is_space (s[i + 3])))) i++;
                    i += 3;
                }
            }
            return list;
        }

        private static string slice (uint8[] s, int start, int end) {
            var sb = new StringBuilder.sized (end - start + 1);
            for (int k = start; k < end; k++) sb.append_c ((char) s[k]);
            return sb.str;
        }

        private static void add (Gee.ArrayList<Token> list, uint8[] s, int start, int end, bool number) {
            var t = new Token ();
            t.start = start;
            t.end = end;
            t.text = slice (s, start, end);
            t.is_number = number;
            list.add (t);
        }
    }
}
