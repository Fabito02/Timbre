[CCode (cprefix = "Timbre", lower_case_cprefix = "timbre_", cheader_filename = "libtimbre.h")]
namespace Timbre {
    [CCode (cname = "CTrack", has_type_id = false)]
    public struct Track {
        public unowned string id;
        public unowned string title;
        public unowned string artists;
        public unowned string? album;
        public unowned string? thumbnail_url;
        public uint64 duration_secs;
    }

    [Compact]
    [CCode (cname = "CTrackList", free_function = "timbre_track_list_free")]
    public class TrackList {
        public Track* items;
        public size_t len;
    }

    [Compact]
    [CCode (cname = "TimbrePlayerHandle", free_function = "timbre_player_free")]
    public class Player {
        [CCode (cname = "timbre_player_new")]
        public Player ();

        [CCode (cname = "timbre_player_play_file")]
        public bool play_file (string path);

        [CCode (cname = "timbre_player_play_url")]
        public bool play_url (string url, uint64 duration_secs = 0);

        [CCode (cname = "timbre_player_pause")]
        public void pause ();

        [CCode (cname = "timbre_player_resume")]
        public void resume ();

        [CCode (cname = "timbre_player_stop")]
        public void stop ();

        [CCode (cname = "timbre_player_seek")]
        public bool seek (double target_secs);

        [CCode (cname = "timbre_player_get_position")]
        public double get_position ();

        [CCode (cname = "timbre_player_is_finished")]
        public bool is_finished ();

        [CCode (cname = "timbre_player_play_track_id")]
        public bool play_track_id (string track_id, uint64 duration_secs = 0);

        [CCode (cname = "timbre_player_search_tracks")]
        public TrackList? search_tracks (string query);
    }
}
