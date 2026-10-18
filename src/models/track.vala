namespace Timbre {
    public class TrackItem : Object {
        public string id { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public string artist { get; set; default = ""; }
        public uint64 duration_secs { get; set; default = 0; }
        public string? thumbnail_url { get; set; default = null; }
        public bool is_live { get; set; default = false; }
        public bool explicit { get; set; default = false; }

        public LikeStatus? like_status = null;

        public TrackItem () {}

        public TrackItem.with_data (
            string id,
            string title,
            string artist,
            uint64 duration_secs = 0,
            string? thumbnail_url = null,
            LikeStatus? like_status = null,
            bool is_live = false,
            bool explicit = false
        ) {
            Object (
                id: id,
                title: title,
                artist: artist,
                duration_secs: duration_secs,
                thumbnail_url: thumbnail_url,
                is_live: is_live,
                explicit: explicit
            );
            this.like_status = like_status;
        }
    }
}

namespace Timbre {
    public class QueueItem : Object {
        public TrackItem track { get; construct; }
        public int index { get; set; }
        public bool is_playing { get; set; }

        public bool is_live {
            get { return this.track != null && this.track.is_live; }
        }
        public bool explicit {
            get { return this.track != null && this.track.explicit; }
        }

        public QueueItem (TrackItem track, int index, bool is_playing) {
            Object (
                track: track,
                index: index,
                is_playing: is_playing
            );
        }
    }
}