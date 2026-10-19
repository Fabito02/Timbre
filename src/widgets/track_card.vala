namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/widgets/track_card.ui")]
    public class TrackCard : Gtk.Button {
        [GtkChild] private unowned Gtk.Picture image_cover;
        [GtkChild] private unowned Gtk.Label label_title;
        [GtkChild] private unowned Gtk.Label label_artist;
        [GtkChild] private unowned Gtk.Label explicit_badge;
        [GtkChild] private unowned Gtk.Box live_overlay;
        [GtkChild] private unowned Adw.Bin album_overlay;
        [GtkChild] private unowned Adw.Bin play_overlay;

        public MediaItem media_item { get; private set; }
        public string track_id { get { return media_item.id; } }
        public string item_type { get { return media_item.kind.to_string (); } }

        private Timbre.Utils.ImageBinding cover_binding;

        public TrackCard (MediaItem item) {
            Object ();
            this.media_item = item;

            this.label_title.label = item.title;
            this.label_artist.label = item.subtitle_text ();

            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 144);
            this.cover_binding.load (item.thumb);

            if (item.kind == ItemKind.ARTIST) {
                this.add_css_class ("artist");
            }

            this.play_overlay.visible = item.kind.is_playable ();
            this.album_overlay.visible = (item.kind == ItemKind.ALBUM);
            this.live_overlay.visible = item.is_live;
            this.explicit_badge.visible = item.explicit;

            if (item.kind == ItemKind.VIDEO) {
                this.image_cover.width_request = 256;
                this.image_cover.height_request = 144;
            } else {
                this.image_cover.width_request = 144;
                this.image_cover.height_request = 144;
            }

            this.label_title.max_width_chars = (item.kind == ItemKind.VIDEO) ? 32 : 20;
            this.label_artist.max_width_chars = (item.kind == ItemKind.VIDEO) ? 32 : 20;
        }
    }
}
