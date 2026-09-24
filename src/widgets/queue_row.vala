namespace Timbre {
    public class QueueRow : Gtk.Box {
        private Gtk.Image grip;
        private Gtk.Stack stack;
        private Gtk.Label label_idx;
        private Gtk.Label label_title;
        private Gtk.Label label_artist;

        private weak Timbre.QueueItem? current_item = null;
        private ulong notify_playing_id = 0;
        private ulong notify_index_id = 0;

        public signal void item_moved (int from_index, int to_index);

        public QueueRow () {
            Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 8);

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
        }

        private void setup_dnd () {
            var drag_source = new Gtk.DragSource ();
            drag_source.actions = Gdk.DragAction.MOVE;

            drag_source.prepare.connect ((x, y) => {
                if (this.current_item == null) return null;
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
                if (str_val == null || this.current_item == null) return false;

                int from_index = int.parse (str_val);
                int to_index = this.current_item.index;
                if (from_index == to_index) return false;

                this.item_moved (from_index, to_index);
                return true;
            });

            this.add_controller (drop_target);
        }

        public void unbind () {
            if (this.current_item == null) return;

            if (this.notify_playing_id != 0) {
                this.current_item.disconnect (this.notify_playing_id);
                this.notify_playing_id = 0;
            }
            if (this.notify_index_id != 0) {
                this.current_item.disconnect (this.notify_index_id);
                this.notify_index_id = 0;
            }
            this.current_item = null;
        }

        public void bind (Timbre.QueueItem queue_item) {
            this.unbind ();

            this.current_item = queue_item;
            this.label_title.label = queue_item.track.title;
            this.label_artist.label = queue_item.track.artist;

            this.update_state ();

            this.notify_playing_id = queue_item.notify["is-playing"].connect (() => {
                this.update_state ();
            });
            this.notify_index_id = queue_item.notify["index"].connect (() => {
                this.update_state ();
            });
        }

        private void update_state () {
            if (this.current_item == null) return;

            if (this.current_item.is_playing) {
                this.stack.visible_child_name = "playing";
                this.label_title.add_css_class ("heading");
            } else {
                this.stack.visible_child_name = "index";
                this.label_idx.label = "%d".printf (this.current_item.index + 1);
                this.label_title.remove_css_class ("heading");
            }
        }
    }
}
