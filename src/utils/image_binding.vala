namespace Timbre.Utils {

    public class ImageBinding : Object {
        private const double PREFETCH_PX = 400.0;
        private const uint HIDDEN_UNLOAD_SECS = 5;
        private const int MAX_CHECK_RETRIES = 90;
        private const int MAX_HOOK_RETRIES = 10;

        private weak Gtk.Picture? picture;
        private int target_size;
        private string fallback_icon;

        private string? current_url = null;
        private bool loaded = false;
        private bool picture_destroyed = false;
        private bool disposed = false;

        private GLib.Cancellable? cancellable = null;

        private ulong map_id = 0;
        private ulong unmap_id = 0;
        private ulong destroy_id = 0;
        private ulong height_id = 0;
        private ulong parent_id = 0;
        private uint unload_id = 0;
        private uint check_idle = 0;
        private uint hook_retry_id = 0;
        private int check_retries = 0;
        private int hook_retries = 0;

        private GLib.GenericArray<Gtk.ScrolledWindow> scrolled_ancestors;
        private GLib.GenericArray<ulong> adj_signal_ids;
        private bool hooked = false;

        public ImageBinding (Gtk.Picture picture,
            int target_size,
            string fallback_icon = "audio-x-generic-symbolic") {
            this.picture = picture;
            this.target_size = target_size;
            this.fallback_icon = fallback_icon;

            this.scrolled_ancestors = new GLib.GenericArray<Gtk.ScrolledWindow> ();
            this.adj_signal_ids = new GLib.GenericArray<ulong> ();

            this.map_id = picture.map.connect (this.on_map);
            this.unmap_id = picture.unmap.connect (this.on_unmap);
            this.destroy_id = picture.destroy.connect (this.on_picture_destroy);
            this.height_id = picture.notify["height"].connect (this.on_height_changed);
            this.parent_id = picture.notify["parent"].connect (this.on_parent_changed);

            this.apply_placeholder ();
        }

        public void load (string? url) {
            if (url == null) {
                this.current_url = null;
                var pic = this.picture;
                if (pic != null) {
                    pic.set_paintable (null);
                }
                return;
            }
            if (this.picture_destroyed)return;

            if (this.current_url == url && this.loaded && this.picture != null && this.picture.paintable != null) {
                return;
            }

            this.current_url = url;
            this.loaded = false;

            if (this.cancellable != null) {
                this.cancellable.cancel ();
                this.cancellable = null;
            }

            var pic = this.picture;
            if (pic == null)return;

            if (url.strip ().length == 0) {
                this.apply_placeholder ();
                return;
            }

            var display = pic.get_display () ?? Gdk.Display.get_default ();
            if (display == null) {
                this.apply_placeholder ();
                this.try_hook ();
                this.schedule_check ();
                return;
            }

            int scale = pic.get_scale_factor ();
            string upgraded = ImageLoader.get_high_res_url (url, this.target_size);
            string key = "%s@%dx%d".printf (upgraded, this.target_size, scale);

            var cached = ImageLoader.get_default ().lookup (key);
            if (cached != null) {
                pic.paintable = cached;
                this.loaded = true;
                return;
            }

            this.apply_placeholder ();
            this.try_hook ();
            this.start_fetch (url);
        }

        private void schedule_check () {
            if (this.picture_destroyed || this.disposed)return;
            if (this.check_idle != 0)return;

            this.check_idle = GLib.Idle.add_full (GLib.Priority.LOW, () => {
                this.check_idle = 0;
                this.check ();
                return GLib.Source.REMOVE;
            });
        }

        private void check () {
            if (this.picture_destroyed || this.disposed)return;
            var pic = this.picture;
            if (pic == null)return;

            if (!this.hooked) {
                this.try_hook ();
            }

            if (pic.get_height () <= 0 || pic.get_width () <= 0) {
                if (this.check_retries < MAX_CHECK_RETRIES) {
                    this.check_retries++;
                    this.schedule_check ();
                }
                return;
            }
            this.check_retries = 0;

            bool in_view = this.is_in_viewport ();

            if (in_view) {
                if (!this.loaded && this.current_url != null && this.cancellable == null) {
                    this.apply_placeholder ();
                    this.start_fetch (this.current_url);
                }
                if (this.unload_id != 0) {
                    GLib.Source.remove (this.unload_id);
                    this.unload_id = 0;
                }
            } else if (this.loaded && this.unload_id == 0) {
                this.schedule_unload ();
            }
        }

        private void try_hook () {
            if (this.hooked)return;
            this.hook_scrolled ();
            if (this.hooked) {
                this.schedule_check ();
                return;
            }
            this.schedule_hook_retry ();
        }

        private void schedule_hook_retry () {
            if (this.hook_retry_id != 0)return;
            if (this.hook_retries >= MAX_HOOK_RETRIES)return;
            this.hook_retries++;
            this.hook_retry_id = GLib.Timeout.add (100, () => {
                this.hook_retry_id = 0;
                if (this.picture_destroyed || this.disposed)return GLib.Source.REMOVE;
                if (this.hooked)return GLib.Source.REMOVE;
                this.try_hook ();
                return GLib.Source.REMOVE;
            });
        }

        private void hook_scrolled () {
            if (this.hooked)return;
            var pic = this.picture;
            if (pic == null)return;

            Gtk.Widget? w = pic.get_parent ();
            bool found_any = false;

            while (w != null) {
                if (w is Gtk.ScrolledWindow) {
                    var sw = (Gtk.ScrolledWindow) w;
                    this.scrolled_ancestors.add (sw);

                    var vadj = sw.get_vadjustment ();
                    var hadj = sw.get_hadjustment ();

                    if (vadj != null) {
                        this.adj_signal_ids.add (vadj.value_changed.connect (this.on_viewport_changed));
                        this.adj_signal_ids.add (vadj.changed.connect (this.on_viewport_changed));
                    } else {
                        this.adj_signal_ids.add (0);
                        this.adj_signal_ids.add (0);
                    }
                    if (hadj != null) {
                        this.adj_signal_ids.add (hadj.value_changed.connect (this.on_viewport_changed));
                        this.adj_signal_ids.add (hadj.changed.connect (this.on_viewport_changed));
                    } else {
                        this.adj_signal_ids.add (0);
                        this.adj_signal_ids.add (0);
                    }
                    found_any = true;
                }
                w = w.get_parent ();
            }

            this.hooked = found_any;
        }

        private void unhook_scrolled () {
            int slot = 0;
            for (int i = 0; i < this.scrolled_ancestors.length; i++) {
                var sw = this.scrolled_ancestors.get (i);
                if (sw != null) {
                    var vadj = sw.get_vadjustment ();
                    var hadj = sw.get_hadjustment ();
                    if (vadj != null) {
                        var id1 = this.adj_signal_ids.get (slot + 0);
                        if (id1 != 0)vadj.disconnect (id1);
                        var id2 = this.adj_signal_ids.get (slot + 1);
                        if (id2 != 0)vadj.disconnect (id2);
                    }
                    if (hadj != null) {
                        var id3 = this.adj_signal_ids.get (slot + 2);
                        if (id3 != 0)hadj.disconnect (id3);
                        var id4 = this.adj_signal_ids.get (slot + 3);
                        if (id4 != 0)hadj.disconnect (id4);
                    }
                }
                slot += 4;
            }
            this.scrolled_ancestors = new GLib.GenericArray<Gtk.ScrolledWindow> ();
            this.adj_signal_ids = new GLib.GenericArray<ulong> ();
            this.hooked = false;
            this.hook_retries = 0;
        }

        private void on_viewport_changed () {
            this.schedule_check ();
        }

        private void on_map () {
            if (this.picture_destroyed || this.disposed)return;

            if (this.unload_id != 0) {
                GLib.Source.remove (this.unload_id);
                this.unload_id = 0;
            }

            this.try_hook ();
            this.check_retries = 0;
            this.schedule_check ();
        }

        private void on_parent_changed () {
            if (this.picture_destroyed || this.disposed)return;
            if (!this.hooked) {
                this.try_hook ();
            }
        }

        private void on_height_changed () {
            this.schedule_check ();
        }

        private void on_unmap () {
            if (this.picture_destroyed || this.disposed)return;

            this.unhook_scrolled ();

            if (this.cancellable != null)return;
            if (this.unload_id != 0)return;

            this.schedule_unload ();
        }

        private void on_picture_destroy () {
            this.picture_destroyed = true;
            this.teardown ();
        }

        private void schedule_unload () {
            if (this.unload_id != 0)return;
            this.unload_id = GLib.Timeout.add_seconds (HIDDEN_UNLOAD_SECS, () => {
                this.unload_id = 0;
                if (this.picture_destroyed || this.disposed)return GLib.Source.REMOVE;
                if (this.is_in_viewport ())return GLib.Source.REMOVE;

                var pic = this.picture;
                if (pic == null)return GLib.Source.REMOVE;

                var url = this.current_url;
                if (url != null) {
                    ImageLoader.get_default ().forget (
                                                       url, this.target_size, pic.get_scale_factor ()
                    );
                }

                pic.set_paintable (null);
                this.apply_placeholder ();
                this.loaded = false;
                return GLib.Source.REMOVE;
            });
        }

        private bool is_in_viewport () {
            var pic = this.picture;
            if (pic == null)return false;
            if (!pic.get_mapped ())return false;

            int pw = pic.get_width ();
            int ph = pic.get_height ();
            if (pw <= 0 || ph <= 0)return false;

            if (this.scrolled_ancestors.length == 0)return true;

            for (int i = 0; i < this.scrolled_ancestors.length; i++) {
                var sw = this.scrolled_ancestors.get (i);
                if (sw == null)continue;
                if (!sw.get_mapped ())continue;

                int sw_w = sw.get_width ();
                int sw_h = sw.get_height ();
                if (sw_w <= 0 || sw_h <= 0)continue;

                Graphene.Point in_pt = Graphene.Point () { x = 0, y = 0 };
                Graphene.Point out_pt;
                if (!pic.compute_point (sw, in_pt, out out_pt))continue;

                double left = out_pt.x;
                double right = left + pw;
                double top = out_pt.y;
                double bottom = top + ph;

                if (right < -PREFETCH_PX || left > sw_w + PREFETCH_PX) {
                    return false;
                }
                if (bottom < -PREFETCH_PX || top > sw_h + PREFETCH_PX) {
                    return false;
                }
            }

            return true;
        }

        private void start_fetch (string url) {
            if (this.picture_destroyed || this.disposed)return;
            if (this.cancellable != null)return;

            var pic = this.picture;
            if (pic == null)return;
            var display = pic.get_display () ?? Gdk.Display.get_default ();
            if (display == null)return;

            int scale = pic.get_scale_factor ();
            int target = this.target_size;

            var cancel = new GLib.Cancellable ();
            this.cancellable = cancel;

            string requested = url;

            ImageLoader.get_default ().load_texture_async.begin (
                                                                 url, display, target, scale, cancel,
                                                                 (obj, res) => {
                Gdk.Texture? tex = null;
                try {
                    tex = ImageLoader.get_default ().load_texture_async.end (res);
                } catch (GLib.Error e) {
                    // Trata erros de cancelamento ou falhas de rede sem crashar
                }

                if (this.cancellable == cancel) {
                    this.cancellable = null;
                }
                if (this.picture_destroyed || this.disposed)return;
                if (this.current_url != requested)return;

                if (tex != null) {
                    var p = this.picture;
                    if (p == null)return;
                    p.paintable = tex;
                    this.loaded = true;
                    if (!this.is_in_viewport () && this.unload_id == 0) {
                        this.schedule_unload ();
                    }
                }
            });
        }

        private void apply_placeholder () {
            if (this.picture_destroyed || this.disposed)return;
            var pic = this.picture;
            if (pic == null)return;
            var display = pic.get_display () ?? Gdk.Display.get_default ();
            if (display == null)return;

            var theme = Gtk.IconTheme.get_for_display (display);
            int scale = pic.get_scale_factor ();
            var paintable = theme.lookup_icon (
                                               this.fallback_icon, null, this.target_size, scale,
                                               Gtk.TextDirection.NONE, Gtk.IconLookupFlags.FORCE_SYMBOLIC
            );
            if (paintable != null) {
                pic.paintable = paintable;
            }
        }

        private void teardown () {
            if (this.cancellable != null) {
                this.cancellable.cancel ();
                this.cancellable = null;
            }
            if (this.unload_id != 0) {
                GLib.Source.remove (this.unload_id);
                this.unload_id = 0;
            }
            if (this.check_idle != 0) {
                GLib.Source.remove (this.check_idle);
                this.check_idle = 0;
            }
            if (this.hook_retry_id != 0) {
                GLib.Source.remove (this.hook_retry_id);
                this.hook_retry_id = 0;
            }

            var pic = this.picture;
            if (pic != null) {
                pic.set_paintable (null);

                if (this.map_id != 0)pic.disconnect (this.map_id);
                if (this.unmap_id != 0)pic.disconnect (this.unmap_id);
                if (this.destroy_id != 0)pic.disconnect (this.destroy_id);
                if (this.height_id != 0)pic.disconnect (this.height_id);
                if (this.parent_id != 0)pic.disconnect (this.parent_id);
            }
            this.map_id = 0;
            this.unmap_id = 0;
            this.destroy_id = 0;
            this.height_id = 0;
            this.parent_id = 0;

            this.unhook_scrolled ();

            this.picture_destroyed = true;
            this.picture = null;
            this.current_url = null;
        }

        public override void dispose () {
            if (this.disposed)return;
            this.disposed = true;
            this.teardown ();
            base.dispose ();
        }

        ~ImageBinding () {
            // GLib.debug ("ImageBinding successfully destroyed");
        }
    }
}
