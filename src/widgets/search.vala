namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/widgets/search.ui")]
    public class SearchPage : Gtk.Box {
        [CCode (cname = "g_object_run_dispose", cheader_filename = "glib-object.h")]

        [GtkChild] private unowned Adw.ViewStack stack;
        [GtkChild] private unowned Gtk.Box toggle_container;
        [GtkChild] private unowned Gtk.Stack results_stack;

        [GtkChild] private unowned Adw.StatusPage main_page;
        [GtkChild] private unowned Adw.StatusPage status_page;

        public signal void track_selected (MediaItem item);
        public signal void collection_selected (MediaItem item);

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
        }

        public void show_loading () {
            if (this.released) return;
            this.clear_results ();
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

            MediaItem? top = null;
            if (obj.has_member ("top_result") && !obj.get_null_member ("top_result")) {
                var n = obj.get_member ("top_result");
                if (n.get_node_type () == Json.NodeType.OBJECT) {
                    top = this.parse_item (n.get_object ());
                }
            }

            var all = new GenericArray<MediaItem> ();
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

            var songs = new GenericArray<MediaItem> ();
            var artists = new GenericArray<MediaItem> ();
            var playlists = new GenericArray<MediaItem> ();
            var albums = new GenericArray<MediaItem> ();
            var videos = new GenericArray<MediaItem> ();
            var episodes = new GenericArray<MediaItem> ();

            foreach (var it in all) {
                switch (it.kind) {
                    case ItemKind.SONG:     songs.add (it); break;
                    case ItemKind.ARTIST:   artists.add (it); break;
                    case ItemKind.PLAYLIST: playlists.add (it); break;
                    case ItemKind.ALBUM:    albums.add (it); break;
                    case ItemKind.VIDEO:
                        if (it.item_type == "Episode") episodes.add (it);
                        else videos.add (it);
                        break;
                }
            }

            var group = new Adw.ToggleGroup ();
            group.add_css_class ("round");
            group.halign = Gtk.Align.CENTER;
            this.current_group = group;

            var main = this.make_tab (group, _("Main"), "blocks-symbolic", "main");
            if (top != null) {
                var single = new GenericArray<MediaItem> ();
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
                var p = this.make_tab (group, _("Other results"), "tape-symbolic", "others");
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

        private MediaItem? parse_item (Json.Object obj) {
            string id = this.json_str (obj, "id");
            if (id.length == 0) return null;

            var item = new MediaItem ();
            item.id = id;
            item.kind = ItemKind.parse (this.json_str (obj, "kind"));
            item.title = this.json_str (obj, "title");
            item.item_type = this.json_str (obj, "item_type");
            item.thumb = this.json_str (obj, "thumb");
            item.duration_seconds = (uint) this.json_int (obj, "duration_seconds");
            item.is_live = this.json_bool (obj, "is_live");
            item.explicit = this.json_bool (obj, "explicit");
            item.subscribers = this.json_str (obj, "subscribers");
            item.count = this.json_str (obj, "count");
            item.description = this.json_str (obj, "description");

            if (obj.has_member ("artists") && !obj.get_null_member ("artists")) {
                var artists_node = obj.get_member ("artists");
                if (artists_node.get_node_type () == Json.NodeType.ARRAY) {
                    foreach (unowned Json.Node a in artists_node.get_array ().get_elements ()) {
                        if (a.get_node_type () != Json.NodeType.OBJECT) continue;
                        var ao = a.get_object ();
                        var p = new Person ();
                        if (ao.has_member ("name") && !ao.get_null_member ("name"))
                            p.name = ao.get_string_member ("name");
                        if (ao.has_member ("id") && !ao.get_null_member ("id"))
                            p.id = ao.get_string_member ("id");
                        item.artists.add (p);
                    }
                }
            }

            return item;
        }

        private string json_str (Json.Object obj, string key) {
            if (!obj.has_member (key)) return "";
            if (obj.get_null_member (key)) return "";
            return obj.get_string_member (key);
        }

        private int json_int (Json.Object obj, string key) {
            if (!obj.has_member (key) || obj.get_null_member (key)) return 0;
            return (int) obj.get_int_member (key);
        }

        private bool json_bool (Json.Object obj, string key) {
            if (!obj.has_member (key) || obj.get_null_member (key)) return false;
            return obj.get_boolean_member (key);
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
                                  GenericArray<MediaItem> items, bool is_top) {
            if (items.length == 0) return;

            var section = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);

            var label = new Gtk.Label (title) { halign = Gtk.Align.START };
            label.add_css_class ("title-4");
            section.append (label);

            var list = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE };
            list.add_css_class ("boxed-list");
            list.add_css_class ("songs-list");

            foreach (var item in items) {
                var row = new Timbre.TrackRow.simple (item);
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

                if (it.kind.is_playable ())
                    this.track_selected (it);
                else
                    this.collection_selected (it);
            });

            section.append (list);
            parent.append (section);
        }

        protected override void unroot () {
            this.released = true;
            this.clear_results ();
            this.player = null;
            base.unroot ();
        }

        private void clear_results () {
            this.current_group = null;

            Gtk.Widget? page = this.results_stack.get_first_child ();
            while (page != null) {
                var next_page = page.get_next_sibling ();
                this.dispose_page_rows (page);
                this.results_stack.remove (page);
                page = next_page;
            }

            Gtk.Widget? c = this.toggle_container.get_first_child ();
            while (c != null) {
                var next = c.get_next_sibling ();
                this.toggle_container.remove (c);
                c = next;
            }
        }

        private void dispose_page_rows (Gtk.Widget page) {
            var listboxes = new GenericArray<Gtk.ListBox> ();
            this.collect_listboxes (page, listboxes);

            foreach (unowned var lb in listboxes) {
                var rows = new GenericArray<unowned Timbre.TrackRow> ();
                Gtk.Widget? child = lb.get_first_child ();
                while (child != null) {
                    if (child is Timbre.TrackRow) {
                        rows.add ((Timbre.TrackRow) child);
                    }
                    child = child.get_next_sibling ();
                }

                foreach (unowned var row in rows) {
                    row.release ();
                }

                lb.remove_all ();

            }
        }

        private void collect_listboxes (Gtk.Widget widget, GenericArray<Gtk.ListBox> listboxes) {
            if (widget is Gtk.ListBox) {
                listboxes.add ((Gtk.ListBox) widget);
                return;
            }
            Gtk.Widget? child = widget.get_first_child ();
            while (child != null) {
                this.collect_listboxes (child, listboxes);
                child = child.get_next_sibling ();
            }
        }
    }
}