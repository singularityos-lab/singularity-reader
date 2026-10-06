namespace Singularity.Apps.Reader {

    public class SheetData : Object {
        public string name = "";
        public Gee.ArrayList<Gee.ArrayList<string>> rows = new Gee.ArrayList<Gee.ArrayList<string>> ();
    }

    public class SheetExport : Object {
        public static Gee.ArrayList<SheetData> tables (Gee.List<PageLayout> pages) {
            var sheets = new Gee.ArrayList<SheetData> ();
            for (int p = 0; p < pages.size; p++) {
                var sheet = new SheetData ();
                sheet.name = _("Page %d").printf (p + 1);
                bool any_table = false;
                foreach (var b in pages[p].blocks) {
                    if (b.kind != BlockKind.TABLE) continue;
                    if (any_table) sheet.rows.add (new Gee.ArrayList<string> ());
                    any_table = true;
                    foreach (var row in b.rows) sheet.rows.add (row);
                }
                if (!any_table) {
                    foreach (var line in pages[p].lines) {
                        var row = new Gee.ArrayList<string> ();
                        foreach (var cell in line.cells ()) {
                            var s = new StringBuilder ();
                            foreach (var w in cell) {
                                if (s.len > 0) s.append_c (' ');
                                s.append (w.text);
                            }
                            row.add (s.str);
                        }
                        sheet.rows.add (row);
                    }
                }
                sheets.add (sheet);
            }
            return sheets;
        }

        public static string column_name (int index) {
            string s = "";
            int n = index + 1;
            while (n > 0) {
                int r = (n - 1) % 26;
                s = ((char) ('A' + r)).to_string () + s;
                n = (n - 1) / 26;
            }
            return s;
        }

        private static string num (double v) {
            if (v == Math.floor (v) && v.abs () < 1e15) return "%lld".printf ((int64) v);
            return "%.15g".printf (v).replace (",", ".");
        }

        public static uint8[] xlsx (Gee.List<SheetData> sheets) throws Error {
            var zip = new ZipWriter ();
            var types = new StringBuilder ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>");
            var book = new StringBuilder ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>");
            var rels = new StringBuilder ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">");
            for (int i = 0; i < sheets.size; i++) {
                int n = i + 1;
                types.append_printf ("<Override PartName=\"/xl/worksheets/sheet%d.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>", n);
                book.append_printf ("<sheet name=\"%s\" sheetId=\"%d\" r:id=\"rId%d\"/>", TextExport.esc (sheets[i].name), n, n);
                rels.append_printf ("<Relationship Id=\"rId%d\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet%d.xml\"/>", n, n);
                var ws = new StringBuilder ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>");
                for (int r = 0; r < sheets[i].rows.size; r++) {
                    var row = sheets[i].rows[r];
                    ws.append_printf ("<row r=\"%d\">", r + 1);
                    for (int c = 0; c < row.size; c++) {
                        string cell = row[c];
                        if (cell == "") continue;
                        string ref_name = column_name (c) + (r + 1).to_string ();
                        double v;
                        if (PageLayout.parse_number (cell, out v)) ws.append_printf ("<c r=\"%s\"><v>%s</v></c>", ref_name, num (v));
                        else ws.append_printf ("<c r=\"%s\" t=\"inlineStr\"><is><t xml:space=\"preserve\">%s</t></is></c>", ref_name, TextExport.esc (cell));
                    }
                    ws.append ("</row>");
                }
                ws.append ("</sheetData></worksheet>");
                zip.add_text ("xl/worksheets/sheet%d.xml".printf (n), ws.str);
            }
            types.append ("</Types>");
            book.append ("</sheets></workbook>");
            rels.append_printf ("<Relationship Id=\"rId%d\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>", sheets.size + 1);
            zip.add_text ("[Content_Types].xml", types.str);
            zip.add_text ("_rels/.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>");
            zip.add_text ("xl/workbook.xml", book.str);
            zip.add_text ("xl/_rels/workbook.xml.rels", rels.str);
            zip.add_text ("xl/styles.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/></cellXfs></styleSheet>");
            return zip.finish ();
        }

        public static uint8[] ods (Gee.List<SheetData> sheets) throws Error {
            var zip = new ZipWriter ();
            zip.add_text ("mimetype", "application/vnd.oasis.opendocument.spreadsheet", false);
            var body = new StringBuilder ();
            foreach (var sheet in sheets) {
                int cols = 1;
                foreach (var row in sheet.rows) cols = int.max (cols, row.size);
                body.append_printf ("<table:table table:name=\"%s\"><table:table-column table:number-columns-repeated=\"%d\"/>", TextExport.esc (sheet.name), cols);
                foreach (var row in sheet.rows) {
                    body.append ("<table:table-row>");
                    for (int c = 0; c < cols; c++) {
                        string cell = c < row.size ? row[c] : "";
                        double v;
                        if (cell == "") body.append ("<table:table-cell/>");
                        else if (PageLayout.parse_number (cell, out v)) body.append_printf ("<table:table-cell office:value-type=\"float\" office:value=\"%s\"><text:p>%s</text:p></table:table-cell>", num (v), TextExport.esc (cell));
                        else body.append_printf ("<table:table-cell office:value-type=\"string\"><text:p>%s</text:p></table:table-cell>", TextExport.esc (cell));
                    }
                    body.append ("</table:table-row>");
                }
                body.append ("</table:table>");
            }
            zip.add_text ("content.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" office:version=\"1.3\"><office:body><office:spreadsheet>" + body.str + "</office:spreadsheet></office:body></office:document-content>");
            zip.add_text ("styles.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-styles xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" office:version=\"1.3\"/>");
            zip.add_text ("META-INF/manifest.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.3\"><manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.3\" manifest:media-type=\"application/vnd.oasis.opendocument.spreadsheet\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/><manifest:file-entry manifest:full-path=\"styles.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>");
            return zip.finish ();
        }
    }
}
