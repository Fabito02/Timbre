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
                this.track_selected (track_row.track_id, track_row.duration_secs, track_row.track_title, track_row.track_artist, track_row.track_cover);
            } else if (parent == this.listboxPlaylists) {
                this.collection_selected (track_row.track_id, "playlist", track_row.track_title, track_row.track_artist, track_row.track_cover);
            } else if (parent == this.listboxOther) {
                if (track_row.track_artist.contains (_("Artist"))) {
                    this.collection_selected (track_row.track_id, "album", track_row.track_title, track_row.track_artist, track_row.track_cover);
                } else {
                    this.collection_selected (track_row.track_id, "album", track_row.track_title, track_row.track_artist, track_row.track_cover);
                }
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

        public void set_results (
            Timbre.SuggestionList? resultsSuggestions, 
            Timbre.TrackList? resultsMusics, 
            Timbre.AlbumList? resultsAlbums, 
            Timbre.PlaylistList? resultsPlaylists, 
            Timbre.ArtistList? resultsArtists
        ) {
            this.clear_list ();
            bool has_results = false;

            // 1. Top Results (Oculto por padrão até implementarmos um endpoint genérico no Rust)
            this.boxTopResults.visible = false; 

            // 2. Musics
            if (resultsMusics != null && resultsMusics.len > 0) {
                has_results = true;
                this.boxMusics.visible = true;
                for (int i = 0; i < resultsMusics.len; i++) {
                    var item = resultsMusics.items[i];
                    var row = new Timbre.TrackRow (item.id, item.title, item.artists, item.duration_secs, item.thumbnail_url);
                    this.listboxMusics.append (row);
                }
            } else {
                this.boxMusics.visible = false;
            }

            // 3. Playlists
            if (resultsPlaylists != null && resultsPlaylists.len > 0) {
                has_results = true;
                this.boxPlaylists.visible = true;
                for (int i = 0; i < resultsPlaylists.len; i++) {
                    var item = resultsPlaylists.items[i];
                    var row = new Timbre.TrackRow (item.id, item.title, item.author ?? "Playlist", 0, item.thumbnail_url);
                    this.listboxPlaylists.append (row);
                }
            } else {
                this.boxPlaylists.visible = false;
            }

            // 4. Other Results (Agrupando Sugestões, Álbuns e Artistas)
            bool has_other = false;
            
            if (resultsSuggestions != null && resultsSuggestions.len > 0) {
                has_results = true;
                has_other = true;
                for (int i = 0; i < resultsSuggestions.len; i++) {
                    string item = resultsSuggestions.items[i];
                    var row = new Timbre.TrackRow ("", item, "Sugestão", 0, null);
                    this.listboxOther.append (row);
                }
            }
            
            if (resultsAlbums != null && resultsAlbums.len > 0) {
                has_results = true;
                has_other = true;
                for (int i = 0; i < resultsAlbums.len; i++) {
                    var item = resultsAlbums.items[i];
                    var row = new Timbre.TrackRow (item.id, item.title, "Álbum • " + item.artists, 0, item.thumbnail_url);
                    this.listboxOther.append (row);
                }
            }
            
            if (resultsArtists != null && resultsArtists.len > 0) {
                has_results = true;
                has_other = true;
                for (int i = 0; i < resultsArtists.len; i++) {
                    var item = resultsArtists.items[i];
                    var row = new Timbre.TrackRow (item.id, item.name, "Artista", 0, item.thumbnail_url);
                    this.listboxOther.append (row);
                }
            }
            
            this.boxOther.visible = has_other;

            // Controle da interface final
            if (has_results) {
                this.stack.visible_child = this.search_page;
            } else {
                this.stack.visible_child = this.status_page;
            }
        }

        private void clear_list () {
            Gtk.Widget? child;
            
            child = this.listboxTopResults.get_first_child ();
            while (child != null) { var next = child.get_next_sibling (); this.listboxTopResults.remove (child); child = next; }

            child = this.listboxMusics.get_first_child ();
            while (child != null) { var next = child.get_next_sibling (); this.listboxMusics.remove (child); child = next; }

            child = this.listboxPlaylists.get_first_child ();
            while (child != null) { var next = child.get_next_sibling (); this.listboxPlaylists.remove (child); child = next; }

            child = this.listboxOther.get_first_child ();
            while (child != null) { var next = child.get_next_sibling (); this.listboxOther.remove (child); child = next; }
        }
    }
}
