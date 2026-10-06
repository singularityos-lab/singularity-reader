using Singularity.Apps.Reader;

string write_sample (bool dark_background) {
    var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, 400, 160);
    var cr = new Cairo.Context (surface);
    if (dark_background) cr.set_source_rgb (0.12, 0.12, 0.14); else cr.set_source_rgb (0.97, 0.96, 0.93);
    cr.paint ();
    if (dark_background) cr.set_source_rgb (0.92, 0.92, 0.95); else cr.set_source_rgb (0.1, 0.1, 0.3);
    cr.set_line_width (8);
    cr.move_to (40, 120);
    cr.curve_to (120, 10, 200, 150, 360, 40);
    cr.stroke ();
    string path = Path.build_filename (Environment.get_tmp_dir (), "sig-%s.png".printf (Uuid.string_random ().substring (0, 6)));
    surface.write_to_png (path);
    return path;
}

void check (bool dark_background) {
    string path = write_sample (dark_background);
    var result = SignatureStore.from_image (path);
    FileUtils.remove (path);
    assert (result != null);
    result.flush ();
    unowned uchar[] data = result.get_data ();
    int stride = result.get_stride ();
    int ink = 0, clear = 0, colored = 0;
    for (int y = 0; y < result.get_height (); y++) {
        for (int x = 0; x < result.get_width (); x++) {
            int o = y * stride + x * 4;
            if (data[o + 3] == 255) {
                ink++;
                if (data[o] != 0 || data[o + 1] != 0 || data[o + 2] != 0) colored++;
            } else if (data[o + 3] == 0) {
                clear++;
            }
        }
    }
    assert (ink > 500);
    assert (clear > ink);
    assert (colored == 0);
    assert (result.get_width () < 400 && result.get_height () < 160);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/signature/light-paper", () => check (false));
    Test.add_func ("/signature/dark-screenshot", () => check (true));
    return Test.run ();
}
