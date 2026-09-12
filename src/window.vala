namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/window.ui")]
    public class Window : Adw.ApplicationWindow {
        private Timbre.Player player;
        private bool is_playing = false;
        private bool is_seeking = false;
        private uint tick_id = 0;
        private uint seek_debounce_id = 0;

        [GtkChild]
        private unowned Gtk.Scale scale_progress;
        [GtkChild]
        private unowned Gtk.Adjustment adjustment_progress;
        [GtkChild]
        private unowned Gtk.Label label_time_current;
        [GtkChild]
        private unowned Gtk.Label label_time_total;
        [GtkChild]
        private unowned Gtk.Button button_play_pause;

        public Window (Gtk.Application app) {
            Object (application: app);

            this.player = new Timbre.Player ();

            var results = this.player.search_tracks ("Ditto");
            if (results != null && results.len > 0) {
                for (int i = 0; i < results.len; i++) {
                    var track = results.items[i];
                    print ("[%d] %s - %s (ID: %s, Duração: %llu s)\n", 
                           i + 1, track.title, track.artists, track.id, track.duration_secs);
                }

                var first = results.items[0];
                this.play_track (first.id, first.duration_secs);
            }
        }

        private string format_time (double total_seconds) {
            int s = (int) total_seconds;
            int minutes = s / 60;
            int seconds = s % 60;
            return "%d:%02d".printf (minutes, seconds);
        }

        public void play_track (string track_id, uint64 duration_secs) {
            message ("Carregando faixa: %s (%llu s)", track_id, duration_secs);

            if (this.player.play_track_id (track_id, duration_secs)) {
                this.adjustment_progress.upper = (double) duration_secs;
                this.label_time_total.label = this.format_time ((double) duration_secs);

                this.adjustment_progress.value = 0.0;
                this.label_time_current.label = "0:00";

                this.is_playing = true;
                this.button_play_pause.icon_name = "media-playback-pause-symbolic";

                if (this.tick_id == 0) {
                    this.tick_id = GLib.Timeout.add (250, this.update_ui_tick);
                }
            }
        }

        private bool update_ui_tick () {
            if (!this.is_playing) {
                return true;
            }

            if (this.is_seeking || this.seek_debounce_id != 0) {
                return true;
            }

            double pos = this.player.get_position ();
            int total_secs = (int) pos;
            int mins = total_secs / 60;
            int secs = total_secs % 60;

            this.label_time_current.label = "%d:%02d".printf (mins, secs);

            this.is_seeking = true;
            this.scale_progress.set_value (pos);
            this.is_seeking = false;

            return true;
        }

        [GtkCallback]
        private void on_seek_changed () {
            if (this.is_seeking) {
                return;
            }

            double target_pos = this.scale_progress.get_value ();
            int total_secs = (int) target_pos;
            this.label_time_current.label = "%d:%02d".printf (total_secs / 60, total_secs % 60);

            if (this.seek_debounce_id != 0) {
                GLib.Source.remove (this.seek_debounce_id);
            }

            this.seek_debounce_id = GLib.Timeout.add (250, () => {
                message ("Disparando seek para: %.1f s", target_pos);
                this.player.seek (target_pos);
                this.seek_debounce_id = 0;
                return false;
            });
        }

        [GtkCallback]
        private void on_play_pause_clicked () {
            if (this.is_playing) {
                this.player.pause ();
                this.button_play_pause.icon_name = "media-playback-start-symbolic";
                this.is_playing = false;
            } else {
                this.player.resume ();
                this.button_play_pause.icon_name = "media-playback-pause-symbolic";
                this.is_playing = true;
            }
        }
    }
}
