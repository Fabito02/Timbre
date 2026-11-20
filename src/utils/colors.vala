namespace Timbre.Utils {

    public class ColorEntry : Object {
        public int    h;
        public int    s;
        public int    l;
        public int    count;
        public string hex;
    }

    public struct Rgb {
        public double r;
        public double g;
        public double b;
    }

    public class Colors : Object {

        public static string? get_vibrant_color (string? uri) {
            var colors = get_colors (uri);
            return (colors != null && colors.length () > 0)
                ? colors.nth_data (0).hex
                : null;
        }

        public static GLib.List<ColorEntry>? get_colors (string? uri) {
            if (uri == null || uri.strip ().length == 0) {
                return null;
            }

            string resolved = uri;
            if (!resolved.has_prefix ("file://")) {
                if (resolved.has_prefix ("/")) {
                    resolved = File.new_for_path (resolved).get_uri ();
                } else {
                    return null;
                }
            }

            try {
                var file   = File.new_for_uri (resolved);
                var stream = file.read (null);
                var pixbuf = new Gdk.Pixbuf.from_stream_at_scale (
                    stream, 64, 64, true, null);
                try { stream.close (null); }
                catch (Error e) { /* ignore */ }

                unowned uint8[] pixels = pixbuf.get_pixels ();
                int rowstride = pixbuf.get_rowstride ();
                int channels  = pixbuf.get_n_channels ();
                int width     = pixbuf.get_width ();
                int height    = pixbuf.get_height ();

                var color_map = new HashTable<string, ColorEntry> (str_hash, str_equal);

                for (int y = 0; y < height; y++) {
                    for (int x = 0; x < width; x++) {
                        int offset = y * rowstride + x * channels;
                        uint8 r8 = pixels[offset];
                        uint8 g8 = pixels[offset + 1];
                        uint8 b8 = pixels[offset + 2];

                        double r = r8 / 255.0;
                        double g = g8 / 255.0;
                        double b = b8 / 255.0;
                        double max = double.max (r, double.max (g, b));
                        double min = double.min (r, double.min (g, b));
                        double ld  = (max + min) / 2.0;

                        int h, s, l;
                        if (max == min) {
                            h = 0;
                            s = 0;
                            l = (int) Math.round (ld * 100);
                        } else {
                            double d  = max - min;
                            double sd = ld > 0.5 ? d / (2.0 - max - min) : d / (max + min);
                            double hd;
                            if (max == r)      hd = (g - b) / d + (g < b ? 6 : 0);
                            else if (max == g) hd = (b - r) / d + 2;
                            else               hd = (r - g) / d + 4;
                            h = (int) Math.round ((hd / 6.0) * 360);
                            s = (int) Math.round (sd * 100);
                            l = (int) Math.round (ld * 100);
                        }

                        const int STEP = 24;
                        int qr = int.min (255, ((int) r8 / STEP) * STEP + STEP / 2);
                        int qg = int.min (255, ((int) g8 / STEP) * STEP + STEP / 2);
                        int qb = int.min (255, ((int) b8 / STEP) * STEP + STEP / 2);

                        string hex = "#%02x%02x%02x".printf (qr, qg, qb);

                        var entry = color_map.lookup (hex);
                        if (entry == null) {
                            entry = new ColorEntry () {
                                h = h, s = s, l = l, count = 0, hex = hex
                            };
                            color_map.insert (hex, entry);
                        }
                        entry.count += 1;
                    }
                }

                var colors = new GLib.List<ColorEntry> ();
                foreach (var c in color_map.get_values ()) {
                    colors.append (c);
                }
                if (colors.length () == 0) {
                    return colors;
                }

                int total_pixels = width * height;

                ColorEntry? dominant = null;
                foreach (var c in colors) {
                    if (dominant == null || c.count > dominant.count) {
                        dominant = c;
                    }
                }

                colors.sort ((a, b) => {
                    double l_score_a = 1.0 - Math.fabs (a.l - 50) / 50.0;
                    double l_score_b = 1.0 - Math.fabs (b.l - 50) / 50.0;
                    double score_a   = (double) (a.s * a.s) * l_score_a * Math.log (a.count + 1);
                    double score_b   = (double) (b.s * b.s) * l_score_b * Math.log (b.count + 1);
                    return score_b > score_a ? 1 : (score_b < score_a ? -1 : 0);
                });

                ColorEntry? chosen = null;

                if (dominant != null) {
                    double weight_d = dominant.s * (1.0 - Math.fabs (dominant.l - 50) / 50.0);

                    foreach (var c in colors) {
                        double weight = c.s * (1.0 - Math.fabs (c.l - 50) / 50.0);
                        double diff   = weight - weight_d;

                        if (diff > 0.0) {
                            double ratio   = Math.fmin (1.0, diff / 50.0);
                            double min_pct = 0.10 - (0.10 - 0.00) * ratio;
                            int min_count  = (int) (total_pixels * min_pct);

                            if (c.count >= min_count) {
                                chosen = c;
                                break;
                            }
                        }
                    }
                }

                if (chosen == null) {
                    chosen = dominant;
                }

                if (chosen == null) {
                    chosen = colors.nth_data (0);
                }

                if (colors.nth_data (0) != chosen) {
                    colors.remove (chosen);
                    colors.prepend (chosen);
                }

                var color = colors.nth_data (0);

                var rgb = hsl_to_rgb (color.h, color.s, color.l);
                double luminance = get_relative_luminance (rgb.r, rgb.g, rgb.b);

                int l         = color.l;
                int initial_l = l;
                const double LIGHT_BG_LUMINANCE = 0.957;
                const double DARK_BG_LUMINANCE  = 0.037;

                if (get_contrast_ratio (luminance, LIGHT_BG_LUMINANCE) < 3) {
                    while (get_contrast_ratio (luminance, LIGHT_BG_LUMINANCE) < 3 && l > 0) {
                        l--;
                        var c = hsl_to_rgb (color.h, color.s, l);
                        luminance = get_relative_luminance (c.r, c.g, c.b);
                    }
                } else if (get_contrast_ratio (luminance, DARK_BG_LUMINANCE) < 3) {
                    while (get_contrast_ratio (luminance, DARK_BG_LUMINANCE) < 3 && l < 100) {
                        l++;
                        var c = hsl_to_rgb (color.h, color.s, l);
                        luminance = get_relative_luminance (c.r, c.g, c.b);
                    }
                }

                int  lightness_shift = (int) Math.fabs (l - initial_l);
                bool is_deep_dark    = initial_l < 15;
                bool is_bright_light = initial_l > 85;
                bool is_muted_color  = color.s >= 8 && color.s < 35;

                if (is_deep_dark) {
                    color.s = (int) Math.round (color.s * ((double) initial_l / 15.0));
                } else if (is_bright_light) {
                    color.s = (int) Math.round (color.s * ((100.0 - initial_l) / 15.0));
                } else if (lightness_shift > 10 && is_muted_color) {
                    double boost_factor = 1.0 + ((double) lightness_shift / 50.0) * 0.4;
                    color.s = int.min (45, (int) Math.round (color.s * boost_factor));
                }

                color.l = l;
                var final_rgb = hsl_to_rgb (color.h, color.s, color.l);
                color.hex = "#%s%s%s".printf (
                    to_hex (final_rgb.r),
                    to_hex (final_rgb.g),
                    to_hex (final_rgb.b));

                return colors;

            } catch (Error e) {
                warning ("Colors.get_colors: %s", e.message);
                return null;
            }
        }

        private static double get_relative_luminance (double r, double g, double b) {
            double ar = r <= 0.04045 ? r / 12.92 : Math.pow ((r + 0.055) / 1.055, 2.4);
            double ag = g <= 0.04045 ? g / 12.92 : Math.pow ((g + 0.055) / 1.055, 2.4);
            double ab = b <= 0.04045 ? b / 12.92 : Math.pow ((b + 0.055) / 1.055, 2.4);
            return 0.2126 * ar + 0.7152 * ag + 0.0722 * ab;
        }

        private static double get_contrast_ratio (double lum1, double lum2) {
            double brightest = double.max (lum1, lum2);
            double darkest   = double.min (lum1, lum2);
            return Math.round (((brightest + 0.05) / (darkest + 0.05)) * 100) / 100;
        }

        private static string to_hex (double val) {
            return "%02x".printf ((int) Math.round (val * 255));
        }

        private static double hue_to_rgb (double p, double q, double t) {
            if (t < 0) t += 1;
            if (t > 1) t -= 1;
            if (t < 1.0 / 6) return p + (q - p) * 6 * t;
            if (t < 1.0 / 2) return q;
            if (t < 2.0 / 3) return p + (q - p) * (2.0 / 3 - t) * 6;
            return p;
        }

        private static Rgb hsl_to_rgb (int h360, int s100, int l100) {
            double h = h360 / 360.0;
            double s = s100 / 100.0;
            double l = l100 / 100.0;
            if (s == 0) {
                return Rgb () { r = l, g = l, b = l };
            }
            double q = l < 0.5 ? l * (1 + s) : l + s - l * s;
            double p = 2 * l - q;
            return Rgb () {
                r = hue_to_rgb (p, q, h + 1.0 / 3),
                g = hue_to_rgb (p, q, h),
                b = hue_to_rgb (p, q, h - 1.0 / 3)
            };
        }
    }
}
