namespace Singularity.Apps.Reader {

    public class SlideExport : Object {
        private const string ODF_NS = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" xmlns:draw=\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\" xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\" xmlns:presentation=\"urn:oasis:names:tc:opendocument:xmlns:presentation:1.0\"";

        private const string P_NS = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"";
        private const string XML_HEAD = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n";
        private const string EMPTY_TREE = "<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>";

        public static uint8[] build (Poppler.Document doc, int first, int last, double dpi, bool pptx) throws Error {
            return pptx ? build_pptx (doc, first, last, dpi) : build_odp (doc, first, last, dpi);
        }

        private static uint8[] build_pptx (Poppler.Document doc, int first, int last, double dpi) throws Error {
            var zip = new ZipWriter ();
            double pw, ph;
            doc.get_page (first).get_size (out pw, out ph);
            int64 cx = (int64) (pw * 12700), cy = (int64) (ph * 12700);
            var types = new StringBuilder (XML_HEAD + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/><Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/><Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/><Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>");
            var ids = new StringBuilder ();
            var pres_rels = new StringBuilder (XML_HEAD + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"theme/theme1.xml\"/>");
            for (int i = first; i <= last; i++) {
                int n = i - first + 1;
                var page = doc.get_page (i);
                double w, h;
                page.get_size (out w, out h);
                double s = double.min (pw / w, ph / h);
                int64 ex = (int64) (w * s * 12700), ey = (int64) (h * s * 12700);
                int64 ox = (cx - ex) / 2, oy = (cy - ey) / 2;
                zip.add ("ppt/media/page%d.png".printf (n), Exporter.render_png (page, dpi), false);
                types.append_printf ("<Override PartName=\"/ppt/slides/slide%d.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>", n);
                ids.append_printf ("<p:sldId id=\"%d\" r:id=\"rIdS%d\"/>", 255 + n, n);
                pres_rels.append_printf ("<Relationship Id=\"rIdS%d\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide%d.xml\"/>", n, n);
                zip.add_text ("ppt/slides/slide%d.xml".printf (n), XML_HEAD + "<p:sld " + P_NS + "><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"
                    + "<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"Page %d\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rIdImg\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"%lld\" y=\"%lld\"/><a:ext cx=\"%lld\" cy=\"%lld\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>".printf (n, ox, oy, ex, ey)
                    + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>");
                zip.add_text ("ppt/slides/_rels/slide%d.xml.rels".printf (n), XML_HEAD + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rIdLayout\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rIdImg\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"../media/page%d.png\"/></Relationships>".printf (n));
            }
            types.append ("</Types>");
            pres_rels.append ("</Relationships>");
            zip.add_text ("[Content_Types].xml", types.str);
            zip.add_text ("_rels/.rels", XML_HEAD + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>");
            zip.add_text ("ppt/presentation.xml", XML_HEAD + "<p:presentation " + P_NS + "><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>" + ids.str
                + "</p:sldIdLst><p:sldSz cx=\"%lld\" cy=\"%lld\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>".printf (cx, cy));
            zip.add_text ("ppt/_rels/presentation.xml.rels", pres_rels.str);
            zip.add_text ("ppt/slideMasters/slideMaster1.xml", XML_HEAD + "<p:sldMaster " + P_NS + ">" + EMPTY_TREE
                + "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst></p:sldMaster>");
            zip.add_text ("ppt/slideMasters/_rels/slideMaster1.xml.rels", XML_HEAD + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"../theme/theme1.xml\"/></Relationships>");
            zip.add_text ("ppt/slideLayouts/slideLayout1.xml", XML_HEAD + "<p:sldLayout " + P_NS + " type=\"blank\">" + EMPTY_TREE + "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>");
            zip.add_text ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", XML_HEAD + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>");
            zip.add_text ("ppt/theme/theme1.xml", theme ());
            return zip.finish ();
        }

        private static string theme () {
            var c = new StringBuilder ();
            string[] names = { "dk1", "lt1", "dk2", "lt2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink" };
            string[] values = { "000000", "FFFFFF", "1F2937", "F3F4F6", "3584E4", "E01B24", "33D17A", "F6D32D", "9141AC", "FF7800", "1C71D8", "813D9C" };
            for (int i = 0; i < names.length; i++) c.append_printf ("<a:%s><a:srgbClr val=\"%s\"/></a:%s>", names[i], values[i], names[i]);
            string fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>";
            string line = "<a:ln w=\"9525\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>";
            string effect = "<a:effectStyle><a:effectLst/></a:effectStyle>";
            return XML_HEAD + "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Reader\"><a:themeElements><a:clrScheme name=\"Reader\">" + c.str
                + "</a:clrScheme><a:fontScheme name=\"Reader\"><a:majorFont><a:latin typeface=\"Sans\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"Sans\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme><a:fmtScheme name=\"Reader\"><a:fillStyleLst>"
                + fill + fill + fill + "</a:fillStyleLst><a:lnStyleLst>" + line + line + line + "</a:lnStyleLst><a:effectStyleLst>" + effect + effect + effect + "</a:effectStyleLst><a:bgFillStyleLst>" + fill + fill + fill
                + "</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>";
        }

        private static uint8[] build_odp (Poppler.Document doc, int first, int last, double dpi) throws Error {
            var zip = new ZipWriter ();
            zip.add_text ("mimetype", "application/vnd.oasis.opendocument.presentation", false);
            double pw, ph;
            doc.get_page (first).get_size (out pw, out ph);
            var body = new StringBuilder ();
            var manifest = new StringBuilder ();
            for (int i = first; i <= last; i++) {
                int n = i - first + 1;
                var page = doc.get_page (i);
                double w, h;
                page.get_size (out w, out h);
                double s = double.min (pw / w, ph / h);
                string path = "Pictures/page%d.png".printf (n);
                zip.add (path, Exporter.render_png (page, dpi), false);
                manifest.append_printf ("<manifest:file-entry manifest:full-path=\"%s\" manifest:media-type=\"image/png\"/>", path);
                body.append_printf ("<draw:page draw:name=\"page%d\" draw:master-page-name=\"Default\"><draw:frame svg:x=\"%gpt\" svg:y=\"%gpt\" svg:width=\"%gpt\" svg:height=\"%gpt\"><draw:image xlink:href=\"%s\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/></draw:frame></draw:page>",
                    n, Math.round ((pw - w * s) / 2), Math.round ((ph - h * s) / 2), Math.round (w * s), Math.round (h * s), path);
            }
            zip.add_text ("content.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content " + ODF_NS + " office:version=\"1.3\"><office:body><office:presentation>" + body.str + "</office:presentation></office:body></office:document-content>");
            zip.add_text ("styles.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-styles " + ODF_NS + " office:version=\"1.3\"><office:automatic-styles><style:page-layout style:name=\"PM\"><style:page-layout-properties fo:page-width=\"%gpt\" fo:page-height=\"%gpt\" fo:margin-top=\"0pt\" fo:margin-bottom=\"0pt\" fo:margin-left=\"0pt\" fo:margin-right=\"0pt\"/></style:page-layout></office:automatic-styles><office:master-styles><style:master-page style:name=\"Default\" style:page-layout-name=\"PM\"/></office:master-styles></office:document-styles>".printf (Math.round (pw), Math.round (ph)));
            zip.add_text ("META-INF/manifest.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.3\"><manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.3\" manifest:media-type=\"application/vnd.oasis.opendocument.presentation\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/><manifest:file-entry manifest:full-path=\"styles.xml\" manifest:media-type=\"text/xml\"/>" + manifest.str + "</manifest:manifest>");
            return zip.finish ();
        }
    }
}
