namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/widgets/track_card.ui")]
    public class TrackCard : Gtk.Button {
        [GtkChild] private unowned Gtk.Picture image_cover;
        [GtkChild] private unowned Gtk.Label label_title;
        [GtkChild] private unowned Gtk.Label label_artist;

        public string track_id { get; private set; }
        public string item_type { get; private set; }
        public string track_title { get; private set; }
        public string track_artist { get; private set; }
        public string? track_cover { get; private set; }

        public TrackCard (string id, string type_name, string title, string artists, string? cover_url = null) {
            Object ();
            this.track_id = id;
            this.item_type = type_name;
            this.track_title = title;
            this.track_artist = artists;
            this.track_cover = cover_url;

            this.label_title.label = title;
            this.label_artist.label = artists;

            var display = Gdk.Display.get_default ();
            if (display != null) {
                Timbre.Utils.ImageLoader.get_default ().load_paintable_async.begin (
                    cover_url, display, 150, this.get_scale_factor (), "audio-x-generic-symbolic",
                    (obj, res) => {
                        this.image_cover.paintable = Timbre.Utils.ImageLoader.get_default ().load_paintable_async.end (res);
                    }
                );
            }
        }
    }
}
