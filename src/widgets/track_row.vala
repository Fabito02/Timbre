namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/widgets/track_row.ui")]
    public class TrackRow : Gtk.ListBoxRow {
        [GtkChild] private unowned Gtk.Picture image_cover;
        [GtkChild] private unowned Gtk.Label label_title;
        [GtkChild] private unowned Gtk.Label label_artist;
        [GtkChild] private unowned Gtk.Label label_duration;
        [GtkChild] private unowned Gtk.Box like_slot;
        [GtkChild] private unowned Gtk.Label explicit_badge;
        [GtkChild] private unowned Gtk.Box live_badge;

        public string media_kind { get; private set; }
        public string track_id { get; private set; }
        public uint64 duration_secs { get; private set; }
        public string track_title { get; private set; }
        public string track_artist { get; private set; }
        public string? track_cover { get; private set; }
        public bool is_live { get; private set; }
        public bool explicit { get; private set; }

        private Timbre.Utils.ImageBinding cover_binding;
        private Timbre.LikeButton? like_btn = null;

        public TrackRow.empty () {
            Object ();
            this.media_kind = "";
            this.track_id = "";
            this.duration_secs = 0;
            this.track_title = "";
            this.track_artist = "";
            this.track_cover = null;
            this.is_live = false;
            this.explicit = false;

            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 48);
            this.cover_binding.load (null);

            this.explicit_badge.visible = false;
            this.live_badge.visible = false;
        }

        public TrackRow (Timbre.Player player,
                         string kind,
                         string id, string title, string artists,
                         uint64 duration_secs, string? cover_url = null,
                         LikeStatus? status = null, bool is_live = false, bool explicit = false) {
            Object ();
            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 48);

            this.like_btn = new Timbre.LikeButton (player);
            this.like_slot.append (this.like_btn);

            this.set_content (kind, id, title, artists,
                              duration_secs, cover_url, status,
                              is_live, explicit);
        }

        public TrackRow.simple (string kind,
                                string id, string title, string artists,
                                uint64 duration_secs, string? cover_url = null,
                                bool is_live = false, bool explicit = false) {
            Object ();
            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 48);
            this.set_content (kind, id, title, artists,
                              duration_secs, cover_url, null, is_live, explicit);
        }

        public void set_content (string kind, string id, string title,
                                 string artists, uint64 duration_secs,
                                 string? cover_url = null,
                                 LikeStatus? status = null,
                                 bool is_live = false,
                                 bool explicit = false) {
            this.media_kind = kind;
            this.track_id = id;
            this.duration_secs = duration_secs;
            this.track_title = title;
            this.track_artist = artists;
            this.track_cover = cover_url;
            this.is_live = is_live;
            this.explicit = explicit;

            this.label_title.label = title;
            this.label_artist.label = artists;

            int s = (int) duration_secs;
            this.label_duration.label = "%d:%02d".printf (s / 60, s % 60);
            
            this.label_duration.visible = (duration_secs > 0) && !is_live;

            this.cover_binding.load (cover_url);

            if (this.like_btn != null) {
                string? vid = (id != null && id.length > 0) ? id : null;
                this.like_btn.set_target (vid, status);
            }

            if (kind == "Artist") {
                this.add_css_class ("artist");
            }

            this.explicit_badge.visible = explicit;
            this.live_badge.visible = is_live;
        }

        public override void dispose () {
            this.like_btn = null;
            base.dispose ();
        }
    }
}
