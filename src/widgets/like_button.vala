namespace Timbre {

    public class LikeButton : Gtk.Button {
        private Gtk.Popover popover;
        private Gtk.Label dislike_label;
        private unowned Timbre.Player player;

        private string? video_id = null;
        private LikeStatus status = LikeStatus.INDIFFERENT;
        private bool suppress_next_click = false;

        public LikeButton (Timbre.Player player) {
            this.player = player;

            this.add_css_class ("flat");
            this.add_css_class ("circular");
            this.valign = Gtk.Align.CENTER;
            this.visible = false;

            this.popover = new Gtk.Popover ();
            this.popover.has_arrow = true;
            this.popover.set_parent (this);

            var menu_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            menu_box.margin_top = 4;
            menu_box.margin_bottom = 4;
            menu_box.margin_start = 4;
            menu_box.margin_end = 4;

            var dislike_content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            dislike_content.append (
                new Gtk.Image.from_icon_name ("heart-broken-symbolic"));
            this.dislike_label = new Gtk.Label ("Dislike");
            dislike_content.append (this.dislike_label);

            var dislike_btn = new Gtk.Button ();
            dislike_btn.add_css_class ("flat");
            dislike_btn.child = dislike_content;
            dislike_btn.clicked.connect (this.on_dislike_clicked);
            menu_box.append (dislike_btn);

            this.popover.child = menu_box;

            this.clicked.connect (this.on_clicked);

            this.popover.closed.connect (() => {
                GLib.Idle.add (() => {
                    this.suppress_next_click = false;
                    return GLib.Source.REMOVE;
                });
            });

            var right_click = new Gtk.GestureClick () {
                button = Gdk.BUTTON_SECONDARY
            };
            right_click.pressed.connect (() => this.show_menu ());
            this.add_controller (right_click);

            var long_press = new Gtk.GestureLongPress () {
                touch_only = false
            };
            long_press.pressed.connect (() => {
                this.suppress_next_click = true;
                this.show_menu ();
            });
            this.add_controller (long_press);

            this.update_icon ();
        }

        public void set_target (string? video_id, LikeStatus? status = null) {
            if (video_id == null || video_id.length == 0) {
                this.video_id = null;
                this.status = LikeStatus.INDIFFERENT;
                this.update_icon ();
                this.visible = false;
                return;
            }

            this.video_id = video_id;
            this.status = status ?? LikeStatus.INDIFFERENT;
            this.update_icon ();
            this.visible = true;
        }

        private void on_clicked () {
            if (this.video_id == null) return;

            if (this.suppress_next_click || this.popover.visible) {
                this.suppress_next_click = false;
                return;
            }

            var target = (this.status == LikeStatus.LIKE)
                ? LikeStatus.INDIFFERENT
                : LikeStatus.LIKE;
            this.apply_rating (target);
        }

        private void on_dislike_clicked () {
            this.popover.popdown ();
            this.suppress_next_click = false;

            var target = (this.status == LikeStatus.DISLIKE)
                ? LikeStatus.INDIFFERENT
                : LikeStatus.DISLIKE;
            this.apply_rating (target);
        }

        private void show_menu () {
            if (this.video_id == null) return;

            this.dislike_label.label = (this.status == LikeStatus.DISLIKE)
                ? "Remove Dislike"
                : "Dislike";

            this.popover.pointing_to = Gdk.Rectangle () {
                x = 0, y = 0,
                width = this.get_width (),
                height = this.get_height ()
            };
            this.popover.popup ();
        }

        private void apply_rating (LikeStatus target) {
            if (this.video_id == null) return;

            this.status = target;
            this.update_icon ();

            int rating = 0;
            switch (target) {
                case LikeStatus.LIKE:    rating = 1;  break;
                case LikeStatus.DISLIKE: rating = -1; break;
                default:                 rating = 0;  break;
            }

            string vid = this.video_id;
            this.player.rate_track (vid, rating, (success, error) => {
                if (!success) {
                    string msg = error != null ? (string) error : "unknown error";
                    warning ("rate_track(%s): %s", vid, msg);
                }
                if (error != null) {
                    Timbre.string_free (error);
                }
            });
        }

        private void update_icon () {
            string icon;
            string? add_class = null;
            string tip;

            switch (this.status) {
                case LikeStatus.LIKE:
                    icon = "heart-filled-symbolic";
                    add_class = "liked-button";
                    tip = "Unlike (Hold or right-click for Dislike)";
                    break;
                case LikeStatus.DISLIKE:
                    icon = "heart-broken-symbolic";
                    add_class = "disliked-button";
                    tip = "Disliked (Hold or right-click to remove)";
                    break;
                default:
                    icon = "heart-outline-thick-symbolic";
                    tip = "Like (Hold or right-click for Dislike)";
                    break;
            }

            this.icon_name = icon;
            this.remove_css_class ("liked-button");
            this.remove_css_class ("disliked-button");
            if (add_class != null) {
                this.add_css_class (add_class);
            }
            this.tooltip_text = tip;
        }

        public override void dispose () {
            this.popover.unparent ();
            base.dispose ();
        }
    }
}
