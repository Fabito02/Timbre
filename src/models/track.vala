namespace Timbre {
    public class TrackItem : Object {
        public string id { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public string artist { get; set; default = ""; }
        public uint64 duration_secs { get; set; default = 0; }
        public string? thumbnail_url { get; set; default = null; }

        public TrackItem () {}

        public TrackItem.with_data (
            string id,
            string title,
            string artist,
            uint64 duration_secs = 0,
            string? thumbnail_url = null
        ) {
            Object (
                id: id,
                title: title,
                artist: artist,
                duration_secs: duration_secs,
                thumbnail_url: thumbnail_url
            );
        }
    }
}

namespace Timbre {
    public class QueueItem : Object {
        public TrackItem track { get; construct; }
        public int index { get; set; }
        public bool is_playing { get; set; }

        public QueueItem (TrackItem track, int index, bool is_playing) {
            Object (
                track: track,
                index: index,
                is_playing: is_playing
            );
        }
    }
}
