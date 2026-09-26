namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/pages/collection.ui")]
    public class CollectionPage : Adw.NavigationPage {
        [GtkChild] private unowned Gtk.Picture image_cover;
        [GtkChild] private unowned Gtk.Label label_title;
        [GtkChild] private unowned Gtk.Label label_subtitle;
        [GtkChild] private unowned Gtk.Button button_play_all;
        [GtkChild] private unowned Gtk.Spinner spinner_loading;
        [GtkChild] private unowned Gtk.ListBox tracks_list;

        private unowned Timbre.Player player;
        private string collection_id;
        private string collection_type;
        private GenericArray<Timbre.TrackItem> tracks;

        private Timbre.Utils.ImageBinding header_binding;
        private ulong row_activated_id = 0;
        private ulong play_all_id = 0;

        private bool released = false;

        public signal void track_selected (string id, uint64 duration, string title, string artist, string? cover);
        public signal void play_collection (GenericArray<Timbre.TrackItem> tracks, int start_index);

        public CollectionPage (
            Timbre.Player player,
            string id,
            string type_name,
            string title,
            string subtitle,
            string? cover_url
        ) {
            Object (title: title);

            this.player = player;
            this.collection_id = id;
            this.collection_type = type_name.down ();
            this.tracks = new GenericArray<Timbre.TrackItem> ();

            this.label_title.label = title;
            this.label_subtitle.label = subtitle;

            this.header_binding = new Timbre.Utils.ImageBinding (this.image_cover, 160);
            this.header_binding.load (cover_url);

            this.play_all_id = this.button_play_all.clicked.connect (this.on_play_all_clicked);

            this.row_activated_id = this.tracks_list.row_activated.connect ((row) => {
                int index = row.get_index ();
                if (index >= 0 && index < this.tracks.length) {
                    this.play_collection (this.tracks, index);
                }
            });

            this.load_collection_tracks ();
        }
        
        protected override void unroot () {
            this.released = true;

            if (this.row_activated_id != 0) {
                this.tracks_list.disconnect (this.row_activated_id);
                this.row_activated_id = 0;
            }
            if (this.play_all_id != 0) {
                this.button_play_all.disconnect (this.play_all_id);
                this.play_all_id = 0;
            }

        private void on_play_all_clicked () {
            if (this.tracks.length > 0) {
                this.play_collection (this.tracks, 0);
            }
        }
    }
}
