namespace Timbre.Services {

    [DBus (name = "org.mpris.MediaPlayer2")]
    public interface MprisRoot : Object {
        public abstract void raise () throws GLib.DBusError, GLib.IOError;
        public abstract void quit () throws GLib.DBusError, GLib.IOError;

        public abstract bool can_quit { get; }
        public abstract bool fullscreen { get; set; }
        public abstract bool can_set_fullscreen { get; }
        public abstract bool can_raise { get; }
        public abstract bool has_track_list { get; }
        public abstract string identity { owned get; }
        public abstract string desktop_entry { owned get; }
        public abstract string[] supported_uri_schemes { owned get; }
        public abstract string[] supported_mime_types { owned get; }
    }

    [DBus (name = "org.mpris.MediaPlayer2.Player")]
    public interface MprisPlayer : Object {
        public abstract void next () throws GLib.DBusError, GLib.IOError;
        public abstract void previous () throws GLib.DBusError, GLib.IOError;
        public abstract void pause () throws GLib.DBusError, GLib.IOError;
        public abstract void play_pause () throws GLib.DBusError, GLib.IOError;
        public abstract void stop () throws GLib.DBusError, GLib.IOError;
        public abstract void play () throws GLib.DBusError, GLib.IOError;
        public abstract void seek (int64 offset) throws GLib.DBusError, GLib.IOError;
        public abstract void set_position (GLib.ObjectPath track_id, int64 position)
            throws GLib.DBusError, GLib.IOError;
        public abstract void open_uri (string uri) throws GLib.DBusError, GLib.IOError;

        public abstract string playback_status { owned get; }
        public abstract string loop_status { owned get; set; }
        public abstract double rate { get; set; }
        public abstract bool shuffle { get; set; }
        public abstract HashTable<string, Variant> metadata { owned get; }
        public abstract double volume { get; set; }
        public abstract int64 position { get; }
        public abstract double minimum_rate { get; }
        public abstract double maximum_rate { get; }
        public abstract bool can_go_next { get; }
        public abstract bool can_go_previous { get; }
        public abstract bool can_play { get; }
        public abstract bool can_pause { get; }
        public abstract bool can_seek { get; }
        public abstract bool can_control { get; }

        public signal void seeked (int64 position);
    }

    public class Mpris : Object, MprisRoot, MprisPlayer {
        public const string BUS_NAME = "org.mpris.MediaPlayer2.io.github.fabito02.Timbre";
        public const string OBJECT_PATH = "/org/mpris/MediaPlayer2";
        private const string IFACE_PLAYER = "org.mpris.MediaPlayer2.Player";
        private const string IFACE_PROPS  = "org.freedesktop.DBus.Properties";
        private const string IDENTITY_STR = "Timbre";
        private const string DESKTOP_ENTRY_STR = "io.github.fabito02.Timbre";
        private const string TRACK_ID_PREFIX = "/io/github/fabito02/Timbre/track/v";
        private const string TRACK_ID_NONE   = "/io/github/fabito02/Timbre/track/vnone";

        private GLib.DBusConnection? connection = null;
        private uint root_reg_id = 0;
        private uint player_reg_id = 0;
        private uint owner_id = 0;
        private uint poll_id = 0;

        private ulong sig_track_changed = 0;
        private ulong sig_queue_updated = 0;
        private ulong sig_repeat_changed = 0;
        private ulong sig_shuffle_changed = 0;

        private unowned Timbre.Player player;
        private unowned Timbre.QueueManager queue;

        private string last_status = "";
        private bool last_idle = true;

        public delegate double PositionProvider ();
        public delegate double DurationProvider ();

        private PositionProvider? position_provider = null;
        private DurationProvider? duration_provider = null;

        public signal void raise_requested ();
        public signal void quit_requested ();

        public Mpris (Timbre.Player player, Timbre.QueueManager queue) {
            this.player = player;
            this.queue = queue;
        }

        public override void dispose () {
            this.shutdown ();
            base.dispose ();
        }

        public void set_position_provider (PositionProvider provider) {
            this.position_provider = provider;
        }

        public void set_duration_provider (DurationProvider provider) {
            this.duration_provider = provider;
        }

        private double reported_position () {
            return (this.position_provider != null)
                ? this.position_provider ()
                : this.player.get_position ();
        }

