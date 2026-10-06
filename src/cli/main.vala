namespace Singularity.Apps.Reader {

    public class Cli : Object {
        private string password = "";
        private string output = "";
        private string[] rest = {};

        private const string USAGE = """Usage: singularity-pdf COMMAND [options] FILE...

Commands:
  info FILE                      Pages, version, security, forms and signatures
  text FILE                      Print the text of every page
  merge FILE... -o OUT           Combine files, with a bookmark per file
  split FILE N -o DIR            Split every N pages
  extract FILE PAGES -o OUT      Copy pages, for example 1-3,7
  delete FILE PAGES -o OUT       Remove pages
  rotate FILE PAGES DEG -o OUT   Rotate pages by 90, 180 or 270 degrees
  compress FILE -o OUT           Optimize images and structure
  linearize FILE -o OUT          Save for fast web view
  encrypt FILE PASSWORD -o OUT   Protect with AES-256
  decrypt FILE -o OUT            Remove protection (use -p for the password)
  pdfa FILE LEVEL -o OUT         Convert to PDF/A (1b, 2b, 3b)
  pdfx FILE VERSION -o OUT       Convert to PDF/X (PDF/X-1a, PDF/X-3, PDF/X-4)
  check FILE STANDARD            Check PDF/A-2b, PDF/X-4, PDF/UA and others
  tag FILE LANG -o OUT           Add accessibility tags
  redact FILE REGEX -o OUT       Remove every match of a pattern, then verify
  sanitize FILE -o OUT           Remove hidden information
  watermark FILE TEXT -o OUT     Add a text watermark
  number FILE -o OUT             Add page numbers
  ocr FILE -o OUT                Recognize text in scanned pages
  export FILE FORMAT -o OUT      docx, odt, xlsx, ods, pptx, odp, png, jpeg, tiff, txt, html
  fill FILE NAME=VALUE... -o OUT Fill form fields
  flatten FILE -o OUT            Turn form fields and stamps into page content
  sign FILE CERT.p12 -o OUT      Sign with a certificate (-p is the certificate password)
  verify FILE                    Check digital signatures
  compare OLD NEW                List the differences between two files
  attach FILE ATTACHMENT -o OUT  Attach a file
  images FILE -o DIR             Extract the original images

Options:
  -p PASSWORD   Password to open FILE
  -o OUTPUT     Output file or folder
""";

        public int run (string[] args) {
            if (args.length < 2 || args[1] == "--help" || args[1] == "-h") {
                print ("%s", USAGE);
                return args.length < 2 ? 1 : 0;
            }
            string command = args[1];
            for (int i = 2; i < args.length; i++) {
                if (args[i] == "-p" && i + 1 < args.length) password = args[++i];
                else if (args[i] == "-o" && i + 1 < args.length) output = args[++i];
                else rest += args[i];
            }
            try {
                return dispatch (command);
            } catch (Error e) {
                printerr ("singularity-pdf: %s\n", e.message);
                return 1;
            }
        }

        private uint8[] read_input (int index = 0) throws Error {
            if (rest.length <= index) throw new IOError.INVALID_ARGUMENT ("a file is missing");
            uint8[] data;
            FileUtils.get_data (rest[index], out data);
            return data;
        }

        private Singularity.Pdf.Document open (int index = 0) throws Error {
            return Singularity.Pdf.Document.open_bytes (read_input (index), password);
        }

        private void write (uint8[] data) throws Error {
            if (output == "") throw new IOError.INVALID_ARGUMENT ("use -o to name the output");
            FileUtils.set_data (output, data);
        }

        private string arg (int i) throws Error {
            if (rest.length <= i) throw new IOError.INVALID_ARGUMENT ("an argument is missing");
            return rest[i];
        }

        private int[] pages (string spec, int total) {
            int[] result = {};
            foreach (var part in spec.split (",")) {
                string p = part.strip ();
                int dash = p.index_of_char ('-');
                if (dash >= 0) {
                    int a = dash == 0 ? 1 : int.parse (p.substring (0, dash));
                    string tail = p.substring (dash + 1);
                    int b = tail == "" ? total : int.parse (tail);
                    for (int i = int.max (1, a); i <= int.min (total, b); i++) result += i - 1;
                } else if (p != "") {
                    int n = int.parse (p);
                    if (n >= 1 && n <= total) result += n - 1;
                }
            }
            return result;
        }

        private int dispatch (string command) throws Error {
            switch (command) {
                case "info":
                    var d = open ();
                    print ("Pages: %d\nVersion: %s\n", d.page_count (), d.version);
                    var info = d.info_if_present ();
                    if (info != null) foreach (var k in info.dict.keys) print ("%s: %s\n", k, d.lookup (info, k).text_value ());
                    print ("Encrypted: %s\n", d.security != null ? (d.security.revision >= 5 ? "AES-256" : "yes") : "no");
                    print ("Form fields: %d\n", Singularity.Pdf.Forms.list (d).size);
                    print ("Annotations: %d\n", Singularity.Pdf.Annotations.list (d).size);
                    print ("Attachments: %d\n", Singularity.Pdf.Attachments.list (d).size);
                    print ("Signatures: %d\n", Singularity.Pdf.Signing.list (d).size);
                    print ("Tagged: %s\n", d.lookup (d.catalog (), "StructTreeRoot").is_dict () ? "yes" : "no");
                    string part = Singularity.Pdf.Standards.pdfa_part (d);
                    if (part != "") print ("PDF/A: %s\n", part);
                    return 0;
                case "text":
                    var d = open ();
                    for (int p = 0; p < d.page_count (); p++) {
                        var it = new Singularity.Pdf.Interpreter (d);
                        it.run_page (p);
                        print ("%s\n\f", it.page_text ());
                    }
                    return 0;
                case "merge":
                    var docs = new Gee.ArrayList<Singularity.Pdf.Document> ();
                    string[] titles = {};
                    for (int i = 0; i < rest.length; i++) {
                        docs.add (open (i));
                        string b = Path.get_basename (rest[i]);
                        titles += b.has_suffix (".pdf") ? b.substring (0, b.length - 4) : b;
                    }
                    write (Singularity.Pdf.Pages.merge (docs, titles).save ());
                    return 0;
                case "split":
                    var d = open ();
                    int n = int.parse (arg (1));
                    var parts = Singularity.Pdf.Pages.split_every (d, n);
                    DirUtils.create_with_parents (output, 0755);
                    for (int i = 0; i < parts.size; i++) FileUtils.set_data (Path.build_filename (output, "part-%d.pdf".printf (i + 1)), parts[i].save ());
                    return 0;
                case "extract":
                    var d = open ();
                    write (Singularity.Pdf.Pages.extract (d, pages (arg (1), d.page_count ())).save ());
                    return 0;
                case "delete":
                    var d = open ();
                    Singularity.Pdf.Pages.delete (d, pages (arg (1), d.page_count ()));
                    write (d.save ());
                    return 0;
                case "rotate":
                    var d = open ();
                    Singularity.Pdf.Pages.rotate (d, pages (arg (1), d.page_count ()), int.parse (arg (2)));
                    write (d.save ());
                    return 0;
                case "compress":
                    write (Operations.optimize (read_input (), password, 150, 75));
                    return 0;
                case "linearize":
                    write (Operations.linearize (read_input (), password));
                    return 0;
                case "encrypt":
                    write (Operations.protect (read_input (), password, arg (1)));
                    return 0;
                case "decrypt":
                    write (Operations.unprotect (read_input (), password));
                    return 0;
                case "pdfa":
                    int remaining;
                    write (Operations.pdfa (read_input (), password, arg (1), out remaining));
                    if (remaining > 0) printerr ("%d problems could not be fixed automatically\n", remaining);
                    return remaining > 0 ? 2 : 0;
                case "pdfx":
                    var d = open ();
                    Singularity.Pdf.SaveOptions opts;
                    var issues = Singularity.Pdf.Standards.convert_pdfx (d, arg (1), out opts);
                    write (d.save (opts));
                    foreach (var i in issues) printerr ("%s: %s\n", i.rule, i.message);
                    return issues.size > 0 ? 2 : 0;
                case "check":
                    var d = open ();
                    string std = arg (1).down ();
                    Gee.ArrayList<Singularity.Pdf.Issue> issues;
                    if (std.has_prefix ("pdf/a-") || std.has_prefix ("a")) issues = Singularity.Pdf.Standards.check_pdfa (d, std.replace ("pdf/a-", "").replace ("a", ""));
                    else if (std.contains ("ua")) issues = Singularity.Pdf.Standards.check_pdfua (d);
                    else issues = Singularity.Pdf.Standards.check_pdfx (d, arg (1));
                    foreach (var i in issues) print ("%s\t%s\t%s\n", i.rule, i.page >= 0 ? "page %d".printf (i.page + 1) : "document", i.message);
                    print ("%d problems\n", issues.size);
                    return issues.size > 0 ? 2 : 0;
                case "tag":
                    write (Operations.tag (read_input (), password, arg (1)));
                    return 0;
                case "redact":
                    int count;
                    write (Operations.redact_pattern (read_input (), password, arg (1), out count));
                    print ("%d areas redacted and verified\n", count);
                    return 0;
                case "sanitize":
                    write (Operations.sanitize (read_input (), password));
                    return 0;
                case "watermark":
                    write (Operations.watermark (read_input (), password, arg (1)));
                    return 0;
                case "number":
                    write (Operations.number_pages (read_input (), password, Path.get_basename (arg (0))));
                    return 0;
                case "ocr":
                    var loop = new MainLoop ();
                    uint8[]? result = null;
                    Error? failure = null;
                    int words = 0;
                    var input = read_input ();
                    Operations.ocr.begin (input, password, true, null, (o, r) => {
                        try {
                            result = Operations.ocr.end (r, out words);
                        } catch (Error e) {
                            failure = e;
                        }
                        loop.quit ();
                    });
                    loop.run ();
                    if (failure != null) throw failure;
                    write (result);
                    print ("%d words recognized\n", words);
                    return 0;
                case "export":
                    var poppler = new Poppler.Document.from_bytes (new Bytes (read_input ()), password);
                    Exporter.export (poppler, arg (1), File.new_for_path (output));
                    return 0;
                case "fill":
                    var d = open ();
                    var values = new Gee.HashMap<string, string> ();
                    for (int i = 1; i < rest.length; i++) {
                        int eq = rest[i].index_of_char ('=');
                        if (eq > 0) values[rest[i].substring (0, eq)] = rest[i].substring (eq + 1);
                    }
                    int filled = Singularity.Pdf.Forms.import_values (d, values);
                    write (d.save ());
                    print ("%d fields filled\n", filled);
                    return 0;
                case "flatten":
                    var d = open ();
                    Singularity.Pdf.Forms.flatten (d);
                    FillFormPage.flatten_stamps (d);
                    write (d.save ());
                    return 0;
                case "sign":
                    var d = open ();
                    var req = new Singularity.Pdf.SignatureRequest ();
                    req.signer = Environment.get_real_name ();
                    write (DigitalSigner.sign_file_pkcs12 (d, req, arg (1), password, null));
                    return 0;
                case "verify":
                    var d = open ();
                    var list = DigitalSigner.verify (d, false);
                    foreach (var s in list) print ("%s\t%s\t%s\n", s.field, s.status.to_string ().replace ("SINGULARITY_APPS_READER_SIGNATURE_STATE_", ""), s.signer);
                    if (list.size == 0) print ("not signed\n");
                    return 0;
                case "compare":
                    var r = Singularity.Pdf.Compare.documents (open (0), open (1));
                    foreach (var c in r.changes) print ("%s\tpage %d\t%s\t%s\n", c.kind.to_string ().replace ("SINGULARITY_PDF_CHANGE_KIND_", ""), int.max (c.page_a, c.page_b) + 1, c.old_text, c.new_text);
                    print ("%d added, %d removed, %d changed\n", r.inserted_words, r.deleted_words, r.replaced);
                    return r.identical ? 0 : 3;
                case "attach":
                    var d = open ();
                    uint8[] data;
                    FileUtils.get_data (arg (1), out data);
                    Singularity.Pdf.Attachments.add (d, Path.get_basename (arg (1)), data);
                    write (d.save ());
                    return 0;
                case "images":
                    var d = open ();
                    DirUtils.create_with_parents (output, 0755);
                    int count = 0;
                    var seen = new Gee.HashSet<int> ();
                    for (int p = 0; p < d.page_count (); p++) {
                        foreach (var info in Singularity.Pdf.Images.list (d, p)) {
                            if (info.xobject == null || (info.xobject.is_ref () && seen.contains (info.xobject.num))) continue;
                            if (info.xobject.is_ref ()) seen.add (info.xobject.num);
                            try {
                                string ext;
                                var bytes = Singularity.Pdf.Images.original (d, info, out ext);
                                FileUtils.set_data (Path.build_filename (output, "image-%d.%s".printf (++count, ext)), bytes);
                            } catch (Error e) {
                                printerr ("page %d: %s\n", p + 1, e.message);
                            }
                        }
                    }
                    print ("%d images\n", count);
                    return 0;
                default:
                    printerr ("unknown command %s\n\n%s", command, USAGE);
                    return 1;
            }
        }
    }

    int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        Intl.textdomain ("singularity-reader");
        return new Cli ().run (args);
    }
}
