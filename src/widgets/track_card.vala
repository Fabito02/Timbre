namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/widgets/track_card.ui")]
    public class TrackCard : Gtk.Button {
        [GtkChild] private unowned Gtk.Picture image_cover;
        [GtkChild] private unowned Gtk.Label label_title;
        [GtkChild] private unowned Gtk.Label label_artist;
        [GtkChild] private unowned Gtk.Label explicit_badge;

        public string track_id { get; private set; }
        public string item_type { get; private set; }
        public string track_title { get; private set; }
        public string track_artist { get; private set; }
        public string? track_cover { get; private set; }

        private Timbre.Utils.ImageBinding cover_binding;

        public TrackCard (string id, string type_name, string title,
                          string artists, string? cover_url = null,
                          bool is_live = false, bool explicit = false) {
            Object ();
            this.track_id = id;
            this.item_type = type_name;
            this.track_title = title;
            this.track_artist = artists;
            this.track_cover = cover_url;

            this.label_title.label = title;
            this.label_artist.label = artists;

            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 144);
            this.cover_binding.load (cover_url);

            if (type_name == "Artist") {
                this.add_css_class ("artist");
            }

            if (type_name == "Song" || type_name == "Video") {
                this.add_css_class ("song");
            }

            if (type_name == "Album") {
                this.add_css_class ("album");
            }

            if (is_live) {
                this.add_css_class ("live");
            }

            if (explicit) {
                this.add_css_class ("explicit");
            }

            this.explicit_badge.visible = explicit;

            if (type_name == "Video") {
                this.image_cover.width_request = 256;
                this.image_cover.height_request = 144;
            } else {
                this.image_cover.width_request = 144;
                this.image_cover.height_request = 144;
            }

            this.label_title.max_width_chars = (type_name == "Video") ? 32 : 20;
            this.label_artist.max_width_chars = (type_name == "Video") ? 32 : 20;
        }
    }
}
