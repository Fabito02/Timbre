namespace Timbre {

    public class SearchItem : Object {
        public string kind { get; set; default = ""; }
        public string id { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public string subtitle { get; set; default = ""; }
        public string? thumb { get; set; default = null; }
        public uint64 duration { get; set; default = 0; }
        public string item_type { get; set; default = ""; }
        public LikeStatus like_status { get; set; default = LikeStatus.INDIFFERENT; }
    }

    [GtkTemplate (ui = "/io/github/fabito02/Timbre/widgets/search.ui")]
    public class SearchPage : Gtk.Box {
        [GtkChild] private unowned Adw.ViewStack stack;
        [GtkChild] private unowned Gtk.Box toggle_container;
        [GtkChild] private unowned Gtk.Stack results_stack;

        [GtkChild] private unowned Adw.StatusPage main_page;
        [GtkChild] private unowned Adw.StatusPage status_page;

        public signal void track_selected (string track_id, uint64 duration_secs, string title, string artist, string? cover_url);
        public signal void collection_selected (string id, string type_name, string title, string subtitle, string? cover_url);

        private unowned Timbre.Player? player;
        private bool released = false;
        private Adw.ToggleGroup? current_group = null;

        public SearchPage () {
            Object ();
            this.stack.visible_child_name = "main";
        }

        public void set_player (Timbre.Player player) {
            this.player = player;
        }

        public void clear () {
            if (this.released) return;
            this.clear_results ();
            this.stack.visible_child_name = "main";
        }

        public void show_loading () {
            if (this.released) return;
            this.stack.visible_child_name = "loading";
        }

        public void set_results_json (string json_data) {
            if (this.released) return;
            this.clear_results ();

            var parser = new Json.Parser ();
            try {
                parser.load_from_data (json_data);
            } catch (Error e) {
                warning ("search json: %s", e.message);
                this.stack.visible_child_name = "empty";
                return;
            }

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                this.stack.visible_child_name = "empty";
                return;
            }

            var obj = root.get_object ();

            SearchItem? top = null;
            if (obj.has_member ("top_result") && !obj.get_null_member ("top_result")) {
                var n = obj.get_member ("top_result");
                if (n.get_node_type () == Json.NodeType.OBJECT) {
                    top = this.parse_item (n.get_object ());
                }
            }

            var all = new GenericArray<SearchItem> ();
            if (obj.has_member ("items") && !obj.get_null_member ("items")) {
                var arr = obj.get_array_member ("items");
                foreach (unowned Json.Node node in arr.get_elements ()) {
                    if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                    var s = this.parse_item (node.get_object ());
                    if (s != null) all.add (s);
                }
            }

            if (top == null && all.length == 0) {
                this.stack.visible_child_name = "empty";
                return;
            }

            var songs = new GenericArray<SearchItem> ();
            var artists = new GenericArray<SearchItem> ();
            var playlists = new GenericArray<SearchItem> ();
            var albums = new GenericArray<SearchItem> ();
            var videos = new GenericArray<SearchItem> ();
            var episodes = new GenericArray<SearchItem> ();

            for (int i = 0; i < all.length; i++) {
                var it = all.get (i);
                switch (it.kind) {
                    case "Song":     songs.add (it); break;
                    case "Artist":   artists.add (it); break;
                    case "Playlist": playlists.add (it); break;
                    case "Album":    albums.add (it); break;
                    case "Video":
                        if (it.item_type == "Episode") episodes.add (it);
                        else videos.add (it);
                        break;
                }
            }

            var group = new Adw.ToggleGroup ();
            group.add_css_class ("round");
            group.halign = Gtk.Align.CENTER;
            this.current_group = group;

            var main = this.make_tab (group, _("Main"), "applications-other-symbolic", "main");
            if (top != null) {
                var single = new GenericArray<SearchItem> ();
                single.add (top);
                this.add_section (main, _("Top Result"), single, true);
            }
            if (all.length > 0) {
                this.add_section (main, _("Relevant Results"), all, false);
            }

            if (songs.length > 0) {
                var p = this.make_tab (group, _("Songs"), "audio-x-generic-symbolic", "songs");
                this.add_section (p, _("Songs"), songs, false);
            }

            if (artists.length > 0) {
                var p = this.make_tab (group, _("Artists"), "music-artist-symbolic", "artists");
                this.add_section (p, _("Artists"), artists, false);
            }

            if (playlists.length > 0) {
                var p = this.make_tab (group, _("Community Playlists"), "music-playlist-symbolic", "playlists");
                this.add_section (p, _("Playlists"), playlists, false);
            }

            if (albums.length > 0 || videos.length > 0 || episodes.length > 0) {
                var p = this.make_tab (group, _("Other results"), "media-optical-symbolic", "others");
                if (albums.length > 0)   this.add_section (p, _("Albums"), albums, false);
                if (videos.length > 0)   this.add_section (p, _("Videos"), videos, false);
                if (episodes.length > 0) this.add_section (p, _("More results"), episodes, false);
            }

            group.notify["active-name"].connect ((obj, pspec) => {
                if (this.released) return;
                string? name = group.active_name;
                if (name == null || name.length == 0) return;
                if (this.results_stack.get_child_by_name (name) == null) return;
                this.results_stack.visible_child_name = name;
            });

            group.active_name = "main";
            this.results_stack.visible_child_name = "main";

            this.toggle_container.append (group);

            this.stack.visible_child_name = "results";
        }

        private static LikeStatus parse_like_status (string s) {
            switch (s) {
                case "Like":    return LikeStatus.LIKE;
                case "Dislike": return LikeStatus.DISLIKE;
                default:        return LikeStatus.INDIFFERENT;
            }
        }

        private SearchItem? parse_item (Json.Object obj) {
            string id = this.json_str (obj, "id");
            if (id.length == 0) return null;

            var s = new SearchItem ();
            s.kind = this.json_str (obj, "kind");
            s.id = id;
            s.title = this.json_str (obj, "title");
            s.item_type = this.json_str (obj, "item_type");

            var sb = new StringBuilder ();
            if (obj.has_member ("artists") && !obj.get_null_member ("artists")) {
                var a = obj.get_member ("artists");
                if (a.get_node_type () == Json.NodeType.ARRAY) {
                    foreach (unowned Json.Node n in a.get_array ().get_elements ()) {
                        if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                        var ao = n.get_object ();
                        if (!ao.has_member ("name") || ao.get_null_member ("name")) continue;
                        if (sb.len > 0) sb.append (", ");
                        sb.append (ao.get_string_member ("name"));
                    }
                }
            }
            string artists_text = sb.str;

            switch (s.kind) {
                case "Album":
                    s.subtitle = artists_text.length > 0 ? artists_text : _("Album");
                    break;
                case "Artist":
                    s.subtitle = this.json_str (obj, "subscribers");
                    if (s.subtitle.length == 0) s.subtitle = _("Artist");
                    break;
                case "Playlist":
                    string count = this.json_str (obj, "count");
                    s.subtitle = count.length > 0 ? "%s songs".printf (count) : _("Playlist");
                    break;
                default:
                    s.subtitle = artists_text;
                    break;
            }

            if (obj.has_member ("thumb") && !obj.get_null_member ("thumb"))
                s.thumb = obj.get_string_member ("thumb");
            if (obj.has_member ("duration_seconds") && !obj.get_null_member ("duration_seconds"))
                s.duration = (uint64) obj.get_int_member ("duration_seconds");

            if (obj.has_member ("like_status") && !obj.get_null_member ("like_status"))
                s.like_status = parse_like_status (obj.get_string_member ("like_status"));

            return s;
        }

        private string json_str (Json.Object obj, string key) {
            if (!obj.has_member (key)) return "";
            if (obj.get_null_member (key)) return "";
            return obj.get_string_member (key);
        }

        private Gtk.Box make_tab (Adw.ToggleGroup group, string label, string icon, string id) {
            var page = new Gtk.Box (Gtk.Orientation.VERTICAL, 24) {
                margin_top = 12,
                margin_bottom = 24,
                margin_start = 12,
                margin_end = 12,
                valign = Gtk.Align.START
            };
            this.results_stack.add_named (page, id);

            var toggle = new Adw.Toggle () {
                name = id,
                label = label,
                icon_name = icon
            };
            group.add (toggle);

            return page;
        }

        private void add_section (Gtk.Box parent, string title,
                                  GenericArray<SearchItem> items, bool is_top) {
            if (items.length == 0) return;

            var section = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);

            var label = new Gtk.Label (title) { halign = Gtk.Align.START };
            label.add_css_class ("title-4");
            section.append (label);

            var list = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE };
            list.add_css_class ("boxed-list");
            list.add_css_class ("songs-list");

            for (int i = 0; i < items.length; i++) {
                var item = items.get (i);
                var row = new Timbre.TrackRow.simple (
                    item.kind, item.id, item.title, item.subtitle,
                    item.duration, item.thumb);
                if (is_top) {
                    row.add_css_class ("search-top-result");
                }
                list.append (row);
            }

            var items_ref = items;
            list.row_activated.connect ((row) => {
                if (this.released) return;
                int idx = row.get_index ();
                if (idx < 0 || idx >= items_ref.length) return;
                var it = items_ref.get (idx);

                if (it.kind == "Song" || it.kind == "Video") {
                    this.track_selected (it.id, it.duration,
                                         it.title, it.subtitle, it.thumb);
                } else {
                    this.collection_selected (it.id, it.kind.down (),
                                              it.title, it.subtitle, it.thumb);
                }
            });

            section.append (list);
            parent.append (section);
        }

        private void clear_results () {
            this.current_group = null;

            Gtk.Widget? c = this.toggle_container.get_first_child ();
            while (c != null) {
                var next = c.get_next_sibling ();
                this.toggle_container.remove (c);
                c = next;
            }

            Gtk.Widget? child = this.results_stack.get_first_child ();
            while (child != null) {
                var next = child.get_next_sibling ();
                this.results_stack.remove (child);
                child = next;
            }
        }

        protected override void unroot () {
            this.released = true;
            this.player = null;
            base.unroot ();
        }
    }
}
