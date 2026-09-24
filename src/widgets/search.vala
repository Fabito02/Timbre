namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/widgets/search.ui")]
    public class SearchPage : Gtk.Box {
        [GtkChild] private unowned Gtk.Stack stack;

        [GtkChild] private unowned Gtk.Box boxTopResults;
        [GtkChild] private unowned Gtk.Box boxMusics;
        [GtkChild] private unowned Gtk.Box boxPlaylists;
        [GtkChild] private unowned Gtk.Box boxOther;

        [GtkChild] private unowned Gtk.ListBox listboxTopResults;
        [GtkChild] private unowned Gtk.ListBox listboxMusics;
        [GtkChild] private unowned Gtk.ListBox listboxPlaylists;
        [GtkChild] private unowned Gtk.ListBox listboxOther;

        [GtkChild] private unowned Gtk.Widget search_page;
        [GtkChild] private unowned Gtk.Widget loading_page;
        [GtkChild] private unowned Adw.StatusPage status_page;
        [GtkChild] private unowned Adw.StatusPage main_page;

        public signal void track_selected (string track_id, uint64 duration_secs, string title, string artist, string? cover_url);
        public signal void collection_selected (string id, string type_name, string title, string subtitle, string? cover_url);

        private unowned Timbre.Player? player;

        public SearchPage () {
            Object ();
            this.stack.visible_child = this.main_page;
        }

        [GtkCallback]
        private void on_row_activated (Gtk.ListBoxRow row) {
            var track_row = row as Timbre.TrackRow;
            if (track_row == null) return;

            var parent = row.get_parent ();
            if (parent == this.listboxMusics || parent == this.listboxTopResults) {
                this.track_selected (track_row.track_id, track_row.duration_secs,
                                     track_row.track_title, track_row.track_artist,
                                     track_row.track_cover);
            } else if (parent == this.listboxPlaylists) {
                this.collection_selected (track_row.track_id, "playlist",
                                          track_row.track_title, track_row.track_artist,
                                          track_row.track_cover);
            } else if (parent == this.listboxOther) {
                // The subtitle prefix tells albums from artists; it is set
                // when the row is populated in set_results_json.
                bool is_artist = track_row.track_artist.has_prefix ("Artista");
                this.collection_selected (track_row.track_id,
                                          is_artist ? "artist" : "album",
                                          track_row.track_title, track_row.track_artist,
                                          track_row.track_cover);
            }
        }

        public void set_player (Timbre.Player player) {
            this.player = player;
        }

        public void clear () {
            this.clear_list ();
            this.stack.visible_child = this.main_page;
        }

        public void show_loading () {
            this.stack.visible_child = this.loading_page;
        }

        public void set_results_json (string json_data) {
            this.clear_list ();
            this.boxTopResults.visible = false;

            var parser = new Json.Parser ();
            try {
                parser.load_from_data (json_data);
            } catch (Error e) {
                warning ("search json: %s", e.message);
                this.stack.visible_child = this.status_page;
                return;
            }

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                this.stack.visible_child = this.status_page;
                return;
            }

            var obj = root.get_object ();
            if (!obj.has_member ("items")) {
                this.stack.visible_child = this.status_page;
                return;
            }

            bool has_music = false;
            bool has_playlist = false;
            bool has_other = false;

            foreach (unowned Json.Node node in obj.get_array_member ("items").get_elements ()) {
                if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                var it = node.get_object ();

                string kind = it.has_member ("kind") ? it.get_string_member ("kind") : "";
                string id = it.has_member ("id") && !it.get_null_member ("id")
                    ? it.get_string_member ("id")
                    : "";
                string title = it.has_member ("title") ? it.get_string_member ("title") : "";

                var sb = new StringBuilder ();
                if (it.has_member ("artists") && !it.get_null_member ("artists")) {
                    foreach (unowned Json.Node a in it.get_array_member ("artists").get_elements ()) {
                        if (a.get_node_type () != Json.NodeType.OBJECT) continue;
                        var ao = a.get_object ();
                        if (!ao.has_member ("name")) continue;
                        if (sb.len > 0) sb.append (", ");
                        sb.append (ao.get_string_member ("name"));
                    }
                }
                string artists = sb.str;

                string? thumb = it.has_member ("thumb") && !it.get_null_member ("thumb")
                    ? it.get_string_member ("thumb")
                    : null;

                uint64 duration = it.has_member ("duration_seconds") && !it.get_null_member ("duration_seconds")
                    ? (uint64) it.get_int_member ("duration_seconds")
                    : 0;

                if (kind == "Song" || kind == "Video") {
                    has_music = true;
                    this.listboxMusics.append (new Timbre.TrackRow (id, title, artists, duration, thumb));
                } else if (kind == "Playlist") {
                    has_playlist = true;
                    this.listboxPlaylists.append (new Timbre.TrackRow (
                        id, title, artists.length > 0 ? artists : "Playlist", 0, thumb));
                } else if (kind == "Album") {
                    has_other = true;
                    this.listboxOther.append (new Timbre.TrackRow (id, title, "Álbum • " + artists, 0, thumb));
                } else if (kind == "Artist") {
                    has_other = true;
                    this.listboxOther.append (new Timbre.TrackRow (id, title, "Artista", 0, thumb));
                }
            }

            this.boxMusics.visible = has_music;
            this.boxPlaylists.visible = has_playlist;
            this.boxOther.visible = has_other;

            bool found = has_music || has_playlist || has_other;
            this.stack.visible_child = found ? this.search_page : this.status_page;
        }

        private void clear_list () {
            Gtk.ListBox[] boxes = {
                this.listboxTopResults,
                this.listboxMusics,
                this.listboxPlaylists,
                this.listboxOther,
            };
            foreach (var box in boxes) {
                Gtk.Widget? child = box.get_first_child ();
                while (child != null) {
                    var next = child.get_next_sibling ();
                    box.remove (child);
                    child = next;
                }
            }
        }
    }
}
