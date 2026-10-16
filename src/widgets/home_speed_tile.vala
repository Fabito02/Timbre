namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/widgets/home_speed_tile.ui")]
    public class HomeSpeedTile : Gtk.Button {
        public string item_id { get; private set; }
        public string item_kind { get; private set; }
        public string item_title { get; private set; }
        public string item_artist { get; private set; }
        public uint64 item_duration { get; private set; }
        public string? item_cover { get; private set; }

        private const int TILE_WIDTH = 220;

        [GtkChild] private unowned Gtk.Picture image_cover;
        [GtkChild] private unowned Gtk.Label label_title;
        [GtkChild] private unowned Gtk.Label label_sub;
        [GtkChild] private unowned Gtk.Label explicit_badge;

        private Timbre.Utils.ImageBinding cover_binding;

        public HomeSpeedTile (string id, string kind, string title, string artist,
                              uint64 duration, string? cover_url, bool is_live = false, bool explicit = false) {
            Object ();

            this.item_id = id;
            this.item_kind = kind;
            this.item_title = title;
            this.item_artist = artist;
            this.item_duration = duration;
            this.item_cover = cover_url;

            this.width_request = TILE_WIDTH;

            this.label_title.label = title;

            string sub = artist;
            if (duration > 0) {
                int s = (int) duration;
                sub = "%s • %d:%02d".printf (artist, s / 60, s % 60);
            }
            this.label_sub.label = sub;

            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 48);
            this.cover_binding.load (cover_url);

            if (kind == "Artist") {
                this.add_css_class ("artist");
            }

            if (kind == "Song") {
                this.add_css_class ("song");
            }

            if (kind == "Album") {
                this.add_css_class ("album");
            }

            if (explicit) {
                this.add_css_class ("explicit");
            }

            this.explicit_badge.visible = explicit;
        }
    }
}
