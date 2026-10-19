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

        [GtkChild] private unowned Gtk.PopoverMenu context_menu;
        [GtkChild] private unowned Gtk.GestureClick secondary_click;

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
        private GLib.SimpleActionGroup? actions = null;

        private void setup_context_menu () {
            var menu = new GLib.Menu ();

            var section1 = new GLib.Menu ();
            section1.append ("Start Radio", "widget.radio");
            section1.append ("Play Next",  "widget.add_next");
            section1.append ("Add to Queue",   "widget.add_queue");
            menu.append_section (null, section1);

            var section2 = new GLib.Menu ();
            section2.append ("Go to Album", "widget.go_album");
            section2.append ("Go to Artist", "widget.go_playlist");
            menu.append_section (null, section2);

            var section3 = new GLib.Menu ();
            section3.append ("Download", "widget.download");
            section3.append ("Add to Playlist...", "widget.add_playlist");
            section3.append ("Copy Link", "widget.copy_link");
            menu.append_section (null, section3);

            this.context_menu.set_menu_model (menu);

            this.actions = new GLib.SimpleActionGroup ();

            var radio_action = new GLib.SimpleAction ("radio", null);
            radio_action.activate.connect (() => {
                var win = this.get_root () as Timbre.Window;
                if (win != null) win.play_radio (this.track_id, false);
            });
            this.actions.add_action (radio_action);

            var add_queue_action = new GLib.SimpleAction ("add_queue", null);
            add_queue_action.activate.connect (() => {
                var win = this.get_root () as Timbre.Window;
                if (win != null) win.add_to_queue (this);
            });
            this.actions.add_action (add_queue_action);

            var remove_action = new GLib.SimpleAction ("remove", null);
            remove_action.activate.connect (() => GLib.message ("remover"));
            this.actions.add_action (remove_action);

            this.insert_action_group ("widget", this.actions);
        }

        public TrackRow.empty () {
            Object ();
            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 48);
            this.cover_binding.load (null);
            this.explicit_badge.visible = false;
            this.live_badge.visible = false;
            this.setup_context_menu ();
        }

        public TrackRow (Timbre.Player player, MediaItem item) {
            Object ();
            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 48);
            this.like_btn = new Timbre.LikeButton (player);
            this.like_slot.append (this.like_btn);
            this.setup_context_menu ();
            this.set_content (item);
        }

        public TrackRow.simple (MediaItem item) {
            Object ();
            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 48);
            this.setup_context_menu ();
            this.set_content (item);
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

        [GtkCallback]
        private void onSecondaryClick (int n_press, double x, double y) {
            var rect = Gdk.Rectangle () {
                x = (int) x,
                y = (int) y,
                width = 1,
                height = 1
            };
            this.context_menu.pointing_to = rect;
            this.context_menu.popup ();
        }

        [GtkCallback]
        private void onLongPress (double x, double y) {
            var rect = Gdk.Rectangle () {
                x = (int) x,
                y = (int) y,
                width = 1,
                height = 1
            };

            this.context_menu.pointing_to = rect;
            this.context_menu.popup ();
        }

        public override void dispose () {
            this.actions = null;
            this.like_btn = null;
            base.dispose ();
        }
    }
}
