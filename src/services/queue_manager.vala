namespace Timbre {
    public class QueueManager : Object {
        public GLib.ListStore store { get; private set; }
        public int current_index { get; private set; default = -1; }

        public signal void track_changed (TrackItem track);
        public signal void queue_updated ();

        public QueueManager () {
            this.store = new GLib.ListStore (typeof (QueueItem));
        }

        public int length {
            get { return (int) this.store.get_n_items (); }
        }

        public TrackItem? get_track_at (int index) {
            if (index < 0 || index >= this.length) return null;
            return ((QueueItem) this.store.get_item (index)).track;
        }

        public void play_list (GenericArray<TrackItem> new_tracks, int start_index = 0) {
            this.store.remove_all ();

            for (int i = 0; i < new_tracks.length; i++) {
                this.store.append (new QueueItem (new_tracks.get (i), i, i == start_index));
            }

            this.current_index = int.max (0, int.min (start_index, this.length - 1));
            this.queue_updated ();

            if (this.length > 0) {
                this.track_changed (this.get_track_at (this.current_index));
            }
        }

        public void play_single (TrackItem track) {
            var single = new GenericArray<TrackItem> ();
            single.add (track);
            this.play_list (single, 0);
        }

        public void play_index (int index) {
            if (index < 0 || index >= this.length) return;
            this.current_index = index;
            this.emit_current ();
        }

        public void clear () {
            this.store.remove_all ();
            this.current_index = -1;
            this.queue_updated ();
        }

        public bool move_item (int from_index, int to_index) {
            if (from_index == to_index
                || from_index < 0 || from_index >= this.length
                || to_index < 0 || to_index >= this.length) {
                return false;
            }

            var item = (QueueItem) this.store.get_item (from_index);
            this.store.remove (from_index);
            this.store.insert (to_index, item);

            if (this.current_index == from_index) {
                this.current_index = to_index;
            } else if (from_index < this.current_index && to_index >= this.current_index) {
                this.current_index--;
            } else if (from_index > this.current_index && to_index <= this.current_index) {
                this.current_index++;
            }

            for (uint i = 0; i < this.store.get_n_items (); i++) {
                var cur = (QueueItem) this.store.get_item (i);
                cur.index = (int) i;
                cur.is_playing = (int) i == this.current_index;
            }

            this.queue_updated ();
            return true;
        }

        public bool has_next () {
            return (this.current_index + 1) < this.length;
        }

        public bool has_prev () {
            return this.current_index > 0;
        }

        public void next () {
            if (!this.has_next ()) return;
            this.current_index++;
            this.emit_current ();
        }

        public void prev () {
            if (!this.has_prev ()) return;
            this.current_index--;
            this.emit_current ();
        }

        private void emit_current () {
            this.update_playing_state ();
            this.track_changed (this.get_track_at (this.current_index));
        }

        private void update_playing_state () {
            for (uint i = 0; i < this.store.get_n_items (); i++) {
                ((QueueItem) this.store.get_item (i)).is_playing = (int) i == this.current_index;
            }
        }
    }
}
