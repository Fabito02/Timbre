namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/widgets/home_speed_tile_card.ui")]
    public class HomeSpeedTileCard : Gtk.Button {
        public MediaItem media_item { get; private set; }

        [GtkChild] private unowned Gtk.Picture image_cover;
        [GtkChild] private unowned Gtk.Label label_title;
        [GtkChild] private unowned Gtk.Label explicit_badge;
        [GtkChild] private unowned Adw.Bin live_badge;
        [GtkChild] private unowned Adw.Bin album_overlay;
        [GtkChild] private unowned Adw.Bin play_overlay;
        [GtkChild] private unowned Gtk.GestureClick secondary_click;
        [GtkChild] private unowned Gtk.GestureLongPress long_press_gesture;

        private Timbre.Utils.ImageBinding cover_binding;
        private bool released = false;

        public HomeSpeedTileCard (MediaItem item) {
            Object ();
            this.media_item = item;

            this.label_title.label = item.title;

            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 120);
            this.cover_binding.load (item.thumb);

            if (item.kind == ItemKind.ARTIST) {
                this.add_css_class ("artist");
            }

            this.play_overlay.visible = item.kind.is_playable ();
            this.album_overlay.visible = (item.kind == ItemKind.ALBUM);
            this.explicit_badge.visible = item.explicit;
            this.live_badge.visible = item.is_live;

            this.setup_gestures ();
        }

        private void setup_gestures () {
            unowned var self = this;
            this.secondary_click.released.connect ((n_press, x, y) => {
                if (self.released)return;
                self.show_context_menu (x, y);
            });
            this.long_press_gesture.pressed.connect ((x, y) => {
                if (self.released)return;
                self.show_context_menu (x, y);
            });
        }

        private void show_context_menu (double x, double y) {
            var win = this.get_root () as Timbre.Window;
            if (win == null)return;

            unowned var self = this;
            var menu = new GLib.Menu ();

            var section1 = new GLib.Menu ();
            section1.append ("Start Radio", "widget.radio");
            section1.append ("Play Next", "widget.add_next");
            section1.append ("Add to Queue", "widget.add_queue");
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
            section3.append ("Add to Playlist...", "widget.add_playlist");
            section3.append ("Copy Link", "widget.copy_link");
            menu.append_section (null, section3);

            var actions = new GLib.SimpleActionGroup ();

            var radio = new GLib.SimpleAction ("radio", null);
            radio.activate.connect (() => { if (!self.released)self.handle_action ("radio"); });
            actions.add_action (radio);

            var add_queue = new GLib.SimpleAction ("add_queue", null);
            add_queue.activate.connect (() => { if (!self.released)self.handle_action ("add_queue"); });
            actions.add_action (add_queue);

            var add_next = new GLib.SimpleAction ("add_next", null);
            add_next.activate.connect (() => { if (!self.released)self.handle_action ("add_next"); });
            actions.add_action (add_next);

            if (has_album) {
                var go_album = new GLib.SimpleAction ("go_album", null);
                go_album.activate.connect (() => { if (!self.released)self.handle_action ("go_album"); });
                actions.add_action (go_album);
            }

            if (has_artist) {
                var go_artist = new GLib.SimpleAction ("go_artist", null);
                go_artist.activate.connect (() => { if (!self.released)self.handle_action ("go_artist"); });
                actions.add_action (go_artist);
            }

            var download = new GLib.SimpleAction ("download", null);
            download.activate.connect (() => { if (!self.released)self.handle_action ("download"); });
            actions.add_action (download);

            var add_playlist = new GLib.SimpleAction ("add_playlist", null);
            add_playlist.activate.connect (() => { if (!self.released)self.handle_action ("add_playlist"); });
            actions.add_action (add_playlist);

            var copy_link = new GLib.SimpleAction ("copy_link", null);
            copy_link.activate.connect (() => { if (!self.released)self.handle_action ("copy_link"); });
            actions.add_action (copy_link);

            var popover = new Gtk.PopoverMenu.from_model (menu);
            popover.has_arrow = false;
            popover.halign = Gtk.Align.START;
            popover.set_parent (this);
            popover.insert_action_group ("widget", actions);

            weak Gtk.Popover popover_weak = popover;
            popover.closed.connect (() => {
                GLib.Idle.add (() => {
                    if (popover_weak != null && popover_weak.get_parent () != null) {
                        popover_weak.unparent ();
                    }
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
            if (this.released)return;
            var win = this.get_root () as Timbre.Window;
            if (win == null)return;

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
                GLib.message ("Download");
                break;
            case "add_playlist":
                GLib.message ("Added to playlist");
                break;
            case "copy_link":
                var clipboard = Gdk.Display.get_default ().get_clipboard ();
                clipboard.set_text ("https://music.youtube.com/watch?v=" + this.media_item.id);
                break;
            }
        }

        public void release () {
            if (this.released)return;
            this.released = true;

            if (this.cover_binding != null) {
                this.cover_binding.dispose ();
                this.cover_binding = null;
            }

            if (this.image_cover != null) {
                this.image_cover.set_paintable (null);
            }

            this.media_item = null;
        }

        public override void dispose () {
            this.release ();
            base.dispose ();
        }
    }
}
