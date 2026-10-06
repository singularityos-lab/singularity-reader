namespace Singularity.Apps.Reader {

    public static int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = FileUtils.read_link ("/proc/self/exe");
            locale_dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale");
        } catch (Error e) {
        }
        Intl.bindtextdomain ("singularity-reader", locale_dir);
        Intl.bind_textdomain_codeset ("singularity-reader", "UTF-8");
        Intl.textdomain ("singularity-reader");
        return new ReaderApp ().run (args);
    }
}
