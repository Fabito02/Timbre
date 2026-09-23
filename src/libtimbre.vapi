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
        public bool explicit;
        public bool available;
        public int kind;
        public bool set_video_id;
        public bool liked;
        public uint64 views;
    }

    [Compact]
    [CCode (cname = "CTrackList", free_function = "timbre_track_list_free")]
    public class TrackList {
        [CCode (array_length_cname = "len")]
        public unowned Track[] items;
        public size_t len;
    }

    [CCode (cname = "CAlbum", has_type_id = false)]
    public struct AlbumItem {
        public unowned string id;
        public unowned string title;
        public unowned string artists;
        public unowned string? thumbnail_url;
    }

    [Compact]
    [CCode (cname = "CAlbumList", free_function = "timbre_album_list_free")]
    public class AlbumList {
        [CCode (array_length_cname = "len")]
        public unowned AlbumItem[] items;
        public size_t len;
    }

    [CCode (cname = "CPlaylist", has_type_id = false)]
    public struct PlaylistItem {
        public unowned string id;
        public unowned string title;
        public unowned string? author;
        public unowned string? thumbnail_url;
    }

    [Compact]
    [CCode (cname = "CPlaylistList", free_function = "timbre_playlist_list_free")]
    public class PlaylistList {
        [CCode (array_length_cname = "len")]
        public unowned PlaylistItem[] items;
        public size_t len;
    }

    [Compact]
    [CCode (cname = "CSuggestionList", free_function = "timbre_suggestion_list_free")]
    public class SuggestionList {
        [CCode (array_length_cname = "len")]
        public unowned string[] items;
        public size_t len;
    }

    [CCode (cname = "CHomeItem", has_type_id = false)]
    public struct CHomeItem {
        public int item_type;
        public Track* track;
        public AlbumItem* album;
        public PlaylistItem* playlist;
    }

    [CCode (cname = "CHomeSection", has_type_id = false)]
    public struct CHomeSection {
        public unowned string title;
        public CHomeItem* items;
        public size_t len;
    }

    [CCode (cname = "CHomeSectionList", has_type_id = false)]
    public struct CHomeSectionList {
        public CHomeSection* sections;
        public size_t len;
    }

    [CCode (cname = "CArtist", has_type_id = false)]
    public struct ArtistItem {
        public unowned string id;
        public unowned string name;
        public unowned string? thumbnail_url;
    }

    [Compact]
    [CCode (cname = "CArtistList", free_function = "timbre_artist_list_free")]
    public class ArtistList {
        [CCode (array_length_cname = "len")]
        public unowned ArtistItem[] items;
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

        [CCode (cname = "timbre_player_play_track_id")]
        public bool play_track_id (string track_id, uint64 duration_secs = 0);

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

        [CCode (cname = "timbre_player_search_tracks")]
        public TrackList? search_tracks (string query);

        [CCode (cname = "timbre_player_search_albums")]
        public AlbumList? search_albums (string query);

        [CCode (cname = "timbre_player_search_playlists")]
        public PlaylistList? search_playlists (string query);

        [CCode (cname = "timbre_player_search_suggestions")]
        public SuggestionList? search_suggestions (string query);

        [CCode (cname = "timbre_player_search_artists")]
        public ArtistList? search_artists (string query);

        [CCode (cname = "timbre_player_get_home_json")]
        public char* get_home_json ();

        [CCode (cname = "timbre_player_get_album_json")]
        public char* get_album_json (string album_id);

        [CCode (cname = "timbre_player_get_playlist_json")]
        public char* get_playlist_json (string playlist_id);

        [CCode (cname = "timbre_player_get_duration")]
        public double get_duration ();

        [CCode (cname = "timbre_player_login")]
        public bool login (string cookies, string path);

        [CCode (cname = "timbre_player_load_cookies")]
        public bool load_cookies (string path);
    }

    [CCode (cname = "timbre_string_free")]
    public static void string_free (char* s);
}
