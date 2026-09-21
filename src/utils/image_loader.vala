namespace Timbre.Utils {

    public class ScaledPaintable : GLib.Object, Gdk.Paintable {
        private Gdk.Texture texture;
        private int scale_factor;

        public ScaledPaintable (Gdk.Texture texture, int scale_factor) {
            this.texture = texture;
            this.scale_factor = scale_factor > 0 ? scale_factor : 1;
        }

        public int get_intrinsic_width () {
            return this.texture.get_width () / this.scale_factor;
        }

        public int get_intrinsic_height () {
            return this.texture.get_height () / this.scale_factor;
        }

        public double get_intrinsic_aspect_ratio () {
            return this.texture.get_intrinsic_aspect_ratio ();
        }

        public void snapshot (Gdk.Snapshot snapshot, double width, double height) {
            this.texture.snapshot (snapshot, width, height);
        }

        public Gdk.PaintableFlags get_flags () {
            return this.texture.get_flags ();
        }
    }

    public class ImageLoader : Object {
        private static ImageLoader? instance;
        private Soup.Session session;
        private GLib.HashTable<string, Gdk.Paintable> memory_cache;

        public static ImageLoader get_default () {
            if (instance == null) {
                instance = new ImageLoader ();
            }
            return instance;
        }

        private ImageLoader () {
            this.session = new Soup.Session ();
            this.memory_cache = new GLib.HashTable<string, Gdk.Paintable> (str_hash, str_equal);
        }

        public async Gdk.Paintable? load_paintable_async (
            string? url, 
            Gdk.Display display, 
            int target_size,
            int scale_factor = 1,
            string fallback_icon = "audio-x-generic-symbolic"
        ) {
            int scale = scale_factor > 0 ? scale_factor : 1;

            if (url != null && url.strip ().length > 0) {
                var cache_key = "%s@%dx%d".printf (url, target_size, scale);
                var cached = this.memory_cache.lookup (cache_key);
                if (cached != null) {
                    return cached;
                }

                try {
                    var message = new Soup.Message ("GET", url);
                    Bytes bytes = yield this.session.send_and_read_async (message, Priority.DEFAULT, null);

                    if (message.status_code == 200) {
                        var stream = new MemoryInputStream.from_bytes (bytes);
                        var original_pixbuf = yield new Gdk.Pixbuf.from_stream_async (stream, null);

                        if (original_pixbuf != null) {
                            int render_size = target_size * scale;
                            var scaled_pixbuf = original_pixbuf.scale_simple (
                                render_size,
                                render_size,
                                Gdk.InterpType.BILINEAR
                            );

                            var texture = Gdk.Texture.for_pixbuf (scaled_pixbuf);
                            
                            Gdk.Paintable paintable;
                            if (scale > 1) {
                                paintable = new ScaledPaintable (texture, scale);
                            } else {
                                paintable = texture;
                            }

                            this.memory_cache.insert (cache_key, paintable);
                            return paintable;
                        }
                    }
                } catch (Error e) {
                    debug ("Failed to download image (%s): %s", url, e.message);
                }
            }

            return this.get_fallback_icon (display, target_size, scale, fallback_icon);
        }

        public Gdk.Paintable? get_fallback_icon (
            Gdk.Display display, 
            int size, 
            int scale_factor = 1, 
            string icon_name = "audio-x-generic-symbolic"
        ) {
            var theme = Gtk.IconTheme.get_for_display (display);
            string[] fallbacks = {
                icon_name,
                "audio-x-generic",
                "media-optical-audio-symbolic"
            };

            return theme.lookup_icon (
                icon_name,
                fallbacks,
                size,
                scale_factor > 0 ? scale_factor : 1,
                Gtk.TextDirection.NONE,
                Gtk.IconLookupFlags.FORCE_SYMBOLIC
            );
        }
    }
}
