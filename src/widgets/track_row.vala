namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/widgets/track_row.ui")]
    public class TrackRow : Gtk.ListBoxRow {
        [GtkChild] private unowned Gtk.Picture image_cover;
        [GtkChild] private unowned Gtk.Label label_title;
        [GtkChild] private unowned Gtk.Label label_artist;
        [GtkChild] private unowned Gtk.Label label_duration;
        [GtkChild] private unowned Gtk.Box like_slot;
        [GtkChild] private unowned Gtk.Label explicit_badge;
        [GtkChild] private unowned Gtk.Box live_badge;
        [GtkChild] private unowned Gtk.GestureClick secondary_click;
        [GtkChild] private unowned Gtk.GestureLongPress long_press_gesture;

        public MediaItem media_item { get; private set; }
        public string track_id { get { return media_item.id; } }
        public string track_title { get { return media_item.title; } }
        public string track_artist { owned get { return media_item.artists_text (); } }
        public string? track_cover { get { return media_item.thumb; } }
        public uint64 duration_secs { get { return (uint64)(media_item.duration_seconds ?? 0); } }
        public bool is_live { get { return media_item.is_live; } }
        public bool explicit { get { return media_item.explicit; } }

        private Timbre.Utils.ImageBinding cover_binding;
        private Timbre.LikeButton? like_btn = null;
        private bool released = false;

        public TrackRow.empty () {
            Object ();
            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 48);
            this.cover_binding.load (null);
            this.explicit_badge.visible = false;
            this.live_badge.visible = false;
            this.setup_gestures ();
        }

        public TrackRow (Timbre.Player player, MediaItem item) {
            Object ();
            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 48);
            this.like_btn = new Timbre.LikeButton (player);
            this.like_slot.append (this.like_btn);
            this.setup_gestures ();
            this.set_content (item);
        }

        public TrackRow.simple (MediaItem item) {
            Object ();
            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 48);
            this.setup_gestures ();
            this.set_content (item);
        }

        private void setup_gestures () {
            unowned var self = this;
        
            this.secondary_click.released.connect ((n_press, x, y) => {
                self.show_context_menu (x, y);
            });
        
            this.long_press_gesture.pressed.connect ((x, y) => {
                self.show_context_menu (x, y);
            });
        }

        private void show_context_menu (double x, double y) {
            var win = this.get_root () as Timbre.Window;
            if (win == null) return;

            unowned var self = this;
            var menu = new GLib.Menu ();

            var section1 = new GLib.Menu ();
            section1.append ("Start Radio", "widget.radio");
            section1.append ("Play Next",  "widget.add_next");
            section1.append ("Add to Queue",   "widget.add_queue");
            menu.append_section (null, section1);

            var section2 = new GLib.Menu ();
            bool has_album = this.media_item.album != null && this.media_item.album.id != null && this.media_item.album.id != "";
            bool has_artist = this.media_item.artists.length > 0 && this.media_item.artists.get (0).id != null && this.media_item.artists.get (0).id != "";

            if (has_album) {
                section2.append ("Go to Album", "widget.go_album");
            }
            if (has_artist) {
                section2.append ("Go to Artist", "widget.go_artist");
            }
            if (section2.get_n_items () > 0) {
                menu.append_section (null, section2);
            }

            var section3 = new GLib.Menu ();
            section3.append ("Download", "widget.download");
            section3.append ("Add to Playlist…", "widget.add_playlist");
            section3.append ("Copy Link", "widget.copy_link");
            menu.append_section (null, section3);

            var actions = new GLib.SimpleActionGroup ();

            var radio = new GLib.SimpleAction ("radio", null);
            radio.activate.connect (() => self.handle_action ("radio"));
            actions.add_action (radio);

            var add_queue = new GLib.SimpleAction ("add_queue", null);
            add_queue.activate.connect (() => self.handle_action ("add_queue"));
            actions.add_action (add_queue);

            var add_next = new GLib.SimpleAction ("add_next", null);
            add_next.activate.connect (() => self.handle_action ("add_next"));
            actions.add_action (add_next);

            if (has_album) {
                var go_album = new GLib.SimpleAction ("go_album", null);
                go_album.activate.connect (() => self.handle_action ("go_album"));
                actions.add_action (go_album);
            }

            if (has_artist) {
                var go_artist = new GLib.SimpleAction ("go_artist", null);
                go_artist.activate.connect (() => self.handle_action ("go_artist"));
                actions.add_action (go_artist);
            }

            var download = new GLib.SimpleAction ("download", null);
            download.activate.connect (() => self.handle_action ("download"));
            actions.add_action (download);

            var add_playlist = new GLib.SimpleAction ("add_playlist", null);
            add_playlist.activate.connect (() => self.handle_action ("add_playlist"));
            actions.add_action (add_playlist);

            var copy_link = new GLib.SimpleAction ("copy_link", null);
            copy_link.activate.connect (() => self.handle_action ("copy_link"));
            actions.add_action (copy_link);

            var popover = new Gtk.PopoverMenu.from_model (menu);
            popover.has_arrow = false;
            popover.halign = Gtk.Align.START;
            popover.set_parent (this);

            popover.insert_action_group ("widget", actions);

            unowned Gtk.Popover popover_ref = popover;
            popover.closed.connect (() => {
                GLib.Idle.add (() => {
                    popover_ref.unparent ();
                    return GLib.Source.REMOVE;
                });
            });

            var rect = Gdk.Rectangle () {
                x = (int) x,
                y = (int) y,
                width = 1,
                height = 1
            };
            popover.pointing_to = rect;
            popover.popup ();
        }

        private void handle_action (string action_name) {
            var win = this.get_root () as Timbre.Window;
            if (win == null) return;

            switch (action_name) {
                case "radio":
                    win.play_radio (this.media_item.id, false);
                    break;
                case "add_next":
                    var tracks = new GenericArray<Timbre.Track> ();
                    tracks.add (this.media_item.to_track ());
                    win.play_next (tracks);
                    break;
                case "add_queue":
                    var tracks = new GenericArray<Timbre.Track> ();
                    tracks.add (this.media_item.to_track ());
                    win.add_to_queue (tracks);
                    break;
                case "go_album":
                    if (this.media_item.album != null && this.media_item.album.id != null) {
                        win.open_collection_from_row (this.media_item.album.id, "Album",
                                                      this.media_item.album.name,
                                                      this.media_item.artists_text (),
                                                      this.media_item.thumb);
                    }
                    break;
                case "go_artist":
                    if (this.media_item.artists.length > 0) {
                        var first_artist = this.media_item.artists.get (0);
                        if (first_artist.id != null) {
                            win.open_artist_from_row (first_artist.id, first_artist.name);
                        }
                    }
                    break;
                case "download":
                    GLib.message ("Download clicado");
                    break;
                case "add_playlist":
                    GLib.message ("Adicionar à playlist clicado");
                    break;
                case "copy_link":
                    var clipboard = Gdk.Display.get_default ().get_clipboard ();
                    clipboard.set_text ("https://music.youtube.com/watch?v=" + this.media_item.id);
                    break;
            }
        }

        public void set_content (MediaItem item) {
            this.media_item = item;
            this.label_title.label = item.title;
            this.label_artist.label = item.subtitle_text ();

            int s = (int) (item.duration_seconds ?? 0);
            this.label_duration.label = "%d:%02d".printf (s / 60, s % 60);
            this.label_duration.visible = (s > 0) && !item.is_live;

            this.cover_binding.load (item.thumb);

            if (this.like_btn != null) {
                string? vid = (item.id != null && item.id.length > 0) ? item.id : null;
                LikeStatus? status = null;
                if (item is Track) {
                    status = ((Track) item).like_status;
                }
                this.like_btn.set_target (vid, status);
            }

            if (item.kind == ItemKind.ARTIST) {
                this.add_css_class ("artist");
            }

            this.explicit_badge.visible = item.explicit;
            this.live_badge.visible = item.is_live;
        }

        public void release () {
            if (this.released) return;
            this.released = true;

            if (this.like_btn != null) {
                var btn = this.like_btn;
                this.like_btn = null;
                if (btn.get_parent () != null) {
                    btn.unparent ();
                }
                btn.dispose ();
            }

            if (this.cover_binding != null) {
                this.cover_binding.dispose ();
                this.cover_binding = null;
            }

            if (this.image_cover != null) {
                this.image_cover.set_paintable (null);
            }

            this.media_item = null;
        }

        ~TrackRow () {
            // GLib.debug ("TrackRow successfully destroyed");
        }

        public override void dispose () {
            this.release ();
            base.dispose ();
        }
    }
}
