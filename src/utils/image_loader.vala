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

        private const int MAX_TEXTURE_CACHE = 8;
        private const int64 HARD_MEMORY_LIMIT = 16 * 1024 * 1024;
        private int64 current_cache_bytes = 0;
        private const int64 SOFT_TTL_USEC = 10 * 1000 * 1000; // 10s
        private const int TRIM_INTERVAL_SEC = 15;

        private GLib.HashTable<string, CacheEntry> cache;
        private uint trim_timer_id = 0;

        private Soup.Session session;
        private string disk_cache_dir;
        private string? auth_cookie = null;

        private ImageLoader () {
            this.cache = new GLib.HashTable<string, CacheEntry> (str_hash, str_equal);

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
            if (entry == null)return null;
            entry.last_access_usec = GLib.get_monotonic_time ();
            return entry.texture;
        }

        private int64 texture_bytes (Gdk.Texture tex) {
            int w = tex.get_width ();
            int h = tex.get_height ();
            return (int64) w * h * 4;
        }

        private void evict_oldest () {
            string? oldest_key = null;
            int64 oldest_ts = int64.MAX;

            var iter = GLib.HashTableIter<string, CacheEntry> (this.cache);
            string key;
            CacheEntry entry;
            while (iter.next (out key, out entry)) {
                if (entry.last_access_usec < oldest_ts) {
                    oldest_ts = entry.last_access_usec;
                    oldest_key = key;
                }
            }

            if (oldest_key != null) {
                var old = this.cache.lookup (oldest_key);
                if (old != null) {
                    this.current_cache_bytes -= texture_bytes (old.texture);
                }
                this.cache.remove (oldest_key);
            }
        }

        private void store (string key, Gdk.Texture tex) {
            int64 now = GLib.get_monotonic_time ();
            int64 bytes = texture_bytes (tex);

            if (this.cache.contains (key)) {
                var old = this.cache.lookup (key);
                if (old != null) {
                    this.current_cache_bytes -= texture_bytes (old.texture);
                }
                this.cache.replace (key, new CacheEntry (tex, now));
                this.current_cache_bytes += bytes;
                return;
            }

            while ((this.current_cache_bytes + bytes > HARD_MEMORY_LIMIT
                    || this.cache.size () >= MAX_TEXTURE_CACHE)
                   && this.cache.size () > 0) {
                this.evict_oldest ();
            }

            this.cache.insert (key, new CacheEntry (tex, now));
            this.current_cache_bytes += bytes;
            this.schedule_trim ();
        }

        public void forget (string url, int target_size, int scale) {
            string upgraded = get_high_res_url (url, target_size, scale);
            string key = "%s@%dx%d".printf (upgraded, target_size, scale);
            if (this.cache.contains (key)) {
                var old = this.cache.lookup (key);
                if (old != null) {
                    this.current_cache_bytes -= texture_bytes (old.texture);
                }
                this.cache.remove (key);
            }
        }

        private void schedule_trim () {
            if (this.trim_timer_id != 0)return;
            this.trim_timer_id = GLib.Timeout.add_seconds (TRIM_INTERVAL_SEC, () => {
                this.trim_timer_id = 0;
                this.trim_now ();
                return GLib.Source.REMOVE;
            });
        }

        private void trim_now () {
            if (this.cache.size () == 0)return;

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
                var old = this.cache.lookup (k);
                if (old != null) {
                    this.current_cache_bytes -= texture_bytes (old.texture);
                }
                this.cache.remove (k);
            }

            if (this.cache.size () > 0) {
                this.schedule_trim ();
            }
        }

        public void shrink_to (int target) {
            while (this.cache.size () > target) {
                int before = (int) this.cache.size ();
                this.evict_oldest ();
                if ((int) this.cache.size () == before) {
                    break;
                }
            }
        }

        public int cache_size () {
            return (int) this.cache.size ();
        }

        public int64 cache_bytes () {
            return this.current_cache_bytes;
        }

        public async Gdk.Texture? load_texture_async (
                                                      string url,
                                                      Gdk.Display display,
                                                      int target_size,
                                                      int scale_factor = 1,
                                                      GLib.Cancellable ? cancel = null
        ) {
            if (cancel != null && cancel.is_cancelled ())return null;

            int effective_scale = scale_factor <= 1 ? 1 : scale_factor;

            string upgraded = get_high_res_url (url, target_size, effective_scale);

            string key = "%s@%dx%d".printf (upgraded, target_size, effective_scale);

            var cached = this.lookup (key);
            if (cached != null)return cached;

            var candidates = build_candidates (upgraded, url);

            foreach (var candidate in candidates) {
                if (cancel != null && cancel.is_cancelled ())return null;

                var tex = yield this.fetch_one_async (candidate, target_size, effective_scale, cancel);

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
                                                    GLib.Cancellable ? cancel
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

                    var scaled = original.scale_simple (
                                                        nw, nh, Gdk.InterpType.BILINEAR);

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

        public static string get_high_res_url (string url, int target_size, int min = 512, int scale_factor = 1) {
            int real_pixels = target_size * scale_factor;
            int min_res = int.max (real_pixels, min);

            if (url.contains ("googleusercontent.com") || url.contains ("ggpht.com")) {
                try {
                    var r1 = new GLib.Regex ("([-=])w\\d+-h\\d+");
                    string res1 = r1.replace (url, -1, 0, "\\1w%d-h%d".printf (min_res, min_res));

                    var r2 = new GLib.Regex ("([-=])s\\d+");
                    string res2 = r2.replace (res1, -1, 0, "\\1s%d".printf (min_res));

                    return res2;
                } catch (Error e) {
                    return url;
                }
            }

            if (url.contains ("i.ytimg.com/vi/")) {
                int last_slash = url.last_index_of_char ('/');
                if (last_slash > 0) {
                    string base_path = url.substring (0, last_slash + 1);
                    return base_path + "maxresdefault.jpg";
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
            } catch (Error e) {
            }
        }

        public string get_disk_path (string url, int target_size, int scale_factor = 1) {
            int effective_scale = scale_factor <= 1 ? 1 : scale_factor;
            string upgraded = get_high_res_url (url, target_size, 512, effective_scale);
            return this.disk_path (upgraded);
        }
    }
}