        private double reported_duration () {
            if (this.duration_provider != null) return this.duration_provider ();
            return 0.0;
        }

        private bool is_idle () {
            return this.current_track () == null
                || this.player.get_state () == 0;
        }

        public void start () {
            try {
                this.connection = GLib.Bus.get_sync (GLib.BusType.SESSION, null);
            } catch (Error e) {
                warning ("mpris: session bus unavailable: %s", e.message);
                return;
            }

            try {
                this.root_reg_id = this.connection.register_object<MprisRoot> (
                    OBJECT_PATH, this);
                this.player_reg_id = this.connection.register_object<MprisPlayer> (
                    OBJECT_PATH, this);
            } catch (Error e) {
                warning ("mpris: register_object failed: %s", e.message);
                if (this.root_reg_id != 0) {
                    this.connection.unregister_object (this.root_reg_id);
                    this.root_reg_id = 0;
                }
                if (this.player_reg_id != 0) {
                    this.connection.unregister_object (this.player_reg_id);
                    this.player_reg_id = 0;
                }
                this.connection = null;
                return;
            }

            this.owner_id = GLib.Bus.own_name_on_connection (
                this.connection, BUS_NAME,
                GLib.BusNameOwnerFlags.NONE, null, null);

            this.last_status = this.playback_status;
            this.last_idle = this.is_idle ();

            this.poll_id = GLib.Timeout.add (100, () => {
                string s = this.playback_status;
                if (s != this.last_status) {
                    this.last_status = s;
                    this.emit_status_changed ();
                }

                bool idle = this.is_idle ();
                if (idle != this.last_idle) {
                    this.last_idle = idle;
                    this.emit_metadata_changed ();
                    this.emit_can_go_changed (
                        idle ? false : this.queue.has_next (),
                        this.queue.has_prev ());
                }

                return GLib.Source.CONTINUE;
            });

            this.sig_track_changed = this.queue.track_changed.connect (() => {
                this.last_idle = this.is_idle ();
                this.emit_metadata_changed ();
                this.emit_can_go_changed (this.queue.has_next (), this.queue.has_prev ());
            });
            this.sig_queue_updated = this.queue.queue_updated.connect (() => {
                this.emit_can_go_changed (this.queue.has_next (), this.queue.has_prev ());
            });
            this.sig_repeat_changed = this.queue.repeat_changed.connect ((mode) => {
                this.emit_loop_status_changed ();
            });
            this.sig_shuffle_changed = this.queue.shuffle_changed.connect ((mode) => {
                this.emit_shuffle_changed ();
            });

            message ("mpris: registered at %s (%s)", BUS_NAME, OBJECT_PATH);
        }

        public void shutdown () {
            if (this.poll_id != 0) {
                GLib.Source.remove (this.poll_id);
                this.poll_id = 0;
            }

            if (this.sig_track_changed != 0) {
                this.queue.disconnect (this.sig_track_changed);
                this.sig_track_changed = 0;
            }
            if (this.sig_queue_updated != 0) {
                this.queue.disconnect (this.sig_queue_updated);
                this.sig_queue_updated = 0;
            }
            if (this.sig_repeat_changed != 0) {
                this.queue.disconnect (this.sig_repeat_changed);
                this.sig_repeat_changed = 0;
            }
            if (this.sig_shuffle_changed != 0) {
                this.queue.disconnect (this.sig_shuffle_changed);
                this.sig_shuffle_changed = 0;
            }

            if (this.owner_id != 0) {
                GLib.Bus.unown_name (this.owner_id);
                this.owner_id = 0;
            }
            if (this.connection != null) {
                if (this.root_reg_id != 0) {
                    this.connection.unregister_object (this.root_reg_id);
                    this.root_reg_id = 0;
                }
                if (this.player_reg_id != 0) {
                    this.connection.unregister_object (this.player_reg_id);
                    this.player_reg_id = 0;
                }
            }
            this.connection = null;
        }

        public void raise () throws GLib.DBusError, GLib.IOError {
            this.raise_requested ();
        }

        public void quit () throws GLib.DBusError, GLib.IOError {
            this.quit_requested ();
        }

