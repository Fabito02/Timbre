namespace Timbre.Utils {
    public class ImageLoader : Object {
        private static ImageLoader? instance;

        public static ImageLoader get_default () {
            if (instance == null) {
                instance = new ImageLoader ();
            }
            return instance;
        }

        private const int LRU_MAX_ITEMS = 256;
        private const int64 LRU_MAX_BYTES = 24 * 1024 * 1024;
        private const int64 LRU_TTL_US = 2 * 60 * 1000 * 1000LL;
        private const int LRU_MAX_PIXELS = 256 * 256;

        private class CacheEntry : Object {
            public Gdk.Texture texture;
            public int64 bytes;
            public int64 last_used_us;

            public CacheEntry (Gdk.Texture tex) {
                this.texture = tex;
                this.bytes = (int64) tex.get_width () * tex.get_height () * 4;
                this.last_used_us = GLib.get_monotonic_time ();
            }
        }

        private Soup.Session session;
        private string disk_cache_dir;
        private string? auth_cookie = null;

        private GLib.HashTable<string, CacheEntry> lru =
            new GLib.HashTable<string, CacheEntry> (str_hash, str_equal);
        private GLib.GenericArray<string> lru_order = new GLib.GenericArray<string> ();
        private int64 lru_total_bytes = 0;

        private ImageLoader () {
            this.session = (Soup.Session) GLib.Object.new (
                                                           typeof (Soup.Session),
                                                           "user-agent", "Mozilla/5.0 (X11; Linux x86_64) Timbre/0.1",
                                                           "timeout", 12,
                                                           "max-conns", 4,
                                                           "max-conns-per-host", 2
            );

            this.disk_cache_dir = GLib.Path.build_filename (
                                                            GLib.Environment.get_user_cache_dir (), "timbre", "thumbs");
            GLib.DirUtils.create_with_parents (this.disk_cache_dir, 0755);
        }

        public void set_auth_cookie (string? cookie) {
            this.auth_cookie = cookie;
        }

        public void trim_now () {
            this.lru.remove_all ();
            this.lru_order = new GLib.GenericArray<string> ();
            this.lru_total_bytes = 0;
        }

        private static string cache_key (string url, int size, int scale) {
            return "%s@%d@%d".printf (url, size, scale);
        }

        private Gdk.Texture? lru_lookup (string key) {
            var e = this.lru.lookup (key);
            if (e == null)return null;

            int64 now = GLib.get_monotonic_time ();
            if (now - e.last_used_us > LRU_TTL_US) {
                this.lru_evict_key (key);
                return null;
            }
            e.last_used_us = now;

            for (int i = 0; i < this.lru_order.length; i++) {
                if (this.lru_order.get (i) == key) {
                    this.lru_order.remove_index (i);
                    break;
                }
            }
            this.lru_order.add (key);
            return e.texture;
        }

        private void lru_put (string key, Gdk.Texture tex) {
            int pixels = tex.get_width () * tex.get_height ();
            if (pixels > LRU_MAX_PIXELS)return;

            if (this.lru.contains (key)) {
                this.lru_evict_key (key);
            }
            var e = new CacheEntry (tex);
            this.lru.insert (key, e);
            this.lru_order.add (key);
            this.lru_total_bytes += e.bytes;

            while (this.lru_order.length > LRU_MAX_ITEMS
                   || this.lru_total_bytes > LRU_MAX_BYTES) {
                if (this.lru_order.length == 0)break;
                string oldest = this.lru_order.get (0);
                this.lru_evict_key (oldest);
            }
        }

        private void lru_evict_key (string key) {
            var e = this.lru.lookup (key);
            if (e != null) {
                this.lru_total_bytes -= e.bytes;
                this.lru.remove (key);
            }
            for (int i = 0; i < this.lru_order.length; i++) {
                if (this.lru_order.get (i) == key) {
                    this.lru_order.remove_index (i);
                    break;
                }
            }
        }

        public async Gdk.Texture? load_texture_async (
                                                      string url, Gdk.Display display, int target_size,
                                                      int scale_factor = 1, GLib.Cancellable ? cancel = null
        ) {
            if (cancel != null && cancel.is_cancelled ())return null;

            int effective_scale = scale_factor <= 1 ? 1 : scale_factor;
            string key = cache_key (url, target_size, effective_scale);

            var cached = this.lru_lookup (key);
            if (cached != null) {
                return cached;
            }

            string upgraded = get_high_res_url (url, target_size, effective_scale);
            var candidates = build_candidates (upgraded, url);

            foreach (var candidate in candidates) {
                if (cancel != null && cancel.is_cancelled ())return null;
                var tex = yield this.fetch_one_async (candidate, target_size, effective_scale, cancel);

                if (tex != null) {
                    this.lru_put (key, tex);
                    return tex;
                }
            }
            return null;
        }

        public async bool ensure_downloaded_async (string url, int target_size, int scale_factor = 1,
                                                   GLib.Cancellable? cancel = null) {
            if (cancel != null && cancel.is_cancelled ())return false;

            int effective_scale = scale_factor <= 1 ? 1 : scale_factor;
            string upgraded = get_high_res_url (url, target_size, effective_scale);
            string primary = this.disk_path (upgraded);

            if (GLib.FileUtils.test (primary, GLib.FileTest.EXISTS))return true;

            foreach (var candidate in build_candidates (upgraded, url)) {
                if (cancel != null && cancel.is_cancelled ())return false;
                var tex = yield this.fetch_one_async (candidate, target_size, effective_scale, cancel);

                if (tex != null)return true;
            }
            return false;
        }

        public string ? find_cached_path (string url, int target_size, int scale_factor = 1) {
            int effective_scale = scale_factor <= 1 ? 1 : scale_factor;
            string upgraded = get_high_res_url (url, target_size, effective_scale);

            string primary = this.disk_path (upgraded);
            if (GLib.FileUtils.test (primary, GLib.FileTest.EXISTS))return primary;

            foreach (var candidate in build_candidates (upgraded, url)) {
                string p = this.disk_path (candidate);
                if (GLib.FileUtils.test (p, GLib.FileTest.EXISTS))return p;
            }
            return null;
        }

        public string disk_path_for (string name) {
            return GLib.Path.build_filename (this.disk_cache_dir, name);
        }

        private async Gdk.Texture? fetch_one_async (
                                                    string url, int target_size, int scale_factor, GLib.Cancellable ? cancel
        ) {
            try {
                GLib.Bytes? blob = null;

                if (url.has_prefix ("file://")) {
                    string path = url.substring (7);
                    int q = path.index_of_char ('?');
                    if (q >= 0)path = path.substring (0, q);
                    blob = this.read_file_bytes (path);
                    if (blob == null)return null;
                } else {
                    blob = this.read_disk_cache (url);
                    if (blob == null) {
                        var msg = new Soup.Message ("GET", url);
                        if (this.auth_cookie != null && needs_auth (url)) {
                            msg.request_headers.append ("Cookie", this.auth_cookie);
                        }
                        blob = yield this.session.send_and_read_async (msg, Priority.DEFAULT, cancel);

                        if (msg.status_code != 200)return null;

                        this.write_disk_cache (url, blob);
                    }
                }

                if (blob == null || blob.get_size () == 0)return null;

                var stream = new MemoryInputStream.from_bytes (blob);
                var original = yield new Gdk.Pixbuf.from_stream_async (stream, cancel);
                if (original == null)return null;

                int th = target_size * scale_factor;
                int w = original.get_width ();
                int h = original.get_height ();
                if (w <= 0 || h <= 0)return null;

                Gdk.Pixbuf final_pixbuf = original;
                if (h > th) {
                    double s = (double) th / (double) h;
                    int nh = th;
                    int nw = int.max (1, (int) (w * s));
                    var scaled = original.scale_simple (nw, nh, Gdk.InterpType.BILINEAR);
                    if (scaled == null)return null;
                    final_pixbuf = scaled;
                }

                return new Gdk.MemoryTexture (
                                              final_pixbuf.get_width (),
                                              final_pixbuf.get_height (),
                                              final_pixbuf.get_has_alpha () ? Gdk.MemoryFormat.R8G8B8A8 : Gdk.MemoryFormat.R8G8B8,
                                              final_pixbuf.read_pixel_bytes (),
                                              final_pixbuf.get_rowstride ()
                );
            } catch (Error e) {
                debug ("ImageLoader: %s → %s", url, e.message);
                return null;
            }
        }

        private static void sort_samples (double[] arr, int lo, int hi) {
            if (lo >= hi)return;
            double pivot = arr[(lo + hi) / 2];
            int i = lo, j = hi;
            while (i <= j) {
                while (arr[i] < pivot)i++;
                while (arr[j] > pivot)j--;
                if (i <= j) {
                    double t = arr[i];
                    arr[i] = arr[j];
                    arr[j] = t;
                    i++;
                    j--;
                }
            }
            sort_samples (arr, lo, j);
            sort_samples (arr, i, hi);
        }

        public bool measure_stats (string path, out double median, out double p2) {
            median = 0.0;
            p2 = 0.0;
            try {
                Gdk.Pixbuf pixbuf = new Gdk.Pixbuf.from_file (path);

                int w = pixbuf.get_width ();
                int h = pixbuf.get_height ();
                if (w <= 0 || h <= 0)return false;

                int rs = pixbuf.get_rowstride ();
                int nc = pixbuf.get_n_channels ();
                unowned uint8[] data = pixbuf.get_pixels ();

                int step = int.max (1, int.max (w, h) / 100);
                int sx = (w + step - 1) / step;
                int sy = (h + step - 1) / step;
                var samples = new double[sx * sy];
                int idx = 0;

                for (int y = 0; y < h; y += step) {
                    for (int x = 0; x < w; x += step) {
                        int i = y * rs + x * nc;
                        double r = data[i] / 255.0;
                        double g = data[i + 1] / 255.0;
                        double b = data[i + 2] / 255.0;
                        r = r <= 0.04045 ? r / 12.92 : GLib.Math.pow ((r + 0.055) / 1.055, 2.4);
                        g = g <= 0.04045 ? g / 12.92 : GLib.Math.pow ((g + 0.055) / 1.055, 2.4);
                        b = b <= 0.04045 ? b / 12.92 : GLib.Math.pow ((b + 0.055) / 1.055, 2.4);
                        samples[idx++] = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                    }
                }

                if (idx == 0)return false;

                sort_samples (samples, 0, idx - 1);

                median = samples[idx / 2];
                p2 = samples[int.max (0, (int) (idx * 0.02))];
                return true;
            } catch (Error e) {
                debug ("measure_stats: %s", e.message);
                return false;
            }
        }

        private static int snap_to_step (int target) {
            int[] steps = { 60, 120, 226, 320, 544, 640, 800, 960, 1280, 1600, 1920, 2560, 4096 };
            foreach (var s in steps) {
                if (s >= target)return s;
            }
            return 4096;
        }

        public static string get_high_res_url (string url, int target_size, int scale_factor = 1) {
            int real_pixels = target_size * scale_factor;

            if (url.contains ("googleusercontent.com") || url.contains ("ggpht.com")) {
                int snapped = snap_to_step (real_pixels);
                try {
                    var r1 = new GLib.Regex ("([-=])w\\d+-h\\d+");
                    string res1 = r1.replace (url, -1, 0, "\\1w%d-h%d".printf (snapped, snapped));

                    var r2 = new GLib.Regex ("([-=])s\\d+");
                    string res2 = r2.replace (res1, -1, 0, "\\1s%d".printf (snapped));

                    return res2;
                } catch (Error e) {
                    return url;
                }
            }

            if (url.contains ("i.ytimg.com/vi/")) {
                string qual;
                if (real_pixels <= 90)qual = "default";
                else if (real_pixels <= 180)qual = "mqdefault";
                else if (real_pixels <= 360)qual = "hqdefault";
                else if (real_pixels <= 480)qual = "sddefault";
                else qual = "maxresdefault";

                int last_slash = url.last_index_of_char ('/');
                if (last_slash > 0) {
                    string base_path = url.substring (0, last_slash + 1);
                    return base_path + qual + ".jpg";
                }
            }

            return url;
        }

        private static string[] build_candidates (string primary, string original) {
            var list = new GLib.GenericArray<string> ();
            list.add (primary);

            if (primary.contains ("i.ytimg.com/vi/")) {
                string[] quals = { "maxresdefault", "sddefault", "hqdefault", "mqdefault", "default" };
                string current = "";
                foreach (var q in quals) {
                    if (primary.contains ("/" + q + ".")) { current = q; break; }
                }
                if (current.length > 0) {
                    bool past = false;
                    foreach (var q in quals) {
                        if (past)list.add (primary.replace ("/" + current + ".", "/" + q + "."));
                        if (q == current)past = true;
                    }
                }
            }

            if (original != primary) {
                bool found = false;
                for (int i = 0; i < list.length; i++) {
                    if (list.get (i) == original) { found = true; break; }
                }
                if (!found)list.add (original);
            }

            return list.steal ();
        }

        private static bool needs_auth (string url) {
            return url.contains ("ytimg.com")
                   || url.contains ("googleusercontent.com")
                   || url.contains ("ggpht.com");
        }

        private GLib.Bytes? read_file_bytes (string path) {
            try {
                var file = GLib.File.new_for_path (path);
                uint8[] bytes;
                string etag;
                if (!file.load_contents (null, out bytes, out etag))return null;
                return new GLib.Bytes (bytes);
            } catch (Error e) {
                return null;
            }
        }

        private string disk_path (string url) {
            var sum = GLib.Checksum.compute_for_string (GLib.ChecksumType.SHA1, url);
            return GLib.Path.build_filename (this.disk_cache_dir, sum);
        }

        private GLib.Bytes? read_disk_cache (string url) {
            return this.read_file_bytes (this.disk_path (url));
        }

        private void write_disk_cache (string url, GLib.Bytes blob) {
            try {
                string path = this.disk_path (url);
                string tmp = path + ".tmp";
                var tmp_file = GLib.File.new_for_path (tmp);
                tmp_file.replace_contents (blob.get_data (), null, false,
                                           GLib.FileCreateFlags.NONE, null, null);
                var dest = GLib.File.new_for_path (path);
                tmp_file.move (dest, GLib.FileCopyFlags.OVERWRITE, null, null);
            } catch (Error e) {}
        }

        public string get_disk_path (string url, int target_size, int scale_factor = 1) {
            int effective_scale = scale_factor <= 1 ? 1 : scale_factor;
            string upgraded = get_high_res_url (url, target_size, effective_scale);
            return this.disk_path (upgraded);
        }
    }
}
