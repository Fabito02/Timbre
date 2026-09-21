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
        private GenericArray<TrackItem> tracks;

        public signal void track_selected (string id, uint64 duration, string title, string artist, string? cover);
        public signal void play_collection (GenericArray<TrackItem> tracks, int start_index);

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
            this.collection_type = type_name;
            this.tracks = new GenericArray<TrackItem> ();

            this.label_title.label = title;
            this.label_subtitle.label = subtitle;

            var display = Gdk.Display.get_default ();
            if (display != null) {
                int scale = this.get_scale_factor ();
                Timbre.Utils.ImageLoader.get_default ().load_paintable_async.begin (
                    cover_url,
                    display,
                    160,
                    scale,
                    "audio-x-generic-symbolic",
                    (obj, res) => {
                        this.image_cover.paintable = Timbre.Utils.ImageLoader.get_default ().load_paintable_async.end (res);
                    }
                );
            }

            this.button_play_all.clicked.connect (this.on_play_all_clicked);

            this.load_collection_tracks ();

            this.tracks_list.row_activated.connect ((row) => {
                int index = row.get_index ();
                if (index >= 0 && index < this.tracks.length) {
                    this.play_collection (this.tracks, index);
                }
            });
        }

        private void load_collection_tracks () {
            this.spinner_loading.visible = true;
            this.spinner_loading.spinning = true;
            this.tracks_list.visible = false;

            new Thread<void*> ("collection-worker", () => {
                char* raw_ptr = null;

                if (this.collection_type == "album") {
                    raw_ptr = this.player.get_album_json (this.collection_id);
                } else {
                    raw_ptr = this.player.get_playlist_json (this.collection_id);
                }

                if (raw_ptr == null) {
                    Idle.add (() => {
                        this.spinner_loading.spinning = false;
                        this.spinner_loading.visible = false;
                        return Source.REMOVE;
                    });
                    return null;
                }

                string json_data = (string) raw_ptr;
                Timbre.string_free (raw_ptr);

                var parsed_tracks = this.parse_tracks_json (json_data);

                Idle.add (() => {
                    this.tracks = parsed_tracks;
                    this.populate_tracks_list ();

                    this.spinner_loading.spinning = false;
                    this.spinner_loading.visible = false;
                    this.tracks_list.visible = true;

                    return Source.REMOVE;
                });

                return null;
            });
        }

        private GenericArray<Timbre.TrackItem> parse_tracks_json (string json_data) {
            var list = new GenericArray<Timbre.TrackItem> ();
        
            var parser = new Json.Parser ();
            parser.load_from_data (json_data);
    
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                return list;
            }
    
            var root_obj = root.get_object ();
            if (!root_obj.has_member ("tracks")) {
                return list;
            }
    
            var tracks_node = root_obj.get_member ("tracks");
            if (tracks_node == null || tracks_node.get_node_type () != Json.NodeType.ARRAY) {
                return list;
            }

            var tracks_arr = tracks_node.get_array ();
            foreach (unowned Json.Node node in tracks_arr.get_elements ()) {
                if (node == null || node.get_node_type () != Json.NodeType.OBJECT) continue;
                var obj = node.get_object ();
    
                var track = new Timbre.TrackItem ();
    
                if (obj.has_member ("video_id") && obj.get_member ("video_id").get_node_type () == Json.NodeType.VALUE && !obj.get_null_member ("video_id")) {
                    track.id = obj.get_string_member ("video_id");
                } else if (obj.has_member ("id") && obj.get_member ("id").get_node_type () == Json.NodeType.VALUE && !obj.get_null_member ("id")) {
                    track.id = obj.get_string_member ("id");
                }
                
                if (obj.has_member ("title") && obj.get_member ("title").get_node_type () == Json.NodeType.VALUE) {
                    track.title = obj.get_string_member ("title");
                }
    
                string artist_name = _("Unknown");
                if (obj.has_member ("artists")) {
                    var artists_node = obj.get_member ("artists");
                    if (artists_node != null && artists_node.get_node_type () == Json.NodeType.ARRAY) {
                        var names = new GenericArray<string> ();
                        foreach (unowned Json.Node a_node in artists_node.get_array ().get_elements ()) {
                            if (a_node != null && a_node.get_node_type () == Json.NodeType.OBJECT) {
                                var a_obj = a_node.get_object ();
                                if (a_obj.has_member ("name") && a_obj.get_member ("name").get_node_type () == Json.NodeType.VALUE) {
                                    names.add (a_obj.get_string_member ("name"));
                                }
                            } else if (a_node != null && a_node.get_node_type () == Json.NodeType.VALUE) {
                                names.add (a_node.get_string ());
                            }
                        }
                        if (names.length > 0) {
                            string[] raw = new string[names.length];
                            for (int j = 0; j < names.length; j++) raw[j] = names.get (j);
                            artist_name = string.joinv (", ", raw);
                        }
                    } else if (artists_node != null && artists_node.get_node_type () == Json.NodeType.VALUE) {
                        artist_name = artists_node.get_string ();
                    }
                } else if (obj.has_member ("author")) {
                    var author_node = obj.get_member ("author");
                    if (author_node != null && author_node.get_node_type () == Json.NodeType.VALUE) {
                        artist_name = author_node.get_string ();
                    }
                }
                track.artist = artist_name;
    
                if (obj.has_member ("duration") && obj.get_member ("duration").get_node_type () == Json.NodeType.OBJECT) {
                    var dur_obj = obj.get_object_member ("duration");
                    if (dur_obj.has_member ("secs")) {
                        track.duration_secs = (uint64) dur_obj.get_int_member ("secs");
                    }
                } else if (obj.has_member ("duration_secs") && obj.get_member ("duration_secs").get_node_type () == Json.NodeType.VALUE) {
                    track.duration_secs = (uint64) obj.get_int_member ("duration_secs");
                } else if (obj.has_member ("duration") && obj.get_member ("duration").get_node_type () == Json.NodeType.VALUE) {
                    track.duration_secs = (uint64) obj.get_int_member ("duration");
                }
    
                if (obj.has_member ("thumbnail_url") && obj.get_member ("thumbnail_url").get_node_type () == Json.NodeType.VALUE) {
                    track.thumbnail_url = obj.get_string_member ("thumbnail_url");
                } else if (obj.has_member ("thumbnails")) {
                    var thumbs_node = obj.get_member ("thumbnails");
                    if (thumbs_node != null && thumbs_node.get_node_type () == Json.NodeType.ARRAY) {
                        var thumbs_arr = thumbs_node.get_array ();
                        if (thumbs_arr.get_length () > 0) {
                            var thumb_obj = thumbs_arr.get_object_element (thumbs_arr.get_length () - 1);
                            if (thumb_obj != null && thumb_obj.has_member ("url") && thumb_obj.get_member ("url").get_node_type () == Json.NodeType.VALUE) {
                                track.thumbnail_url = thumb_obj.get_string_member ("url");
                            }
                        }
                    }
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
        
            for (int i = 0; i < this.tracks.length; i++) {
                var track = this.tracks.get (i);
                
                string display_title = track.title;
                string? display_cover = track.thumbnail_url;

                if (this.collection_type == "album") {
                    display_title = "%d. %s".printf (i + 1, track.title);
                    display_cover = null;
                }

                var row = new Timbre.TrackRow (
                    track.id,
                    display_title,
                    track.artist,
                    track.duration_secs,
                    display_cover
                );
                this.tracks_list.append (row);
            }
        }

        private void on_play_all_clicked () {
            if (this.tracks.length > 0) {
                this.play_collection (this.tracks, 0);
            }
        }
    }
}
