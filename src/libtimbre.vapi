[CCode (cprefix = "Timbre", lower_case_cprefix = "timbre_", cheader_filename = "libtimbre.h")]
namespace Timbre {
    [CCode (cname = "TimbrePlayerHandle", free_function = "timbre_player_free")]
    [Compact]
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
    }
}