namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/window.ui")]
    public class Window : Adw.ApplicationWindow {
        private Timbre.Player player;

        public Window (Gtk.Application app) {
            Object (application: app);

            this.player = new Timbre.Player ();

            string track_id = "D-tI6qEBRMg";

            if (this.player.play_track_id (track_id)) {
                message ("Música do YouTube tocando");
            }
        }
    }
}
