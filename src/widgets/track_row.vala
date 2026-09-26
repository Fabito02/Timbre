namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/widgets/track_row.ui")]
    public class TrackRow : Gtk.ListBoxRow {
        [GtkChild] private unowned Gtk.Picture image_cover;
        [GtkChild] private unowned Gtk.Label label_title;
        [GtkChild] private unowned Gtk.Label label_artist;
        [GtkChild] private unowned Gtk.Label label_duration;

        public string track_id { get; private set; }
        public uint64 duration_secs { get; private set; }
        public string track_title { get; private set; }
        public string track_artist { get; private set; }
        public string? track_cover { get; private set; }

        private Timbre.Utils.ImageBinding cover_binding;

        public TrackRow (string id, string title, string artists,
                         uint64 duration_secs, string? cover_url = null) {
            Object ();
            this.track_id = id;
            this.duration_secs = duration_secs;
            this.track_title = title;
            this.track_artist = artists;
            this.track_cover = cover_url;

            this.label_title.label = title;
            this.label_artist.label = artists;

            int s = (int) duration_secs;
            this.label_duration.label = "%d:%02d".printf (s / 60, s % 60);

            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 48);
            this.cover_binding.load (cover_url);
        }
    }
}
