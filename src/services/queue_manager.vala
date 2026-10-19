namespace Timbre {
    public class QueueManager : Object {
        public GLib.ListStore store { get; private set; }
        public int current_index { get; private set; default = -1; }

        public enum RepeatMode { OFF, ALL, ONE }
        public RepeatMode repeat_mode = RepeatMode.OFF;

        public signal void track_changed (TrackItem track);
        public signal void queue_updated ();
        public signal void repeat_changed (RepeatMode mode);
        public signal void shuffle_changed (bool enabled);
        public signal void queue_ended ();

        public bool _shuffle = false;
        private GenericArray<TrackItem>? _saved_order = null;

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
            this._shuffle = false;
            this._saved_order = null;
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

        public void add_to_queue (GenericArray<TrackItem> new_tracks) {
            int start = this.length;
            for (int i = 0; i < new_tracks.length; i++) {
                this.store.append (new QueueItem (
                    new_tracks.get (i),
                    start + i,
                    false
                ));
            }
            this.queue_updated ();
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
            if (this.repeat_mode == RepeatMode.ONE) {
                this.track_changed (this.get_track_at (this.current_index));
                return;
            }

            if (this.has_next ()) {
                this.current_index++;
                this.emit_current ();
                return;
            }

            if (this.repeat_mode == RepeatMode.ALL) {
                this.current_index = 0;
                this.emit_current ();
            } else {
                this.queue_ended ();
            }
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

        private GenericArray<TrackItem> snapshot_tracks () {
            var out = new GenericArray<TrackItem> ();
            for (uint i = 0; i < this.store.get_n_items (); i++) {
                out.add (((QueueItem) this.store.get_item (i)).track);
            }
            return out;
        }

        private void shuffle_store () {
            int n = this.length;
            if (n < 2) return;

            var items = new GenericArray<QueueItem> ();
            for (uint i = 0; i < this.store.get_n_items (); i++) {
                items.add ((QueueItem) this.store.get_item (i));
            }

            for (int i = n - 1; i > 0; i--) {
                int j = Random.int_range (0, i + 1);
                var tmp = items.get (i);
                items.set (i, items.get (j));
                items.set (j, tmp);
            }

            this.store.remove_all ();
            for (int i = 0; i < items.length; i++) {
                this.store.append (items.get (i));
            }
        }

        private void move_track_to_front (TrackItem? track) {
            if (track == null) return;
            int pos = -1;
            for (int i = 0; i < this.length; i++) {
                if (this.get_track_at (i) == track) { pos = i; break; }
            }
            if (pos <= 0) return;

            this.move_item (pos, 0);
            this.current_index = 0;
        }

        private void reindex () {
            for (uint i = 0; i < this.store.get_n_items (); i++) {
                var item = (QueueItem) this.store.get_item (i);
                item.index = (int) i;
                item.is_playing = (int) i == this.current_index;
            }
        }

        public void set_shuffle (bool enabled) {
            if (this._shuffle == enabled) return;

            TrackItem? current = this.get_track_at (this.current_index);

            if (enabled) {
                this._saved_order = this.snapshot_tracks ();
                this.shuffle_store ();
                this.move_track_to_front (current);
                this.reindex ();
                this._shuffle = true;
            } else {
                this.restore_order ();
                this._shuffle = false;
            }

            this.shuffle_changed (this._shuffle);
            this.queue_updated ();
        }

        private void restore_order () {
            if (this._saved_order == null) return;

            TrackItem? current = this.get_track_at (this.current_index);

            var in_saved = new HashTable<TrackItem, bool> (null, null);
            for (int i = 0; i < this._saved_order.length; i++) {
                in_saved.add (this._saved_order.get (i));
            }

            var extras = new GenericArray<TrackItem> ();
            for (int i = 0; i < this.length; i++) {
                var t = this.get_track_at (i);
                if (t != null && !in_saved.contains (t)) extras.add (t);
            }

            this.store.remove_all ();
            int pos = 0;
            for (int i = 0; i < this._saved_order.length; i++) {
                this.store.append (new QueueItem (this._saved_order.get (i), pos++, false));
            }
            for (int i = 0; i < extras.length; i++) {
                this.store.append (new QueueItem (extras.get (i), pos++, false));
            }

            if (current != null) {
                for (int i = 0; i < this.length; i++) {
                    if (this.get_track_at (i) == current) {
                        this.current_index = i;
                        break;
                    }
                }
            }

            this._saved_order = null;
            this.reindex ();
        }

        public void cycle_repeat () {
            switch (this.repeat_mode) {
                case RepeatMode.OFF:  this.repeat_mode = RepeatMode.ALL; break;
                case RepeatMode.ALL:  this.repeat_mode = RepeatMode.ONE; break;
                case RepeatMode.ONE:  this.repeat_mode = RepeatMode.OFF; break;
            }

            this.repeat_changed (this.repeat_mode);
        }
    }
}
