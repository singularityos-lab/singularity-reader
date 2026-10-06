namespace Singularity.Apps.Reader {

    public class LayoutWord : Object {
        public string text = "";
        public double x1;
        public double y1;
        public double x2;
        public double y2;
        public double size;
        public bool bold;
        public bool italic;
        public string color = "000000";
    }

    public class LayoutLine : Object {
        public Gee.ArrayList<LayoutWord> words = new Gee.ArrayList<LayoutWord> ();
        public double x1 = double.MAX;
        public double y1 = double.MAX;
        public double x2 = -double.MAX;
        public double y2 = -double.MAX;

        public void add (LayoutWord w) {
            words.add (w);
            x1 = double.min (x1, w.x1);
            y1 = double.min (y1, w.y1);
            x2 = double.max (x2, w.x2);
            y2 = double.max (y2, w.y2);
        }

        public double size () {
            double s = 0;
            foreach (var w in words) s = double.max (s, w.size);
            return s;
        }

        public string text () {
            var b = new StringBuilder ();
            foreach (var w in words) {
                if (b.len > 0) b.append_c (' ');
                b.append (w.text);
            }
            return b.str;
        }

        public Gee.ArrayList<Gee.ArrayList<LayoutWord>> cells () {
            var result = new Gee.ArrayList<Gee.ArrayList<LayoutWord>> ();
            Gee.ArrayList<LayoutWord>? cur = null;
            LayoutWord? prev = null;
            foreach (var w in words) {
                double gap = prev != null ? w.x1 - prev.x2 : double.MAX;
                if (cur == null || gap > double.max (w.size, prev.size) * 1.2) {
                    cur = new Gee.ArrayList<LayoutWord> ();
                    result.add (cur);
                }
                cur.add (w);
                prev = w;
            }
            return result;
        }
    }

    public enum BlockKind {
        PARAGRAPH,
        HEADING1,
        HEADING2,
        TABLE,
        IMAGE
    }

    public class LayoutBlock : Object {
        public BlockKind kind = BlockKind.PARAGRAPH;
        public Gee.ArrayList<LayoutLine> lines = new Gee.ArrayList<LayoutLine> ();
        public Gee.ArrayList<Gee.ArrayList<string>> rows = new Gee.ArrayList<Gee.ArrayList<string>> ();
        public uint8[]? png = null;
        public int image_width;
        public int image_height;
        public double width_pt;
        public double height_pt;
        public double top;

        public double size () {
            double s = 0;
            foreach (var l in lines) s = double.max (s, l.size ());
            return s;
        }

        public string text () {
            var b = new StringBuilder ();
            foreach (var l in lines) {
                if (b.len > 0) b.append_c (' ');
                b.append (l.text ());
            }
            return b.str;
        }

        public Gee.ArrayList<LayoutWord> words () {
            var list = new Gee.ArrayList<LayoutWord> ();
            foreach (var l in lines) list.add_all (l.words);
            return list;
        }
    }

    public class PageLayout : Object {
        public double width;
        public double height;
        public Gee.ArrayList<LayoutLine> lines = new Gee.ArrayList<LayoutLine> ();
        public Gee.ArrayList<LayoutBlock> blocks = new Gee.ArrayList<LayoutBlock> ();

        private static bool is_bold (string font) {
            string l = font.down ();
            return l.contains ("bold") || l.contains ("black") || l.contains ("heavy") || l.contains ("semibold");
        }

        private static bool is_italic (string font) {
            string l = font.down ();
            return l.contains ("italic") || l.contains ("oblique");
        }

        public static PageLayout build (Poppler.Page page, bool with_images) {
            var layout = new PageLayout ();
            page.get_size (out layout.width, out layout.height);
            string text = page.get_text () ?? "";
            Poppler.Rectangle[] rects;
            if (!page.get_text_layout (out rects)) rects = new Poppler.Rectangle[0];
            var attrs = new Gee.ArrayList<Poppler.TextAttributes> ();
            foreach (var a in page.get_text_attributes ()) attrs.add (a.copy ());
            int char_index = 0;
            int byte_index = 0;
            unichar c;
            LayoutWord? word = null;
            LayoutLine? line = null;
            int attr_pos = 0;
            while (text.get_next_char (ref byte_index, out c)) {
                int ci = char_index++;
                if (c == '\n' || c == '\r') {
                    if (word != null && line != null) line.add (word);
                    word = null;
                    if (line != null && line.words.size > 0) layout.lines.add (line);
                    line = null;
                    continue;
                }
                if (ci >= rects.length) break;
                var r = rects[ci];
                if (c.isspace ()) {
                    if (word != null && line != null) line.add (word);
                    word = null;
                    continue;
                }
                while (attr_pos < attrs.size && attrs[attr_pos].end_index < ci) attr_pos++;
                Poppler.TextAttributes? attr = attr_pos < attrs.size && attrs[attr_pos].start_index <= ci ? attrs[attr_pos] : null;
                if (line == null) line = new LayoutLine ();
                if (word != null && (r.x1 - word.x2 > (r.y2 - r.y1) * 0.25 || (r.y1 - word.y1).abs () > (r.y2 - r.y1) * 0.6)) {
                    line.add (word);
                    word = null;
                }
                if (word == null) {
                    word = new LayoutWord ();
                    word.x1 = r.x1;
                    word.y1 = r.y1;
                    word.x2 = r.x2;
                    word.y2 = r.y2;
                    word.size = attr != null ? attr.font_size : (r.y2 - r.y1);
                    if (attr != null) {
                        word.bold = is_bold (attr.font_name ?? "");
                        word.italic = is_italic (attr.font_name ?? "");
                        word.color = "%02X%02X%02X".printf (attr.color.red >> 8, attr.color.green >> 8, attr.color.blue >> 8);
                    }
                }
                word.text += c.to_string ();
                word.x1 = double.min (word.x1, r.x1);
                word.y1 = double.min (word.y1, r.y1);
                word.x2 = double.max (word.x2, r.x2);
                word.y2 = double.max (word.y2, r.y2);
            }
            if (word != null && line != null) line.add (word);
            if (line != null && line.words.size > 0) layout.lines.add (line);
            layout.merge_lines ();
            layout.group ();
            if (with_images) layout.add_images (page);
            layout.blocks.sort ((a, b) => a.top < b.top ? -1 : (a.top > b.top ? 1 : 0));
            return layout;
        }

        private void merge_lines () {
            var merged = new Gee.ArrayList<LayoutLine> ();
            foreach (var l in lines) {
                LayoutLine? target = null;
                if (merged.size > 0) {
                    var last = merged[merged.size - 1];
                    double overlap = double.min (last.y2, l.y2) - double.max (last.y1, l.y1);
                    if (overlap > (l.y2 - l.y1) * 0.5 && l.x1 >= last.x2 - 1) target = last;
                }
                if (target == null) {
                    merged.add (l);
                } else {
                    foreach (var w in l.words) target.add (w);
                }
            }
            lines = merged;
        }

        private bool is_table_row (LayoutLine l) {
            return l.cells ().size >= 3;
        }

        private static bool aligned (Gee.List<double?> a, Gee.List<double?> b, double tolerance) {
            if (a.size != b.size) return false;
            for (int i = 0; i < a.size; i++) {
                if ((a[i] - b[i]).abs () > tolerance) return false;
            }
            return true;
        }

        private static Gee.ArrayList<double?> starts (LayoutLine l) {
            var s = new Gee.ArrayList<double?> ();
            foreach (var cell in l.cells ()) s.add (cell[0].x1);
            return s;
        }

        private void group () {
            int i = 0;
            while (i < lines.size) {
                var l = lines[i];
                if (is_table_row (l)) {
                    int j = i + 1;
                    var ref_starts = starts (l);
                    while (j < lines.size && is_table_row (lines[j]) && aligned (ref_starts, starts (lines[j]), double.max (8, l.size () * 2))) j++;
                    if (j - i >= 2) {
                        var block = new LayoutBlock ();
                        block.kind = BlockKind.TABLE;
                        block.top = l.y1;
                        for (int k = i; k < j; k++) {
                            block.lines.add (lines[k]);
                            var row = new Gee.ArrayList<string> ();
                            foreach (var cell in lines[k].cells ()) {
                                var b = new StringBuilder ();
                                foreach (var w in cell) {
                                    if (b.len > 0) b.append_c (' ');
                                    b.append (w.text);
                                }
                                row.add (b.str);
                            }
                            block.rows.add (row);
                        }
                        blocks.add (block);
                        i = j;
                        continue;
                    }
                }
                LayoutBlock? current = null;
                if (blocks.size > 0) {
                    var last = blocks[blocks.size - 1];
                    if (last.kind == BlockKind.PARAGRAPH && last.lines.size > 0) {
                        var prev = last.lines[last.lines.size - 1];
                        double gap = l.y1 - prev.y2;
                        double sz = double.max (prev.size (), l.size ());
                        if (gap >= -sz * 0.3 && gap < sz * 0.8 && (prev.size () - l.size ()).abs () < sz * 0.15) current = last;
                    }
                }
                if (current == null) {
                    current = new LayoutBlock ();
                    current.top = l.y1;
                    blocks.add (current);
                }
                current.lines.add (l);
                i++;
            }
        }

        private void add_images (Poppler.Page page) {
            foreach (var m in page.get_image_mapping ()) {
                var surface = page.get_image (m.image_id);
                if (surface == null) continue;
                if (surface.get_type () != Cairo.SurfaceType.IMAGE) continue;
                var img = (Cairo.ImageSurface) surface;
                var buffer = new ByteArray ();
                img.write_to_png_stream ((data) => {
                    buffer.append (data);
                    return Cairo.Status.SUCCESS;
                });
                if (buffer.len == 0) continue;
                var block = new LayoutBlock ();
                block.kind = BlockKind.IMAGE;
                block.png = buffer.steal ();
                block.image_width = img.get_width ();
                block.image_height = img.get_height ();
                double x1 = double.min (m.area.x1, m.area.x2), x2 = double.max (m.area.x1, m.area.x2);
                double y1 = double.min (m.area.y1, m.area.y2), y2 = double.max (m.area.y1, m.area.y2);
                block.width_pt = double.max (1, x2 - x1);
                block.height_pt = double.max (1, y2 - y1);
                block.top = y1;
                blocks.add (block);
            }
        }

        public static void classify (Gee.List<PageLayout> pages) {
            var sizes = new Gee.ArrayList<double?> ();
            foreach (var p in pages) {
                foreach (var b in p.blocks) {
                    if (b.kind != BlockKind.PARAGRAPH) continue;
                    foreach (var w in b.words ()) sizes.add (w.size);
                }
            }
            if (sizes.size == 0) return;
            sizes.sort ((a, b) => a < b ? -1 : (a > b ? 1 : 0));
            double median = sizes[sizes.size / 2];
            foreach (var p in pages) {
                foreach (var b in p.blocks) {
                    if (b.kind != BlockKind.PARAGRAPH || b.lines.size > 3) continue;
                    double s = b.size ();
                    if (s >= median * 1.5) b.kind = BlockKind.HEADING1;
                    else if (s >= median * 1.18) b.kind = BlockKind.HEADING2;
                }
            }
        }

        public static bool parse_number (string raw, out double value) {
            value = 0;
            string t = raw.strip ().replace (" ", "").replace (" ", "");
            foreach (var cur in new string[] { "€", "$", "£", "%" }) t = t.replace (cur, "");
            if (t == "") return false;
            int comma = t.last_index_of_char (','), dot = t.last_index_of_char ('.');
            if (comma >= 0 && dot >= 0) {
                if (comma > dot) t = t.replace (".", "").replace (",", ".");
                else t = t.replace (",", "");
            } else if (comma >= 0) {
                int count = t.split (",").length - 1;
                if (count == 1 && t.length - comma - 1 != 3) t = t.replace (",", ".");
                else t = t.replace (",", "");
            }
            for (int i = 0; i < t.length; i++) {
                char ch = t[i];
                if (!(ch.isdigit () || ch == '.' || (i == 0 && (ch == '-' || ch == '+')))) return false;
            }
            return double.try_parse (t, out value);
        }
    }
}