        public bool can_quit { get { return true; } }
        public bool fullscreen { get { return false; } set { } }
        public bool can_set_fullscreen { get { return false; } }
        public bool can_raise { get { return true; } }
        public bool has_track_list { get { return false; } }
        public string identity { owned get { return IDENTITY_STR; } }
        public string desktop_entry { owned get { return DESKTOP_ENTRY_STR; } }
        public string[] supported_uri_schemes { owned get { return {}; } }
        public string[] supported_mime_types { owned get { return {}; } }

        public void next () throws GLib.DBusError, GLib.IOError {
            if (this.queue.has_next ()) this.queue.next ();
        }

        public void previous () throws GLib.DBusError, GLib.IOError {
            if (this.player.get_position () > 3.0 || !this.queue.has_prev ()) {
                this.player.seek (0.0);
                return;
            }

            this.queue.prev ();
        }

        public void pause () throws GLib.DBusError, GLib.IOError {
            this.player.pause ();
        }

        public void play_pause () throws GLib.DBusError, GLib.IOError {
            if (this.player.get_state () == 1) this.player.pause ();
            else this.player.resume ();
        }

        public void stop () throws GLib.DBusError, GLib.IOError {
            this.player.stop ();
        }

        public void play () throws GLib.DBusError, GLib.IOError {
            this.player.resume ();
        }

        public void seek (int64 offset) throws GLib.DBusError, GLib.IOError {
            if (this.is_idle ()) return;
            double target = this.reported_position () + (double) offset / 1e6;
            this.apply_seek (target);
        }

        public void set_position (GLib.ObjectPath track_id, int64 position)
                throws GLib.DBusError, GLib.IOError {
            if (this.is_idle ()) return;
            if (track_id != this.current_track_path ()) return;
            this.apply_seek ((double) position / 1e6);
        }

        public void open_uri (string uri) throws GLib.DBusError, GLib.IOError {
            throw new GLib.DBusError.NOT_SUPPORTED ("opening URIs is not supported");
        }

        public string playback_status {
            owned get {
                switch (this.player.get_state ()) {
                    case 1:  return "Playing";
                    case 2:  return "Paused";
                    case 3:  return "Playing";   // Buffering -> Playing
                    case 4:  return "Playing";   // Loading -> Playing
                    default: return "Stopped";
                }
            }
        }

        private void emit_loop_status_changed () {
            var b = new VariantBuilder (new VariantType ("a{sv}"));
            b.add ("{sv}", "LoopStatus", new Variant.string (this.loop_status));
            this.emit_player_changed (b);
        }

        private void emit_shuffle_changed () {
            var b = new VariantBuilder (new VariantType ("a{sv}"));
            b.add ("{sv}", "Shuffle", new Variant.boolean (this.shuffle));
            this.emit_player_changed (b);
        }

        public string loop_status {
            owned get {
                switch (this.queue.repeat_mode) {
                    case Timbre.QueueManager.RepeatMode.ONE:  return "Track";
                    case Timbre.QueueManager.RepeatMode.ALL:  return "Playlist";
                    default:                                   return "None";
                }
            }
            set {
                Timbre.QueueManager.RepeatMode new_mode;
                switch (value) {
                    case "Track":
                        new_mode = Timbre.QueueManager.RepeatMode.ONE;
                        break;
                    case "Playlist":
                        new_mode = Timbre.QueueManager.RepeatMode.ALL;
                        break;
                    default:
                        new_mode = Timbre.QueueManager.RepeatMode.OFF;
                        break;
                }

                if (this.queue.repeat_mode != new_mode) {
                    this.queue.repeat_mode = new_mode;
                    this.queue.repeat_changed (new_mode);
                }
                this.emit_loop_status_changed ();
            }
        }

        public double rate { get { return 1.0; } set { } }
        public bool shuffle {
            get { return this.queue._shuffle; }
            set {
                if (this.queue._shuffle != value) {
                    this.queue.set_shuffle (value);
                    this.emit_shuffle_changed ();
                }
            }
        }

