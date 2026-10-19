namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/widgets/home_speed_tile.ui")]
    public class HomeSpeedTile : Gtk.Button {
        public MediaItem media_item { get; private set; }

        private const int TILE_WIDTH = 230;

        [GtkChild] private unowned Gtk.Picture image_cover;
        [GtkChild] private unowned Gtk.Label label_title;
        [GtkChild] private unowned Gtk.Label label_sub;
        [GtkChild] private unowned Gtk.Label explicit_badge;
        [GtkChild] private unowned Adw.Bin live_badge;
        [GtkChild] private unowned Adw.Bin album_overlay;
        [GtkChild] private unowned Adw.Bin play_overlay;

        private Timbre.Utils.ImageBinding cover_binding;

        public HomeSpeedTile (MediaItem item) {
            Object ();
            this.media_item = item;
            this.width_request = TILE_WIDTH;

            this.label_title.label = item.title;

            string sub = item.subtitle_text ();
            if (item.duration_seconds != null && item.duration_seconds > 0) {
                int s = (int) item.duration_seconds;
                sub = "%s • %d:%02d".printf (sub, s / 60, s % 60);
            }
            this.label_sub.label = sub;

            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 48);
            this.cover_binding.load (item.thumb);

            if (item.kind == ItemKind.ARTIST) {
                this.add_css_class ("artist");
            }

            this.play_overlay.visible = item.kind.is_playable ();
            this.album_overlay.visible = (item.kind == ItemKind.ALBUM);
            this.explicit_badge.visible = item.explicit;
            this.live_badge.visible = item.is_live;
        }
    }
}
