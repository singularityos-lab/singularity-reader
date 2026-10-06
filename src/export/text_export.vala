namespace Singularity.Apps.Reader {

    public class TextExport : Object {
        private const string ODF_NS = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:draw=\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\" xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\"";

        public static string esc (string s) {
            var b = new StringBuilder ();
            int i = 0;
            unichar c;
            while (s.get_next_char (ref i, out c)) {
                if (c < 0x20 && c != '\t' && c != '\n') continue;
                if (c == 0xfffe || c == 0xffff) continue;
                switch (c) {
                    case '&': b.append ("&amp;"); break;
                    case '<': b.append ("&lt;"); break;
                    case '>': b.append ("&gt;"); break;
                    case '"': b.append ("&quot;"); break;
                    default: b.append_unichar (c); break;
                }
            }
            return b.str;
        }

        private class Run {
            public string text = "";
            public bool bold;
            public bool italic;
            public string color = "000000";
            public double size;
        }

        private static Gee.ArrayList<Run> runs (LayoutBlock block) {
            var list = new Gee.ArrayList<Run> ();
            Run? cur = null;
            foreach (var w in block.words ()) {
                if (cur != null && cur.bold == w.bold && cur.italic == w.italic && cur.color == w.color && (cur.size - w.size).abs () < 0.6) {
                    cur.text += " " + w.text;
                    continue;
                }
                if (cur != null) cur.text += " ";
                cur = new Run ();
                cur.text = w.text;
                cur.bold = w.bold;
                cur.italic = w.italic;
                cur.color = w.color;
                cur.size = w.size;
                list.add (cur);
            }
            return list;
        }

        private static int columns (LayoutBlock table) {
            int n = 0;
            foreach (var r in table.rows) n = int.max (n, r.size);
            return n;
        }

        private static string docx_run (Run r, bool heading) {
            var b = new StringBuilder ("<w:r><w:rPr>");
            if (r.bold && !heading) b.append ("<w:b/>");
            if (r.italic) b.append ("<w:i/>");
            if (r.color != "000000") b.append_printf ("<w:color w:val=\"%s\"/>", r.color);
            if (!heading && r.size > 0) b.append_printf ("<w:sz w:val=\"%d\"/>", (int) Math.round (r.size * 2));
            b.append_printf ("</w:rPr><w:t xml:space=\"preserve\">%s</w:t></w:r>", esc (r.text));
            return b.str;
        }

        public static uint8[] docx (Gee.List<PageLayout> pages) throws Error {
            var zip = new ZipWriter ();
            var body = new StringBuilder ();
            var rels = new StringBuilder ();
            int image_id = 0;
            for (int p = 0; p < pages.size; p++) {
                if (p > 0) body.append ("<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>");
                foreach (var block in pages[p].blocks) {
                    switch (block.kind) {
                        case BlockKind.TABLE:
                            int cols = columns (block);
                            body.append ("<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"0\" w:type=\"auto\"/></w:tblPr><w:tblGrid>");
                            for (int c = 0; c < cols; c++) body.append_printf ("<w:gridCol w:w=\"%d\"/>", 9000 / int.max (1, cols));
                            body.append ("</w:tblGrid>");
                            foreach (var row in block.rows) {
                                body.append ("<w:tr>");
                                for (int c = 0; c < cols; c++) {
                                    string cell = c < row.size ? row[c] : "";
                                    body.append_printf ("<w:tc><w:tcPr><w:tcW w:w=\"%d\" w:type=\"dxa\"/></w:tcPr><w:p><w:r><w:t xml:space=\"preserve\">%s</w:t></w:r></w:p></w:tc>", 9000 / int.max (1, cols), esc (cell));
                                }
                                body.append ("</w:tr>");
                            }
                            body.append ("</w:tbl>");
                            break;
                        case BlockKind.IMAGE:
                            image_id++;
                            string rid = "rIdImg%d".printf (image_id);
                            zip.add ("word/media/image%d.png".printf (image_id), block.png, false);
                            rels.append_printf ("<Relationship Id=\"%s\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image%d.png\"/>", rid, image_id);
                            int64 cx = (int64) (block.width_pt * 12700), cy = (int64) (block.height_pt * 12700);
                            body.append_printf ("<w:p><w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"%lld\" cy=\"%lld\"/><wp:docPr id=\"%d\" name=\"Picture %d\"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"%d\" name=\"image%d.png\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"%s\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"%lld\" cy=\"%lld\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>",
                                cx, cy, image_id, image_id, image_id, image_id, rid, cx, cy);
                            break;
                        default:
                            bool heading = block.kind != BlockKind.PARAGRAPH;
                            body.append ("<w:p>");
                            if (heading) body.append_printf ("<w:pPr><w:pStyle w:val=\"%s\"/></w:pPr>", block.kind == BlockKind.HEADING1 ? "Heading1" : "Heading2");
                            foreach (var r in runs (block)) body.append (docx_run (r, heading));
                            body.append ("</w:p>");
                            break;
                    }
                }
            }
            double pw = pages.size > 0 ? pages[0].width : 595, ph = pages.size > 0 ? pages[0].height : 842;
            var doc = new StringBuilder ();
            doc.append ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n");
            doc.append ("<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>");
            doc.append (body.str);
            doc.append_printf ("<w:sectPr><w:pgSz w:w=\"%d\" w:h=\"%d\"/><w:pgMar w:top=\"1134\" w:right=\"1134\" w:bottom=\"1134\" w:left=\"1134\" w:header=\"567\" w:footer=\"567\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>",
                (int) (pw * 20), (int) (ph * 20));
            zip.add_text ("[Content_Types].xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/></Types>");
            zip.add_text ("_rels/.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>");
            zip.add_text ("word/_rels/document.xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>" + rels.str + "</Relationships>");
            zip.add_text ("word/styles.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val=\"22\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"120\"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/></w:style><w:style w:type=\"paragraph\" w:styleId=\"Heading1\"><w:name w:val=\"heading 1\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"120\"/><w:outlineLvl w:val=\"0\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"36\"/></w:rPr></w:style><w:style w:type=\"paragraph\" w:styleId=\"Heading2\"><w:name w:val=\"heading 2\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:pPr><w:keepNext/><w:spacing w:before=\"200\" w:after=\"100\"/><w:outlineLvl w:val=\"1\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"28\"/></w:rPr></w:style><w:style w:type=\"table\" w:styleId=\"TableGrid\"><w:name w:val=\"Table Grid\"/><w:tblPr><w:tblBorders><w:top w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"000000\"/><w:left w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"000000\"/><w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"000000\"/><w:right w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"000000\"/><w:insideH w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"000000\"/><w:insideV w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"000000\"/></w:tblBorders></w:tblPr></w:style></w:styles>");
            zip.add_text ("word/document.xml", doc.str);
            return zip.finish ();
        }

        private static string odt_span_style (Run r, Gee.HashMap<string, string> styles, StringBuilder auto) {
            string key = "%s%s%s%d".printf (r.bold ? "b" : "", r.italic ? "i" : "", r.color, (int) Math.round (r.size * 2));
            if (!styles.has_key (key)) {
                string name = "T%d".printf (styles.size + 1);
                styles[key] = name;
                auto.append_printf ("<style:style style:name=\"%s\" style:family=\"text\"><style:text-properties", name);
                if (r.bold) auto.append (" fo:font-weight=\"bold\"");
                if (r.italic) auto.append (" fo:font-style=\"italic\"");
                auto.append_printf (" fo:color=\"#%s\"", r.color.down ());
                if (r.size > 0) auto.append_printf (" fo:font-size=\"%gpt\"", Math.round (r.size * 2) / 2);
                auto.append ("/></style:style>");
            }
            return styles[key];
        }

        public static uint8[] odt (Gee.List<PageLayout> pages) throws Error {
            var zip = new ZipWriter ();
            zip.add_text ("mimetype", "application/vnd.oasis.opendocument.text", false);
            var body = new StringBuilder ();
            var auto = new StringBuilder ("<style:style style:name=\"PB\" style:family=\"paragraph\" style:parent-style-name=\"Standard\"><style:paragraph-properties fo:break-before=\"page\"/></style:style><style:style style:name=\"Tbl\" style:family=\"table\"><style:table-properties table:border-model=\"collapsing\"/></style:style><style:style style:name=\"Cell\" style:family=\"table-cell\"><style:table-cell-properties fo:border=\"0.5pt solid #000000\" fo:padding=\"0.05cm\"/></style:style><style:style style:name=\"Fr\" style:family=\"graphic\"><style:graphic-properties style:wrap=\"none\" style:vertical-pos=\"top\" style:horizontal-pos=\"center\"/></style:style>");
            var styles = new Gee.HashMap<string, string> ();
            var manifest = new StringBuilder ();
            int image_id = 0;
            int table_id = 0;
            for (int p = 0; p < pages.size; p++) {
                if (p > 0) body.append ("<text:p text:style-name=\"PB\"/>");
                foreach (var block in pages[p].blocks) {
                    switch (block.kind) {
                        case BlockKind.TABLE:
                            int cols = columns (block);
                            table_id++;
                            body.append_printf ("<table:table table:name=\"Table%d\" table:style-name=\"Tbl\"><table:table-column table:number-columns-repeated=\"%d\"/>", table_id, cols);
                            foreach (var row in block.rows) {
                                body.append ("<table:table-row>");
                                for (int c = 0; c < cols; c++) {
                                    string cell = c < row.size ? row[c] : "";
                                    body.append_printf ("<table:table-cell table:style-name=\"Cell\" office:value-type=\"string\"><text:p>%s</text:p></table:table-cell>", esc (cell));
                                }
                                body.append ("</table:table-row>");
                            }
                            body.append ("</table:table>");
                            break;
                        case BlockKind.IMAGE:
                            image_id++;
                            string path = "Pictures/image%d.png".printf (image_id);
                            zip.add (path, block.png, false);
                            manifest.append_printf ("<manifest:file-entry manifest:full-path=\"%s\" manifest:media-type=\"image/png\"/>", path);
                            body.append_printf ("<text:p><draw:frame draw:style-name=\"Fr\" draw:name=\"Image%d\" text:anchor-type=\"as-char\" svg:width=\"%gpt\" svg:height=\"%gpt\"><draw:image xlink:href=\"%s\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/></draw:frame></text:p>",
                                image_id, Math.round (block.width_pt * 100) / 100, Math.round (block.height_pt * 100) / 100, path);
                            break;
                        default:
                            var list = runs (block);
                            if (block.kind == BlockKind.PARAGRAPH) {
                                body.append ("<text:p text:style-name=\"Standard\">");
                            } else {
                                int level = block.kind == BlockKind.HEADING1 ? 1 : 2;
                                body.append_printf ("<text:h text:style-name=\"Heading_20_%d\" text:outline-level=\"%d\">", level, level);
                            }
                            foreach (var r in list) {
                                if (block.kind != BlockKind.PARAGRAPH) {
                                    body.append (esc (r.text));
                                    continue;
                                }
                                body.append_printf ("<text:span text:style-name=\"%s\">%s</text:span>", odt_span_style (r, styles, auto), esc (r.text));
                            }
                            body.append (block.kind == BlockKind.PARAGRAPH ? "</text:p>" : "</text:h>");
                            break;
                    }
                }
            }
            string content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content " + ODF_NS + " office:version=\"1.3\"><office:automatic-styles>" + auto.str + "</office:automatic-styles><office:body><office:text>" + body.str + "</office:text></office:body></office:document-content>";
            double pw = pages.size > 0 ? pages[0].width : 595, ph = pages.size > 0 ? pages[0].height : 842;
            string styles_xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-styles " + ODF_NS + " office:version=\"1.3\"><office:styles><style:style style:name=\"Standard\" style:family=\"paragraph\"><style:paragraph-properties fo:margin-bottom=\"0.2cm\"/><style:text-properties fo:font-size=\"11pt\"/></style:style><style:style style:name=\"Heading_20_1\" style:display-name=\"Heading 1\" style:family=\"paragraph\" style:parent-style-name=\"Standard\" style:default-outline-level=\"1\"><style:text-properties fo:font-size=\"18pt\" fo:font-weight=\"bold\"/></style:style><style:style style:name=\"Heading_20_2\" style:display-name=\"Heading 2\" style:family=\"paragraph\" style:parent-style-name=\"Standard\" style:default-outline-level=\"2\"><style:text-properties fo:font-size=\"14pt\" fo:font-weight=\"bold\"/></style:style></office:styles><office:automatic-styles><style:page-layout style:name=\"PL\"><style:page-layout-properties fo:page-width=\"%gpt\" fo:page-height=\"%gpt\" fo:margin-top=\"2cm\" fo:margin-bottom=\"2cm\" fo:margin-left=\"2cm\" fo:margin-right=\"2cm\"/></style:page-layout></office:automatic-styles><office:master-styles><style:master-page style:name=\"Standard\" style:page-layout-name=\"PL\"/></office:master-styles></office:document-styles>".printf (Math.round (pw), Math.round (ph));
            zip.add_text ("content.xml", content);
            zip.add_text ("styles.xml", styles_xml);
            zip.add_text ("meta.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-meta xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:meta=\"urn:oasis:names:tc:opendocument:xmlns:meta:1.0\" office:version=\"1.3\"><office:meta><meta:generator>Singularity Reader</meta:generator></office:meta></office:document-meta>");
            zip.add_text ("META-INF/manifest.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.3\"><manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.3\" manifest:media-type=\"application/vnd.oasis.opendocument.text\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/><manifest:file-entry manifest:full-path=\"styles.xml\" manifest:media-type=\"text/xml\"/><manifest:file-entry manifest:full-path=\"meta.xml\" manifest:media-type=\"text/xml\"/>" + manifest.str + "</manifest:manifest>");
            return zip.finish ();
        }

        public static string html (Gee.List<PageLayout> pages, string title) {
            var b = new StringBuilder ("<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n");
            b.append_printf ("<title>%s</title>\n", esc (title));
            b.append ("<style>body{max-width:48em;margin:2em auto;font-family:sans-serif;line-height:1.5}table{border-collapse:collapse}td{border:1px solid #888;padding:.2em .5em}img{max-width:100%}section{margin-bottom:3em}</style>\n</head>\n<body>\n");
            for (int p = 0; p < pages.size; p++) {
                b.append_printf ("<section id=\"page-%d\">\n", p + 1);
                foreach (var block in pages[p].blocks) {
                    switch (block.kind) {
                        case BlockKind.HEADING1:
                            b.append_printf ("<h1>%s</h1>\n", esc (block.text ()));
                            break;
                        case BlockKind.HEADING2:
                            b.append_printf ("<h2>%s</h2>\n", esc (block.text ()));
                            break;
                        case BlockKind.TABLE:
                            b.append ("<table>\n");
                            foreach (var row in block.rows) {
                                b.append ("<tr>");
                                foreach (var cell in row) b.append_printf ("<td>%s</td>", esc (cell));
                                b.append ("</tr>\n");
                            }
                            b.append ("</table>\n");
                            break;
                        case BlockKind.IMAGE:
                            b.append_printf ("<img alt=\"\" width=\"%d\" src=\"data:image/png;base64,%s\">\n", (int) block.width_pt, Base64.encode (block.png));
                            break;
                        default:
                            b.append ("<p>");
                            foreach (var r in runs (block)) {
                                string t = esc (r.text);
                                if (r.bold) t = "<strong>" + t + "</strong>";
                                if (r.italic) t = "<em>" + t + "</em>";
                                b.append (t);
                            }
                            b.append ("</p>\n");
                            break;
                    }
                }
                b.append ("</section>\n");
            }
            b.append ("</body>\n</html>\n");
            return b.str;
        }
    }
}
