namespace Timbre.Utils {
    private class CacheEntry : Object {
        public Gdk.Texture texture;
        public int64 last_access_usec;

        public CacheEntry (Gdk.Texture tex, int64 ts) {
            this.texture = tex;
            this.last_access_usec = ts;
        }
    }

    public class ImageLoader : Object {
        private static ImageLoader? instance;

        public static ImageLoader get_default () {
            if (instance == null) {
                instance = new ImageLoader ();
            }
            return instance;
        }

        private const int MAX_TEXTURE_CACHE = 12;
        private const int64 SOFT_TTL_USEC = 45 * 1000 * 1000;   // 45s
        private const int TRIM_INTERVAL_SEC = 15;

        private GLib.HashTable<string, CacheEntry> cache;
        private GLib.Queue<string> lru_order;
        private uint trim_timer_id = 0;

        private Soup.Session session;
        private string disk_cache_dir;
        private string? auth_cookie = null;

        private ImageLoader () {
            this.cache     = new GLib.HashTable<string, CacheEntry> (str_hash, str_equal);
            this.lru_order = new GLib.Queue<string> ();

            this.session = new Soup.Session ();
            this.session.user_agent = "Mozilla/5.0 (X11; Linux x86_64) Timbre/0.1";
            this.session.timeout = 12;

            this.disk_cache_dir = GLib.Path.build_filename (
                GLib.Environment.get_user_cache_dir (), "timbre", "thumbs");
            GLib.DirUtils.create_with_parents (this.disk_cache_dir, 0755);
        }

        public void set_auth_cookie (string? cookie) {
            this.auth_cookie = cookie;
        }

        public Gdk.Texture? lookup (string key) {
            var entry = this.cache.lookup (key);
            if (entry == null) return null;
            entry.last_access_usec = GLib.get_monotonic_time ();
            this.lru_order.remove (key);
            this.lru_order.push_tail (key);
            return entry.texture;
        }

        private void store (string key, Gdk.Texture tex) {
            int64 now = GLib.get_monotonic_time ();
            if (this.cache.contains (key)) {
                this.cache.replace (key, new CacheEntry (tex, now));
                this.lru_order.remove (key);
                this.lru_order.push_tail (key);
                return;
            }
            while (this.cache.size () >= MAX_TEXTURE_CACHE
                   && !this.lru_order.is_empty ()) {
                var oldest = this.lru_order.pop_head ();
                this.cache.remove (oldest);
            }
            this.cache.insert (key, new CacheEntry (tex, now));
            this.lru_order.push_tail (key);
            this.schedule_trim ();
        }

        public void forget (string url, int target_size, int scale) {
            string upgraded = get_high_res_url (url, target_size);
            string key = "%s@%dx%d".printf (upgraded, target_size, scale);
            if (this.cache.contains (key)) {
                this.cache.remove (key);
                this.lru_order.remove (key);
            }
        }

        private void schedule_trim () {
            if (this.trim_timer_id != 0) return;
            this.trim_timer_id = GLib.Timeout.add_seconds (TRIM_INTERVAL_SEC, () => {
                this.trim_timer_id = 0;
                this.trim_now ();
                return GLib.Source.REMOVE;
            });
        }

        private void trim_now () {
            if (this.cache.size () == 0) return;

            int64 now = GLib.get_monotonic_time ();
            var to_remove = new GLib.GenericArray<string> ();

            var iter = GLib.HashTableIter<string, CacheEntry> (this.cache);
            string key;
            CacheEntry entry;
            while (iter.next (out key, out entry)) {
                if (now - entry.last_access_usec > SOFT_TTL_USEC) {
                    to_remove.add (key);
                }
            }

            for (int i = 0; i < to_remove.length; i++) {
                var k = to_remove.get (i);
                this.cache.remove (k);
                this.lru_order.remove (k);
            }

            if (this.cache.size () > 0) {
                this.schedule_trim ();
            }
        }

        public void shrink_to (int target) {
            while (this.cache.size () > target
                   && !this.lru_order.is_empty ()) {
                var oldest = this.lru_order.pop_head ();
                this.cache.remove (oldest);
            }
        }

        public int cache_size () {
            return (int) this.cache.size ();
        }

