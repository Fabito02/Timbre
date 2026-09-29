namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/pages/collection.ui")]
    public class CollectionPage : Adw.NavigationPage {
        [GtkChild] private unowned Gtk.Picture image_cover;
        [GtkChild] private unowned Gtk.Label label_title;
        [GtkChild] private unowned Gtk.Label label_subtitle;
        [GtkChild] private unowned Gtk.Button button_play_all;
        [GtkChild] private unowned Gtk.Spinner spinner_loading;
        [GtkChild] private unowned Gtk.ListBox tracks_list;

        private unowned Timbre.Player player;
        private string collection_id;
        private string collection_type;
        private GenericArray<Timbre.TrackItem> tracks;

        private Timbre.Utils.ImageBinding header_binding;
        private ulong row_activated_id = 0;
        private ulong play_all_id = 0;

        private bool released = false;

        public signal void track_selected (string id, uint64 duration, string title, string artist, string? cover);
        public signal void play_collection (GenericArray<Timbre.TrackItem> tracks, int start_index);

        public CollectionPage (
            Timbre.Player player,
            string id,
            string type_name,
            string title,
            string subtitle,
            string? cover_url
        ) {
            Object (title: title);

            this.player = player;
            this.collection_id = id;
            this.collection_type = type_name.down ();
            this.tracks = new GenericArray<Timbre.TrackItem> ();

            this.label_title.label = title;
            this.label_subtitle.label = subtitle;

            this.header_binding = new Timbre.Utils.ImageBinding (this.image_cover, 160);
            this.header_binding.load (cover_url);

            this.play_all_id = this.button_play_all.clicked.connect (this.on_play_all_clicked);

            this.row_activated_id = this.tracks_list.row_activated.connect ((row) => {
                int index = row.get_index ();
                if (index >= 0 && index < this.tracks.length) {
                    this.play_collection (this.tracks, index);
                }
            });

            this.load_collection_tracks ();
        }

        protected override void unroot () {
            this.released = true;

            if (this.row_activated_id != 0) {
                this.tracks_list.disconnect (this.row_activated_id);
                this.row_activated_id = 0;
            }
            if (this.play_all_id != 0) {
                this.button_play_all.disconnect (this.play_all_id);
                this.play_all_id = 0;
            }

            Gtk.Widget? child = this.tracks_list.get_first_child ();
            while (child != null) {
                var next = child.get_next_sibling ();
                this.tracks_list.remove (child);
                child = next;
            }
            this.tracks = new GenericArray<Timbre.TrackItem> ();

            if (this.header_binding != null) {
                this.header_binding.dispose ();
                this.header_binding = null;
            }

            base.unroot ();
        }

        private void load_collection_tracks () {
            this.spinner_loading.visible = true;
            this.spinner_loading.spinning = true;
            this.tracks_list.visible = false;

            if (this.collection_type == "album") {
                this.player.get_album (this.collection_id, this.on_collection_loaded);
            } else {
                this.player.get_playlist (this.collection_id, this.on_collection_loaded);
            }
        }

        private void on_collection_loaded (char* json_ptr, char* error) {
            Idle.add (() => {
                if (this.released) {
                    if (error != null) Timbre.string_free (error);
                    if (json_ptr != null) Timbre.string_free (json_ptr);
                    return GLib.Source.REMOVE;
                }

                this.spinner_loading.spinning = false;
                this.spinner_loading.visible = false;

                if (error != null) {
                    warning ("collection: %s", (string) error);
                    Timbre.string_free (error);
                    return GLib.Source.REMOVE;
                }

                this.tracks = this.parse_tracks_json ((string) json_ptr);
                this.populate_tracks_list ();
                this.tracks_list.visible = true;
                Timbre.string_free (json_ptr);
                return GLib.Source.REMOVE;
            });
        }

        private GenericArray<Timbre.TrackItem> parse_tracks_json (string json_data) {
            var list = new GenericArray<Timbre.TrackItem> ();

            var parser = new Json.Parser ();
            try {
                parser.load_from_data (json_data);
            } catch (Error e) {
                warning ("collection json: %s", e.message);
                return list;
            }

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                return list;
            }

            var root_obj = root.get_object ();
            if (!root_obj.has_member ("tracks")) return list;

            var tracks_node = root_obj.get_member ("tracks");
            if (tracks_node == null || tracks_node.get_node_type () != Json.NodeType.ARRAY) {
                return list;
            }

            foreach (unowned Json.Node node in tracks_node.get_array ().get_elements ()) {
                if (node == null || node.get_node_type () != Json.NodeType.OBJECT) continue;
                var obj = node.get_object ();
                var track = new Timbre.TrackItem ();

                if (obj.has_member ("video_id") && !obj.get_null_member ("video_id")) {
                    track.id = obj.get_string_member ("video_id");
                } else if (obj.has_member ("id") && !obj.get_null_member ("id")) {
                    track.id = obj.get_string_member ("id");
                }

                if (obj.has_member ("title") && !obj.get_null_member ("title")) {
                    track.title = obj.get_string_member ("title");
                }

                string artist_name = "";
                if (obj.has_member ("artists") && !obj.get_null_member ("artists")) {
                    var artists_node = obj.get_member ("artists");
                    if (artists_node.get_node_type () == Json.NodeType.ARRAY) {
                        var sb = new StringBuilder ();
                        foreach (unowned Json.Node a_node in artists_node.get_array ().get_elements ()) {
                            string? name = null;
                            if (a_node.get_node_type () == Json.NodeType.OBJECT) {
                                var a_obj = a_node.get_object ();
                                if (a_obj.has_member ("name")) {
                                    name = a_obj.get_string_member ("name");
                                }
                            } else if (a_node.get_node_type () == Json.NodeType.VALUE) {
                                name = a_node.get_string ();
                            }
                            if (name != null) {
                                if (sb.len > 0) sb.append (", ");
                                sb.append (name);
                            }
                        }
                        artist_name = sb.str;
                    }
                } else if (obj.has_member ("artist") && !obj.get_null_member ("artist")) {
                    artist_name = obj.get_string_member ("artist");
                }
                track.artist = artist_name.length > 0 ? artist_name : _("Unknown");

                if (obj.has_member ("duration_seconds") && !obj.get_null_member ("duration_seconds")) {
                    track.duration_secs = (uint64) obj.get_int_member ("duration_seconds");
                }

                if (obj.has_member ("thumb") && !obj.get_null_member ("thumb")) {
                    track.thumbnail_url = obj.get_string_member ("thumb");
                } else if (obj.has_member ("thumbnail_url") && !obj.get_null_member ("thumbnail_url")) {
                    track.thumbnail_url = obj.get_string_member ("thumbnail_url");
                }

                list.add (track);
            }

            return list;
        }

        private void populate_tracks_list () {
            Gtk.Widget? child = this.tracks_list.get_first_child ();
            while (child != null) {
                var next = child.get_next_sibling ();
                this.tracks_list.remove (child);
                child = next;
            }

            bool is_album = this.collection_type == "album";
            for (int i = 0; i < this.tracks.length; i++) {
                var track = this.tracks.get (i);
                string display_title = track.title;
                string? display_cover = track.thumbnail_url;
                if (is_album) {
                    display_title = "%d. %s".printf (i + 1, track.title);
                    display_cover = null;
                }

                this.tracks_list.append (new Timbre.TrackRow (
                    track.id,
                    display_title,
                    track.artist,
                    track.duration_secs,
                    display_cover
                ));
            }
        }

        private void on_play_all_clicked () {
            if (this.tracks.length > 0) {
                this.play_collection (this.tracks, 0);
            }
        }
    }
}
