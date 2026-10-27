namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/pages/collection.ui")]
    public class CollectionPage : Adw.NavigationPage {

        [GtkChild] private unowned Timbre.BannerFadeWrapper banner_fade_wrapper;
        [GtkChild] private unowned Gtk.Label label_title;
        [GtkChild] private unowned Gtk.Label label_subtitle;
        [GtkChild] private unowned Gtk.Label label_info;
        [GtkChild] private unowned Gtk.Button button_play_all;
        [GtkChild] private unowned Gtk.Button button_play_shuffle;
        [GtkChild] private unowned Gtk.Button button_play_radio;
        [GtkChild] private unowned Gtk.ListBox tracks_list;
        [GtkChild] private unowned Adw.Bin loading_box;
        [GtkChild] private unowned Gtk.Overlay header_overlay;
        [GtkChild] private unowned Gtk.Label label_description;
        [GtkChild] private unowned Gtk.Label label_read_more;
        [GtkChild] private unowned Adw.HeaderBar header_bar;

        [GtkChild] private unowned Gtk.ScrolledWindow scroll;

        private unowned Gtk.Picture image_cover;

        private unowned Timbre.Player player;
        private string collection_id;
        private string audio_playlist_id = null;
        private string collection_type;
        private GenericArray<Timbre.Track> tracks;

        private Timbre.Utils.ImageBinding header_binding;
        private ulong row_activated_id = 0;
        private ulong root_handler_id = 0;

        private ulong banner_map_id = 0;
        private ulong play_all_click_id = 0;
        private ulong shuffle_click_id = 0;
        private ulong radio_click_id = 0;
        private ulong read_more_id = 0;
        private ulong cover_paintable_id = 0;
        private ulong scroll_handler_id = 0;

        private string current_contrast_class = "";

        private bool released = false;
        private bool disposed_once = false;

        private bool description_expanded = false;
        private string description_full = "";
        private const int DESCRIPTION_PREVIEW = 280;

        private string thumb_album_url = "";

        public signal void play_collection (GenericArray<Timbre.Track> tracks, int start_index, bool shuffle);

        public CollectionPage (Timbre.Player player,
            string id,
            string type_name,
            string title,
            string subtitle,
            string? cover_url) {
            Object (title: title);

            this.player = player;
            this.collection_id = id;
            this.collection_type = type_name.down ();
            this.tracks = new GenericArray<Timbre.Track> ();

            this.label_title.label = title;
            this.label_subtitle.label = subtitle;

            this.thumb_album_url = cover_url;

            var pic = this.banner_fade_wrapper.get_first_child ();
            if (pic != null) {
                this.image_cover = (Gtk.Picture) pic;

                this.cover_paintable_id = this.image_cover.notify["paintable"].connect (() => {
                    var paintable = this.image_cover.paintable;
                    if (paintable == null || !(paintable is Gdk.Texture))return;

                    var texture = (Gdk.Texture) paintable;

                    GLib.Idle.add (() => {
                        if (!this.released) {
                            this.banner_fade_wrapper.queue_draw ();
                            this.update_header_contrast (texture);
                        }
                        return GLib.Source.REMOVE;
                    });
                });
            }

            this.banner_map_id = this.banner_fade_wrapper.map.connect (this.on_banner_map);

            this.header_binding = new Timbre.Utils.ImageBinding (this.image_cover, 1600);
            this.header_binding.load (cover_url);

            this.play_all_click_id = this.button_play_all.clicked.connect (this.on_play_all_clicked);
            this.shuffle_click_id = this.button_play_shuffle.clicked.connect (this.on_play_shuffle_clicked);
            this.radio_click_id = this.button_play_radio.clicked.connect (this.on_radio_clicked);

            this.row_activated_id = this.tracks_list.row_activated.connect ((row) => {
                int index = row.get_index ();
                if (index >= 0 && index < this.tracks.length) {
                    this.play_collection (this.tracks, index, false);
                }
            });

            this.read_more_id = this.label_read_more.activate_link.connect (() => {
                GLib.Idle.add (() => {
                    this.toggle_description ();
                    return GLib.Source.REMOVE;
                });
                return true;
            });

            this.scroll_handler_id = this.scroll.get_vadjustment ().value_changed.connect (() => {
                this.apply_contrast_class_if_at_top ();
            });

            this.header_overlay.visible = false;
            this.loading_box.visible = true;

            this.load_collection_tracks ();
        }

        private void on_banner_map () {
            var root = this.get_root ();
            if (root == null)return;

            this.update_fade_state (root);

            if (this.root_handler_id == 0) {
                this.root_handler_id = root.notify["css-classes"].connect (() => {
                    this.update_fade_state (root);
                });
            }
        }

        private void update_header_contrast (Gdk.Texture texture) {
            if (this.released)return;

            size_t stride;
            var bytes = new Gdk.TextureDownloader (texture).download_bytes (out stride);
            if (bytes == null)return;

            var data = bytes.get_data ();
            if (data == null || data.length == 0)return;

            double r = 0, g = 0, b = 0;
            int count = 0;
            for (int i = 0; i < data.length; i += 16) {
                r += data[i];
                g += data[i + 1];
                b += data[i + 2];
                count++;
            }

            if (count == 0)return;

            double lum = (0.2126 * (r / count) + 0.7152 * (g / count) + 0.0722 * (b / count)) / 255.0;

            this.current_contrast_class = (lum > 0.7) ? "light_background" : "dark_background";

            this.apply_contrast_class_if_at_top ();
        }

        private void apply_contrast_class_if_at_top () {
            if (this.current_contrast_class == "")return;

            var adj = this.scroll.get_vadjustment ();
            bool at_top = adj.get_value () <= 160;

            this.header_bar.remove_css_class ("dark_background");
            this.header_bar.remove_css_class ("light_background");
            this.header_bar.add_css_class ("header-gradient");

            if (at_top) {
                this.header_bar.add_css_class (this.current_contrast_class);
                this.header_bar.remove_css_class ("header-gradient");
            }
        }

        private void update_fade_state (Gtk.Widget root) {
            if (this.released)return;
            bool active = "cover-bg-active" in root.get_css_classes ();
            this.banner_fade_wrapper.fade_active = active;
        }

        protected override void unroot () {
            this.cleanup ();
            base.unroot ();
        }

        public override void dispose () {
            if (!this.disposed_once) {
                this.disposed_once = true;
                this.cleanup ();
            }
            base.dispose ();
        }

        private void cleanup () {
            this.released = true;

            if (this.root_handler_id != 0) {
                var root = this.get_root ();
                if (root != null)root.disconnect (this.root_handler_id);
                this.root_handler_id = 0;
            }
            if (this.banner_map_id != 0) {
                this.banner_fade_wrapper.disconnect (this.banner_map_id);
                this.banner_map_id = 0;
            }
            if (this.play_all_click_id != 0) {
                this.button_play_all.disconnect (this.play_all_click_id);
                this.play_all_click_id = 0;
            }
            if (this.shuffle_click_id != 0) {
                this.button_play_shuffle.disconnect (this.shuffle_click_id);
                this.shuffle_click_id = 0;
            }
            if (this.radio_click_id != 0) {
                this.button_play_radio.disconnect (this.radio_click_id);
                this.radio_click_id = 0;
            }
            if (this.read_more_id != 0) {
                this.label_read_more.disconnect (this.read_more_id);
                this.read_more_id = 0;
            }
            if (this.cover_paintable_id != 0) {
                this.image_cover.disconnect (this.cover_paintable_id);
                this.cover_paintable_id = 0;
            }
            if (this.row_activated_id != 0) {
                this.tracks_list.disconnect (this.row_activated_id);
                this.row_activated_id = 0;
            }

            if (this.scroll_handler_id != 0) {
                this.scroll.get_vadjustment ().disconnect (this.scroll_handler_id);
                this.scroll_handler_id = 0;
            }

            this.clear_rows ();

            this.tracks = new GenericArray<Timbre.Track> ();

            if (this.header_binding != null) {
                this.header_binding.dispose ();
                this.header_binding = null;
            }
        }

        private void clear_rows () {
            this.tracks_list.unselect_all ();

            var rows = new GenericArray<unowned Timbre.TrackRow> ();
            Gtk.Widget? child = this.tracks_list.get_first_child ();
            while (child != null) {
                if (child is Timbre.TrackRow) {
                    rows.add ((Timbre.TrackRow) child);
                }
                child = child.get_next_sibling ();
            }

            foreach (unowned var row in rows) {
                row.release ();
            }

            this.tracks_list.remove_all ();
        }

        private void load_collection_tracks () {
            if (this.collection_type == "album") {
                this.player.get_album (this.collection_id, this.on_collection_loaded);
            } else {
                this.player.get_playlist (this.collection_id, this.on_collection_loaded);
            }
        }

        private void on_collection_loaded (char* json_ptr, char* error) {
            Idle.add (() => {
                if (this.released) {
                    if (error != null)Timbre.string_free (error);
                    if (json_ptr != null)Timbre.string_free (json_ptr);
                    return GLib.Source.REMOVE;
                }

                this.loading_box.visible = false;

                if (error != null) {
                    warning ("collection: %s", (string) error);
                    Timbre.string_free (error);
                    if (json_ptr != null)Timbre.string_free (json_ptr);
                    return GLib.Source.REMOVE;
                }

                this.tracks = this.parse_tracks_json ((string) json_ptr);

                if (this.tracks.length > 0) {
                    this.header_overlay.visible = true;
                    this.populate_tracks_list ();
                    this.tracks_list.visible = true;
                }

                Timbre.string_free (json_ptr);
                return GLib.Source.REMOVE;
            });
        }

        private static LikeStatus parse_like_status (string s) {
            switch (s) {
            case "Like" : return LikeStatus.LIKE;
            case "Dislike": return LikeStatus.DISLIKE;
            default:        return LikeStatus.INDIFFERENT;
            }
        }

        private GenericArray<Timbre.Track> parse_tracks_json (string json_data) {
            var list = new GenericArray<Timbre.Track> ();

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

            var info_parts = new GenericArray<string> ();

            if (root_obj.has_member ("album_type") && !root_obj.get_null_member ("album_type")) {
                info_parts.add (root_obj.get_string_member ("album_type"));
            }

            var autores = new GenericArray<string> ();

            if (root_obj.has_member ("author") && !root_obj.get_null_member ("author")) {
                var author_node = root_obj.get_member ("author");
                if (author_node.get_node_type () == Json.NodeType.ARRAY) {
                    foreach (unowned Json.Node a_node in author_node.get_array ().get_elements ()) {
                        if (a_node.get_node_type () != Json.NodeType.OBJECT)continue;
                        var a_obj = a_node.get_object ();

                        if (a_obj.has_member ("name") && !a_obj.get_null_member ("name")) {
                            string nome = a_obj.get_string_member ("name");
                            if (nome.length > 0) {
                                autores.add (nome);
                            }
                        }
                    }
                }
            }

            var sb = new StringBuilder ();
            for (int i = 0; i < autores.length; i++) {
                if (sb.len > 0)sb.append (", ");
                sb.append (autores.get (i));
            }

            this.label_subtitle.label = sb.str;

            if (root_obj.has_member ("year") && !root_obj.get_null_member ("year")) {
                info_parts.add (root_obj.get_string_member ("year"));
            }

            if (root_obj.has_member ("track_count") && !root_obj.get_null_member ("track_count")) {
                int count = (int) root_obj.get_int_member ("track_count");
                string label = (count == 1) ? _("1 song") : _("%d songs").printf (count);
                info_parts.add (label);
            }

            if (root_obj.has_member ("duration") && !root_obj.get_null_member ("duration")) {
                info_parts.add (root_obj.get_string_member ("duration"));
            }

            sb = new StringBuilder ();
            for (int i = 0; i < info_parts.length; i++) {
                if (sb.len > 0)sb.append (" • ");
                sb.append (info_parts.get (i));
            }

            this.label_info.label = sb.str;

            string? raw_desc = null;
            if (root_obj.has_member ("description") && !root_obj.get_null_member ("description")) {
                raw_desc = root_obj.get_string_member ("description");
            }
            this.set_description (raw_desc);

            if (root_obj.has_member ("audio_playlist_id") && !root_obj.get_null_member ("audio_playlist_id")) {
                this.audio_playlist_id = root_obj.get_string_member ("audio_playlist_id");
            }

            if (!root_obj.has_member ("tracks"))return list;

            var tracks_node = root_obj.get_member ("tracks");
            if (tracks_node == null || tracks_node.get_node_type () != Json.NodeType.ARRAY) {
                return list;
            }

            foreach (unowned Json.Node node in tracks_node.get_array ().get_elements ()) {
                if (node == null || node.get_node_type () != Json.NodeType.OBJECT)continue;
                var obj = node.get_object ();
                var track = new Timbre.Track ();

                if (obj.has_member ("video_id") && !obj.get_null_member ("video_id")) {
                    track.id = obj.get_string_member ("video_id");
                } else if (obj.has_member ("id") && !obj.get_null_member ("id")) {
                    track.id = obj.get_string_member ("id");
                }

                if (obj.has_member ("title") && !obj.get_null_member ("title")) {
                    track.title = obj.get_string_member ("title");
                }

                if (obj.has_member ("artists") && !obj.get_null_member ("artists")) {
                    var artists_node = obj.get_member ("artists");
                    if (artists_node.get_node_type () == Json.NodeType.ARRAY) {
                        foreach (unowned Json.Node a_node in artists_node.get_array ().get_elements ()) {
                            if (a_node.get_node_type () != Json.NodeType.OBJECT)continue;
                            var a_obj = a_node.get_object ();
                            var p = new Person ();
                            if (a_obj.has_member ("name") && !a_obj.get_null_member ("name"))
                                p.name = a_obj.get_string_member ("name");
                            if (a_obj.has_member ("id") && !a_obj.get_null_member ("id"))
                                p.id = a_obj.get_string_member ("id");
                            track.artists.add (p);
                        }
                    }
                } else if (obj.has_member ("artist") && !obj.get_null_member ("artist")) {
                    var p = new Person ();
                    p.name = obj.get_string_member ("artist");
                    track.artists.add (p);
                }

                if (obj.has_member ("album") && !obj.get_null_member ("album")) {
                    var al_node = obj.get_member ("album");
                    if (al_node.get_node_type () == Json.NodeType.OBJECT) {
                        var ao = al_node.get_object ();
                        var named = new Named ();
                        if (ao.has_member ("name") && !ao.get_null_member ("name"))
                            named.name = ao.get_string_member ("name");
                        if (ao.has_member ("id") && !ao.get_null_member ("id"))
                            named.id = ao.get_string_member ("id");
                        track.album = named;
                    }
                }

                if (obj.has_member ("duration_seconds") && !obj.get_null_member ("duration_seconds")) {
                    track.duration_seconds = (uint) obj.get_int_member ("duration_seconds");
                }

                if (obj.has_member ("thumb") && !obj.get_null_member ("thumb")) {
                    track.thumb = obj.get_string_member ("thumb");
                }

                if (obj.has_member ("like_status") && !obj.get_null_member ("like_status")) {
                    track.like_status = parse_like_status (
                                                           obj.get_string_member ("like_status"));
                }

                if (obj.has_member ("is_live") && !obj.get_null_member ("is_live")) {
                    track.is_live = obj.get_boolean_member ("is_live");
                }

                if (obj.has_member ("explicit") && !obj.get_null_member ("explicit")) {
                    track.explicit = obj.get_boolean_member ("explicit");
                }

                list.add (track);
            }

            return list;
        }

        private void populate_tracks_list () {
            this.clear_rows ();

            bool is_album = this.collection_type == "album";
            for (int i = 0; i < this.tracks.length; i++) {
                var track = this.tracks.get (i);
                if (is_album)track.thumb = this.thumb_album_url;
                var index = is_album ? i : -1;
                this.tracks_list.append (new Timbre.TrackRow (this.player, track, index));
            }
        }

        private void on_play_all_clicked () {
            if (this.tracks.length > 0) {
                this.play_collection (this.tracks, 0, false);
            }
        }

        private void on_play_shuffle_clicked () {
            if (this.tracks.length > 0) {
                this.play_collection (this.tracks, 0, true);
            }
        }

        private void on_radio_clicked () {
            if (this.tracks.length == 0)return;

            string radio_id;

            if (this.collection_type == "album") {
                if (this.audio_playlist_id != null) {
                    radio_id = "RDAMPL" + this.audio_playlist_id;
                } else {
                    radio_id = this.tracks.get (Random.int_range (0, this.tracks.length)).id;
                }
            } else {
                string cid = this.collection_id;
                if (cid.has_prefix ("VL"))cid = cid.substring (2);
                radio_id = "RDAMPL" + cid;
            }

            this.player.get_radio (radio_id, (json, error) => {
                GLib.Idle.add (() => {
                    if (this.released) {
                        if (error != null)Timbre.string_free (error);
                        if (json != null)Timbre.string_free (json);
                        return GLib.Source.REMOVE;
                    }
                    if (error != null) {
                        warning ("radio: %s", (string) error);
                        Timbre.string_free (error);
                        return GLib.Source.REMOVE;
                    }
                    var tracks = this.parse_radio_tracks ((string) json);
                    Timbre.string_free (json);
                    if (tracks.length > 0)
                        this.play_collection (tracks, 0, false);
                    return GLib.Source.REMOVE;
                });
            });
        }

        private GenericArray<Track> parse_radio_tracks (string json_str) {
            var tracks = new GenericArray<Track> ();
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (json_str);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT)return tracks;
                var obj = root.get_object ();
                if (!obj.has_member ("tracks"))return tracks;
                var arr = obj.get_array_member ("tracks");
                foreach (unowned Json.Node node in arr.get_elements ()) {
                    if (node.get_node_type () != Json.NodeType.OBJECT)continue;
                    var wrapper = node.get_object ();
                    if (!wrapper.has_member ("track"))continue;
                    var t = ArtistParser.parse_track (wrapper.get_object_member ("track"));
                    if (t != null)tracks.add (t);
                }
            } catch (Error e) {
                debug ("radio parse: %s", e.message);
            }
            return tracks;
        }

        private void set_description (string? raw) {
            if (raw == null || raw.length == 0) {
                this.description_full = "";
                this.description_expanded = false;
                this.label_description.visible = false;
                this.label_read_more.visible = false;
                return;
            }

            var clean = raw.replace ("From Wikipedia", "").strip ();
            while (clean.contains ("  "))clean = clean.replace ("  ", " ");
            while (clean.contains ("\n\n\n"))clean = clean.replace ("\n\n\n", "\n\n");

            this.description_full = clean;
            this.description_expanded = false;

            if (clean.length > DESCRIPTION_PREVIEW) {
                this.label_description.label = this.preview_of (clean);
                this.label_read_more.label = "<a href='toggle'>" + _("Read more") + "</a>";
                this.label_read_more.visible = true;
            } else {
                this.label_description.label = clean;
                this.label_read_more.visible = false;
            }
            this.label_description.visible = true;
        }

        private string preview_of (string text) {
            int cut = int.min (DESCRIPTION_PREVIEW, text.length);
            string head = text.substring (0, cut);
            int sp = head.last_index_of_char (' ');
            if (sp > 0)head = head.substring (0, sp);
            return head + "…";
        }

        private void toggle_description () {
            if (this.description_full.length == 0)return;
            this.description_expanded = !this.description_expanded;
            if (this.description_expanded) {
                this.label_description.label = this.description_full;
                this.label_read_more.label = "<a href='toggle'>" + _("Show less") + "</a>";
            } else {
                this.label_description.label = this.preview_of (this.description_full);
                this.label_read_more.label = "<a href='toggle'>" + _("Read more") + "</a>";
            }
        }
    }
}
