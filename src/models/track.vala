namespace Timbre {

    public enum ItemKind {
        SONG,
        VIDEO,
        ALBUM,
        ARTIST,
        PLAYLIST;

        public bool is_playable () {
            return this == ItemKind.SONG || this == ItemKind.VIDEO;
        }

        public static ItemKind parse (string s) {
            switch (s.down ()) {
                case "song":     return ItemKind.SONG;
                case "video":    return ItemKind.VIDEO;
                case "album":    return ItemKind.ALBUM;
                case "artist":   return ItemKind.ARTIST;
                case "playlist": return ItemKind.PLAYLIST;
                default:         return ItemKind.SONG;
            }
        }
    }

    public enum LikeStatus {
        LIKE,
        DISLIKE,
        INDIFFERENT;

        public static LikeStatus parse (string status) {
            switch (status) {
                case "LIKE":    return LikeStatus.LIKE;
                case "DISLIKE": return LikeStatus.DISLIKE;
                default:        return LikeStatus.INDIFFERENT;
            }
        }
    }

    public class Person : Object {
        public string name { get; set; default = ""; }
        public string? id { get; set; default = null; }
    }

    public class Named : Object {
        public string name { get; set; default = ""; }
        public string? id { get; set; default = null; }
    }

    public class MediaItem : Object {
        public ItemKind kind { get; set; default = ItemKind.SONG; }
        public string id { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public GLib.GenericArray<Person> artists { get; set; }
        public Named? album { get; set; default = null; }
        public string? thumb { get; set; default = null; }
        public string? views { get; set; default = null; }
        public string? subscribers { get; set; default = null; }
        public string? year { get; set; default = null; }
        public string? item_type { get; set; default = null; }
        public uint? duration_seconds { get; set; default = null; }
        public string? count { get; set; default = null; }
        public string? description { get; set; default = null; }
        public string? playlist_id { get; set; default = null; }
        public bool explicit { get; set; default = false; }
        public bool is_live { get; set; default = false; }

        public MediaItem () {
            this.artists = new GLib.GenericArray<Person> ();
        }

        public string artists_text () {
            string[] names = {};
            for (int i = 0; i < this.artists.length; i++) {
                names += this.artists.get (i).name;
            }
            return string.joinv (", ", names);
        }

        public string subtitle_text () {
            if (this.kind == ItemKind.ARTIST && this.subscribers != null && this.subscribers.length > 0)
                return this.subscribers;
            if (this.kind == ItemKind.PLAYLIST) {
                if (this.count != null && this.count.length > 0) return _("%s songs").printf (this.count);
                if (this.description != null && this.description.length > 0) return this.description;
            }
            string at = this.artists_text ();
            if (at.length > 0) return at;
            if (this.description != null) return this.description;
            if (this.year != null) return this.year;
            return "";
        }

        public Track to_track () {
            var t = new Track () {
                id = this.id,
                title = this.title,
                artists = this.artists,
                album = this.album,
                thumb = this.thumb,
                duration_seconds = this.duration_seconds,
                explicit = this.explicit,
                is_live = this.is_live
            };
            return t;
        }
    }

    public class Track : MediaItem {
        public LikeStatus like_status { get; set; default = LikeStatus.INDIFFERENT; }
        public string? video_type { get; set; default = null; }
        public string? entity_id { get; set; default = null; }
        public string? set_video_id { get; set; default = null; }
        public bool is_available { get; set; default = false; }
        public uint? track_number { get; set; default = null; }

        public string video_id {
            get { return this.id; }
            set { this.id = value; }
        }

        public Track () {
            base ();
        }
    }
}