        public async Gdk.Texture? load_texture_async (
            string url,
            Gdk.Display display,
            int target_size,
            int scale_factor = 1,
            GLib.Cancellable? cancel = null
        ) {
            if (cancel != null && cancel.is_cancelled ()) return null;

            string upgraded = get_high_res_url (url, target_size);
            string key = "%s@%dx%d".printf (upgraded, target_size, scale_factor);

            var cached = this.lookup (key);
            if (cached != null) return cached;

            var candidates = build_candidates (upgraded, url);

            foreach (var candidate in candidates) {
                if (cancel != null && cancel.is_cancelled ()) return null;

                var tex = yield this.fetch_one_async (
                    candidate, target_size, scale_factor, cancel);
                if (tex != null) {
                    this.store (key, tex);
                    return tex;
                }
            }
            return null;
        }

        private async Gdk.Texture? fetch_one_async (
            string url,
            int target_size,
            int scale_factor,
            GLib.Cancellable? cancel
        ) {
            try {
                GLib.Bytes? blob = null;

                if (url.has_prefix ("file://")) {
                    string path = url.substring (7);
                    int q = path.index_of_char ('?');
                    if (q >= 0) path = path.substring (0, q);
                    blob = this.read_file_bytes (path);
                    if (blob == null) return null;
                } else {
                    blob = this.read_disk_cache (url);
                    if (blob == null) {
                        var msg = new Soup.Message ("GET", url);
                        if (this.auth_cookie != null && needs_auth (url)) {
                            msg.request_headers.append ("Cookie", this.auth_cookie);
                        }
                        blob = yield this.session.send_and_read_async (
                            msg, Priority.DEFAULT, cancel);
                        if (msg.status_code != 200) return null;
                        this.write_disk_cache (url, blob);
                    }
                }

                if (blob == null || blob.get_size () == 0) return null;

                var stream = new MemoryInputStream.from_bytes (blob);
                var original = yield new Gdk.Pixbuf.from_stream_async (stream, cancel);
                if (original == null) return null;

                int tw = target_size * scale_factor;
                int w = original.get_width ();
                int h = original.get_height ();
                if (w <= 0 || h <= 0) return null;

                double s = double.max (tw / (double) w, tw / (double) h);
                int nw = (int) (w * s);
                int nh = (int) (h * s);

                Gdk.Pixbuf? scaled = original.scale_simple (
                    nw, nh, Gdk.InterpType.BILINEAR);
                if (scaled == null) return null;

                if (nw != nh) {
                    int size = int.min (nw, nh);
                    int x_off = (nw - size) / 2;
                    int y_off = (nh - size) / 2;

                    var cropped = new Gdk.Pixbuf (
                        Gdk.Colorspace.RGB,
                        scaled.get_has_alpha (),
                        scaled.get_bits_per_sample (),
                        size, size
                    );
                    scaled.copy_area (x_off, y_off, size, size, cropped, 0, 0);
                    return Gdk.Texture.for_pixbuf (cropped);
                }

                return Gdk.Texture.for_pixbuf (scaled);
            } catch (Error e) {
                debug ("ImageLoader: %s → %s", url, e.message);
                return null;
            }
        }

        public static string get_high_res_url (string url, int target_size) {
            if (url == null || url.length == 0) return url;

            if (url.contains ("i.ytimg.com")) {
                string[] quals = { "default", "mqdefault", "hqdefault", "sddefault", "maxresdefault" };
                foreach (var q in quals) {
                    if (url.contains ("/" + q + ".jpg") || url.contains ("/" + q + ".webp")) {
                        return url.replace ("/" + q + ".", "/maxresdefault.");
                    }
                }
                return url;
            }

            if (url.contains ("googleusercontent.com") || url.contains ("ggpht.com")) {
                int dim = (target_size > 0) ? target_size * 2 : 544;
                try {
                    var re = new GLib.Regex ("([=-])w\\d+-h\\d+");
                    if (re.match (url)) {
                        return re.replace (url, url.length, 0,
                                           "\\1w%d-h%d".printf (dim, dim));
                    }
                    var re2 = new GLib.Regex ("([=-])s\\d+");
                    if (re2.match (url)) {
                        return re2.replace (url, url.length, 0,
                                            "\\1s%d".printf (dim));
                    }
                } catch (Error e) { /* ignore */ }
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
                        if (past) list.add (primary.replace ("/" + current + ".", "/" + q + "."));
                        if (q == current) past = true;
                    }
                }
            }

            if (original != primary) {
                bool found = false;
                for (int i = 0; i < list.length; i++) {
                    if (list.get (i) == original) { found = true; break; }
                }
                if (!found) list.add (original);
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
                if (!file.load_contents (null, out bytes, out etag)) return null;
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
            } catch (Error e) {

            }
        }
    }
}
