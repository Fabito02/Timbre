[CCode (cprefix = "Timbre", lower_case_cprefix = "timbre_", cheader_filename = "libtimbre.h")]
namespace Timbre {

    public delegate void JsonCallback (char* json, char* error);

    public delegate void DoneCallback (bool success, char* error);

    [CCode (cname = "TimbreUtils")]
    public class BlurCache : GLib.Object {
        [CCode (cname = "timbre_blur_image_from_file")]
        public static unowned string? blur_image_to_cache_from_file (string image_path, uint radius);
    }

    [Compact]
    [CCode (cname = "TimbrePlayerHandle", free_function = "timbre_player_free")]
    public class Player {

        [CCode (cname = "timbre_player_new")]
        public Player ();

        [CCode (cname = "timbre_player_play_file")]
        public bool play_file (string path);

        [CCode (cname = "timbre_player_play_url")]
        public bool play_url (string url, uint64 duration_secs,
            [CCode (scope = "async")] DoneCallback cb);

        [CCode (cname = "timbre_player_play_track_id")]
        public bool play_track_id (string track_id, uint64 duration_secs,
            [CCode (scope = "async")] DoneCallback cb);

        [CCode (cname = "timbre_player_pause")]  public void pause ();

        [CCode (cname = "timbre_player_resume")] public void resume ();

        [CCode (cname = "timbre_player_stop")]   public void stop ();

        [CCode (cname = "timbre_player_reset")]   public void reset ();

        [CCode (cname = "timbre_player_seek")]
        public bool seek (double target_secs);

        [CCode (cname = "timbre_player_get_position")] public double get_position ();

        [CCode (cname = "timbre_player_get_duration")] public double get_duration ();

        [CCode (cname = "timbre_player_is_finished")]  public bool is_finished ();

        [CCode (cname = "timbre_player_is_paused")]    public bool is_paused ();

        [CCode (cname = "timbre_player_set_volume")] public void set_volume (float v);

        [CCode (cname = "timbre_player_get_volume")] public float get_volume ();

        [CCode (cname = "timbre_player_get_state")]       public int get_state ();

        [CCode (cname = "timbre_player_take_last_error")] public char * take_last_error ();

        [CCode (cname = "timbre_player_get_stats")]       public char * get_stats ();

        [CCode (cname = "timbre_audio_stats")]
        public char * audio_stats ();

        [CCode (cname = "timbre_audio_list")]
        public char * audio_list (int kind);

        [CCode (cname = "timbre_audio_remove")]
        public bool audio_remove (string video_id,
            [CCode (scope = "async")] DoneCallback cb);

        [CCode (cname = "timbre_audio_clear")]
        public bool audio_clear (int kind,
            [CCode (scope = "async")] DoneCallback cb);

        [CCode (cname = "timbre_audio_set_cache_limit")]
        public void audio_set_cache_limit (uint64 bytes);

        [CCode (cname = "timbre_audio_download")]
        public bool audio_download (string track_id,
            [CCode (scope = "async")] DoneCallback cb);

        [CCode (cname = "timbre_player_get_home")]
        public bool get_home ([CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_get_explore")]
        public bool get_explore ([CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_get_charts")]
        public bool get_charts (string country, [CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_get_mood_categories")]
        public bool get_mood_categories ([CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_get_category_page")]
        public bool get_category_page (string params, [CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_get_album")]
        public bool get_album (string album_id, [CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_get_playlist")]
        public bool get_playlist (string playlist_id, [CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_get_artist")]
        public bool get_artist (string channel_id, [CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_get_radio")]
        public bool get_radio (string track_id, [CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_get_watch_playlist")]
        public bool get_watch_playlist (string video_id, string playlist_id,
            [CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_get_library_playlists")]
        public bool get_library_playlists ([CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_get_library_albums")]
        public bool get_library_albums ([CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_get_library_subscriptions")]
        public bool get_library_subscriptions ([CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_get_history")]
        public bool get_history ([CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_search")]
        public bool search (string query, [CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_search_suggestions")]
        public bool search_suggestions (string query, [CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_get_account")]
        public bool get_account ([CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_is_authenticated")]
        public bool is_authenticated ();

        [CCode (cname = "timbre_player_login")]
        public bool login (string input, [CCode (scope = "async")] DoneCallback cb);

        [CCode (cname = "timbre_player_logout")]
        public bool logout ([CCode (scope = "async")] DoneCallback cb);

        [CCode (cname = "timbre_player_rate_track")]
        public bool rate_track (string track_id, int rating,
            [CCode (scope = "async")] DoneCallback cb);

        [CCode (cname = "timbre_player_subscribe_artist")]
        public bool subscribe_artist (string channel_id, bool subscribe,
            [CCode (scope = "async")] DoneCallback cb);

        [CCode (cname = "timbre_player_remove_history")]
        public bool remove_history (string tokens_json,
            [CCode (scope = "async")] DoneCallback cb);

        [CCode (cname = "timbre_player_add_to_playlist")]
        public bool add_to_playlist (string playlist_id, string track_ids_json,
            [CCode (scope = "async")] DoneCallback cb);

        [CCode (cname = "timbre_player_create_playlist")]
        public bool create_playlist (string title, string description, string privacy,
            [CCode (scope = "async")] JsonCallback cb);

        [CCode (cname = "timbre_player_delete_playlist")]
        public bool delete_playlist (string playlist_id,
            [CCode (scope = "async")] DoneCallback cb);

        [CCode (cname = "timbre_player_edit_playlist")]
        public bool edit_playlist (string playlist_id, string title, string description,
            string privacy,
            [CCode (scope = "async")] DoneCallback cb);

        [CCode (cname = "timbre_player_record_play_start")]
        public bool record_play_start (string track_id,
            [CCode (scope = "async")] DoneCallback cb);

        [CCode (cname = "timbre_player_record_play_tick")]
        public void record_play_tick (string track_id, double position_secs);

        [CCode (cname = "timbre_player_record_play_end")]
        public void record_play_end (string track_id);

        [CCode (cname = "timbre_audio_release_sink")]
        public void audio_release_sink ();

        [CCode (cname = "timbre_audio_rebuild_sink")]
        public bool audio_rebuild_sink ();

        [CCode (cname = "timbre_player_set_active")]
        public void set_active (bool active);

        [CCode (cname = "timbre_player_browse_section")]
        public bool browse_section (string args_json,
            [CCode (scope = "async")] JsonCallback cb);
    }

    [CCode (cname = "timbre_string_free")]
    public static void string_free (char* s);

    [CCode (cname = "timbre_set_log_level")]
    public static void set_log_level (int level);

    [CCode (cname = "timbre_set_locale")]
    public static void set_locale (string hl, string gl);
}
