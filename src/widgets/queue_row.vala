namespace Timbre {
    public class QueueRow : Gtk.Box {
        private Gtk.Image grip;
        private Gtk.Stack stack;
        private Gtk.Label label_idx;
        private Gtk.Label label_title;
        private Gtk.Label label_artist;

        private Timbre.QueueItem? current_item = null;
        private ulong notify_playing_id = 0;
        private ulong notify_index_id = 0;
        private bool torn_down = false;

        public signal void item_moved (int from_index, int to_index);

        public QueueRow () {
            Object (orientation : Gtk.Orientation.HORIZONTAL, spacing: 8);

            unowned var self = this;

            this.grip = new Gtk.Image.from_icon_name ("list-drag-handle-symbolic");
            this.grip.add_css_class ("dim-label");
            this.append (this.grip);

            this.stack = new Gtk.Stack ();
            this.label_idx = new Gtk.Label ("");
            this.label_idx.width_chars = 3;
            this.label_idx.add_css_class ("dim-label");

            var icon_play = new Gtk.Image.from_icon_name ("media-playback-start-symbolic");
            icon_play.add_css_class ("accent");

            this.stack.add_named (this.label_idx, "index");
            this.stack.add_named (icon_play, "playing");
            this.append (this.stack);

            var txt_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            txt_box.hexpand = true;
            txt_box.valign = Gtk.Align.CENTER;

            this.label_title = new Gtk.Label ("");
            this.label_title.halign = Gtk.Align.START;
            this.label_title.ellipsize = Pango.EllipsizeMode.END;

            this.label_artist = new Gtk.Label ("");
            this.label_artist.halign = Gtk.Align.START;
            this.label_artist.ellipsize = Pango.EllipsizeMode.END;
            this.label_artist.add_css_class ("caption");
            this.label_artist.add_css_class ("dim-label");

            txt_box.append (this.label_title);
            txt_box.append (this.label_artist);
            this.append (txt_box);

            this.setup_dnd ();
            this.setup_gestures ();

            this.destroy.connect (() => {
                self.torn_down = true;
                self.unbind ();
            });
        }

        private void setup_gestures () {
            unowned var self = this;

            var secondary_click = new Gtk.GestureClick () {
                button = Gdk.BUTTON_SECONDARY
            };
            secondary_click.released.connect ((n_press, x, y) => {
                self.show_context_menu (x, y);
            });
            this.add_controller (secondary_click);

            var long_press = new Gtk.GestureLongPress () {
                touch_only = false
            };
            long_press.pressed.connect ((x, y) => {
                self.show_context_menu (x, y);
            });
            this.add_controller (long_press);
        }

        private void show_context_menu (double x, double y) {
            if (this.current_item == null)return;

            var win = this.get_root () as Timbre.Window;
            if (win == null)return;

            unowned var self = this;
            var track = this.current_item.track;
            var menu = new GLib.Menu ();

            var section1 = new GLib.Menu ();
            section1.append ("Start Radio", "widget.radio");
            section1.append ("Play Next", "widget.add_next");
            section1.append ("Add to Queue", "widget.add_queue");
            menu.append_section (null, section1);

            var section2 = new GLib.Menu ();
            bool has_album = track.album != null && track.album.id != null && track.album.id != "";
            bool has_artist = track.artists.length > 0 && track.artists.get (0).id != null && track.artists.get (0).id != "";

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
            if (this.current_item == null)return;

            var win = this.get_root () as Timbre.Window;
            if (win == null)return;

            var track = this.current_item.track;

            switch (action_name) {
            case "radio":
                win.play_radio (track.id, false);
                break;
            case "add_next":
                var tracks = new GenericArray<Timbre.Track> ();
                tracks.add (track);
                win.play_next (tracks);
                break;
            case "add_queue":
                var tracks = new GenericArray<Timbre.Track> ();
                tracks.add (track);
                win.add_to_queue (tracks);
                break;
            case "go_album":
                if (track.album != null && track.album.id != null) {
                    win.open_collection_from_row (track.album.id, "Album",
                                                  track.album.name,
                                                  track.artists_text (),
                                                  track.thumb);
                }
                break;
            case "go_artist":
                if (track.artists.length > 0) {
                    var first_artist = track.artists.get (0);
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
                clipboard.set_text ("https://music.youtube.com/watch?v=" + track.id);
                break;
            }
        }

        private void setup_dnd () {
            var drag_source = new Gtk.DragSource ();
            drag_source.actions = Gdk.DragAction.MOVE;

            drag_source.prepare.connect ((x, y) => {
                if (this.current_item == null)return null;
                var val = Value (typeof (string));
                val.set_string (this.current_item.index.to_string ());
                return new Gdk.ContentProvider.for_value (val);
            });

            drag_source.drag_begin.connect ((drag) => {
                var paintable = new Gtk.WidgetPaintable (this);
                drag_source.set_icon (paintable, (int) this.get_width () / 2, (int) this.get_height () / 2);
            });

            this.grip.add_controller (drag_source);

            var drop_target = new Gtk.DropTarget (typeof (string), Gdk.DragAction.MOVE);
            drop_target.drop.connect ((val, x, y) => {
                string? str_val = val.get_string ();
                if (str_val == null || this.current_item == null)return false;

                int from_index = int.parse (str_val);
                int to_index = this.current_item.index;
                if (from_index == to_index)return false;

                this.item_moved (from_index, to_index);
                return true;
            });

            this.add_controller (drop_target);
        }

        public void unbind () {
            if (this.torn_down && this.current_item == null)return;

            var item = this.current_item;
            if (item != null) {
                if (this.notify_playing_id != 0) {
                    item.disconnect (this.notify_playing_id);
                }
                if (this.notify_index_id != 0) {
                    item.disconnect (this.notify_index_id);
                }
            }
            this.notify_playing_id = 0;
            this.notify_index_id = 0;
            this.current_item = null;
        }

        public void bind (Timbre.QueueItem queue_item) {
            if (this.torn_down)return;
            this.unbind ();

            this.current_item = queue_item;
            this.label_title.label = queue_item.track.title;
            this.label_artist.label = queue_item.track.artists_text ();

            this.update_state ();

            this.notify_playing_id = queue_item.notify["is-playing"].connect (() => {
                if (this.torn_down)return;
                this.update_state ();
            });
            this.notify_index_id = queue_item.notify["index"].connect (() => {
                if (this.torn_down)return;
                this.update_state ();
            });
        }

        private void update_state () {
            if (this.torn_down)return;
            var item = this.current_item;
            if (item == null)return;

            if (item.is_playing) {
                this.stack.visible_child_name = "playing";
                this.label_title.add_css_class ("heading");
            } else {
                this.stack.visible_child_name = "index";
                this.label_idx.label = "%d".printf (item.index + 1);
                this.label_title.remove_css_class ("heading");
            }
        }

        public override void dispose () {
            this.torn_down = true;
            this.unbind ();
            base.dispose ();
        }
    }
}