        public HashTable<string, Variant> metadata {
            owned get {
                var table = new HashTable<string, Variant> (str_hash, str_equal);

                if (this.is_idle ()) {
                    table.insert ("mpris:trackid",
                        new Variant.object_path (TRACK_ID_NONE));
                    return table;
                }

                var track = this.current_track ();
                string video_id = (track != null) ? track.id : "";

                table.insert ("mpris:trackid",
                    new Variant.object_path (this.track_path (video_id)));

                if (track != null) {
                    if (track.title.length > 0) {
                        table.insert ("xesam:title",
                            new Variant.string (track.title));
                    }

                    string artists_str = track.artists_text ();
                    if (artists_str.length > 0) {
                        string[] names = { artists_str };
                        table.insert ("xesam:artist", new Variant.strv (names));
                    }

                    if (track.thumb != null && track.thumb.length > 0) {
                        table.insert ("mpris:artUrl",
                            new Variant.string (track.thumb));
                    }
                }

                double dur = this.reported_duration ();
                if (dur > 0.0) {
                    table.insert ("mpris:length",
                        new Variant.int64 ((int64) (dur * 1e6)));
                }

                return table;
            }
        }

        public double volume {
            get { return (double) this.player.get_volume (); }
            set { this.player.set_volume ((float) value.clamp (0.0, 1.0)); }
        }

        public int64 position {
            get {
                double secs = this.reported_position ();
                if (secs < 0.0) secs = 0.0;
                return (int64) (secs * 1e6);
            }
        }

        public double minimum_rate { get { return 1.0; } }
        public double maximum_rate { get { return 1.0; } }
        public bool can_go_next { get { return !this.is_idle () && this.queue.has_next (); } }
        public bool can_go_previous { get { return this.queue.has_prev (); } }
        public bool can_play { get { return true; } }
        public bool can_pause { get { return true; } }
        public bool can_seek { get { return !this.is_idle () && this.reported_duration () > 0.0; } }
        public bool can_control { get { return true; } }

        public void notify_seeked (double position) {
            if (this.is_idle ()) return;
            this.seeked ((int64) (position * 1e6));
        }

        private void apply_seek (double target) {
            double dur = this.reported_duration ();
            if (dur > 0.0) target = target.clamp (0.0, dur);
            if (target < 0.0) target = 0.0;
            this.player.seek (target);
            this.notify_seeked (target);
        }

        private Timbre.Track? current_track () {
            if (this.queue.current_index < 0) return null;
            return this.queue.get_track_at (this.queue.current_index);
        }

        private string track_path (string video_id) {
            if (video_id.length == 0) {
                return TRACK_ID_NONE;
            }
            var sb = new StringBuilder (TRACK_ID_PREFIX);
            for (int i = 0; i < video_id.length; i++) {
                unowned char c = video_id[i];
                if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                    || (c >= '0' && c <= '9') || c == '_') {
                    sb.append_c (c);
                } else {
                    sb.append_c ('_');
                }
            }
            return sb.str;
        }

        private string current_track_id () {
            var track = this.current_track ();
            return (track != null) ? track.id : "";
        }

        private GLib.ObjectPath current_track_path () {
            return new GLib.ObjectPath (this.track_path (this.current_track_id ()));
        }

        private void emit_player_changed (VariantBuilder b) {
            if (this.connection == null) return;
            try {
                this.connection.emit_signal (
                    null, OBJECT_PATH, IFACE_PROPS, "PropertiesChanged",
                    new Variant ("(s@a{sv}@as)",
                                 IFACE_PLAYER,
                                 b.end (),
                                 new Variant.strv (new string[] {})));
            } catch (Error e) {
                warning ("mpris: emit PropertiesChanged: %s", e.message);
            }
        }

        private void emit_status_changed () {
            var b = new VariantBuilder (new VariantType ("a{sv}"));
            b.add ("{sv}", "PlaybackStatus",
                   new Variant.string (this.playback_status));
            this.emit_player_changed (b);
        }

        private void emit_metadata_changed () {
            var b = new VariantBuilder (new VariantType ("a{sv}"));
            b.add ("{sv}", "Metadata", this.metadata_to_variant ());
            b.add ("{sv}", "CanSeek",
                   new Variant.boolean (this.can_seek));
            this.emit_player_changed (b);
        }

        private void emit_can_go_changed (bool next, bool prev) {
            var b = new VariantBuilder (new VariantType ("a{sv}"));
            b.add ("{sv}", "CanGoNext",     new Variant.boolean (next));
            b.add ("{sv}", "CanGoPrevious", new Variant.boolean (prev));
            this.emit_player_changed (b);
        }

        private Variant metadata_to_variant () {
            var b = new VariantBuilder (new VariantType ("a{sv}"));
            this.metadata.foreach ((key, value) => {
                b.add ("{sv}", key, value);
            });
            return b.end ();
        }
    }
}
