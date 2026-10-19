namespace Timbre {

    public class LibraryItem : Object {
        public string id { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public string subtitle { get; set; default = ""; }
        public string? thumb { get; set; default = null; }
        public string kind { get; set; default = ""; }
        public uint64 duration { get; set; default = 0; }
        public bool is_live { get; set; default = false; }
        public bool explicit { get; set; default = false; }
    }

    [GtkTemplate (ui = "/io/github/fabito02/Timbre/pages/library.ui")]
    public class LibraryPage : Adw.NavigationPage {

        [GtkChild] private unowned Gtk.Stack stack;
        [GtkChild] private unowned Gtk.Box content_box;
        [GtkChild] private unowned Gtk.Box skeleton_box;
        [GtkChild] private unowned Adw.StatusPage status_page;

        private const string DEFAULT_VIEW_MODE = "grid";

        public signal void collection_selected (string id, string kind, string title, string subtitle, string? cover);
        public signal void artist_selected (string id, string name);

        private unowned Timbre.Player? player;
        private bool loading = false;
        private bool loaded = false;
        private int pending_requests = 0;
        private bool load_had_data = false;
        private bool load_had_error = false;
        private string view_mode = DEFAULT_VIEW_MODE;
        private bool built = false;
        private string current_query = "";

        private Section playlists_section;
        private Section albums_section;
        private Section artists_section;

        private Gtk.Button view_toggle;

        private Gtk.Box library_sub_view;

        public LibraryPage () {
            Object ();
        }

        public override void constructed () {
            base.constructed ();

            this.content_box.vexpand = false;
            this.content_box.valign = Gtk.Align.START;

            this.build_header_and_sections ();
            this.stack.visible_child_name = "placeholder";
            this.built = true;
        }

        private Section[] get_sections () {
            return { playlists_section, albums_section, artists_section };
        }

        private void build_header_and_sections () {
            this.view_toggle = new Gtk.Button.from_icon_name ("view-grid-symbolic") {
                tooltip_text = _("Switch to list view"), valign = Gtk.Align.CENTER
            };
            this.view_toggle.add_css_class ("flat");
            this.view_toggle.add_css_class ("circular");
            this.view_toggle.clicked.connect (this.on_view_toggle_clicked);

            this.library_sub_view = new Gtk.Box (Gtk.Orientation.VERTICAL, 24) {
                vexpand = false,
                valign = Gtk.Align.START
            };
            this.playlists_section = new Section (_("Playlists"), this.view_toggle);
            this.albums_section = new Section (_("Albums"), null);
            this.artists_section = new Section (_("Artists"), null);

            this.library_sub_view.append (this.playlists_section.root);
            this.library_sub_view.append (this.albums_section.root);
            this.library_sub_view.append (this.artists_section.root);

            foreach (var sec in get_sections ()) {
                sec.item_activated.connect (this.on_item_activated);
            }

            this.content_box.append (this.library_sub_view);
        }

        public void set_player (Timbre.Player player) {
            this.player = player;
            if (player.is_authenticated ()) {
                GLib.Idle.add (() => {
                    this.load_library_data (false);
                    return GLib.Source.REMOVE;
                });
            }
        }

        public void refresh () {
            this.load_library_data (true);
        }

        public void filter_content (string text) {
            this.current_query = text.strip ().down ();
            foreach (var sec in get_sections ()) {
                sec.apply_filter (this.current_query);
            }
        }

        public void load_library_data (bool force) {
            if (!this.built || this.player == null || this.loading || (this.loaded && !force)) return;

            this.loading = true;
            if (force) this.loaded = false;
            this.pending_requests = 3;
            this.load_had_data = false;
            this.load_had_error = false;

            this.show_skeleton ();

            foreach (var sec in get_sections ()) {
                sec.clear ();
            }

            this.player.get_library_playlists ((json, error) => {
                GLib.Idle.add (() => { this.on_request_done (json, error, this.playlists_section, "Playlist"); return GLib.Source.REMOVE; });
            });
            this.player.get_library_albums ((json, error) => {
                GLib.Idle.add (() => { this.on_request_done (json, error, this.albums_section, "Album"); return GLib.Source.REMOVE; });
            });
            this.player.get_library_subscriptions ((json, error) => {
                GLib.Idle.add (() => { this.on_request_done (json, error, this.artists_section, "Artist"); return GLib.Source.REMOVE; });
            });
        }

        private void on_request_done (char* json, char* error, Section section, string default_kind) {
            if (!this.built || section == null) {
                if (error != null) Timbre.string_free (error);
                if (json != null) Timbre.string_free (json);
                return;
            }

            if (error != null) {
                warning ("library %s: %s", default_kind, (string) error);
                Timbre.string_free (error);
                this.load_had_error = true;
            } else {
                var items = this.parse_library_items ((string) json, default_kind);
                Timbre.string_free (json);
                if (items.length > 0) {
                    this.load_had_data = true;
                    section.add_items (items);
                    if (this.current_query.length > 0) {
                        section.apply_filter (this.current_query);
                    }
                }
            }

            this.pending_requests--;
            if (this.pending_requests > 0) return;

            this.loading = false;
            this.loaded = true;
            this.update_visibility ();

            if (this.load_had_data) {
                this.stack.visible_child_name = "content";
            } else if (this.load_had_error) {
                this.show_status_error ();
            } else {
                this.stack.visible_child_name = "placeholder";
            }
        }

        private void update_visibility () {
            foreach (var sec in get_sections ()) {
                sec.root.visible = sec.count > 0;
            }
        }

        private void show_status_error () {
            this.status_page.icon_name = "dialog-warning-symbolic";
            this.status_page.title = _("Couldn't load Library");
            this.status_page.description = _("Check your connection and try again.");
            this.stack.visible_child_name = "status";
        }

        private void show_skeleton () {
            Gtk.Widget? c = this.skeleton_box.get_first_child ();
            while (c != null) {
                var next = c.get_next_sibling ();
                this.skeleton_box.remove (c);
                c = next;
            }

            for (int s = 0; s < 3; s++) {
                var sec = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
                var title = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) {
                    height_request = 20, width_request = 160, halign = Gtk.Align.START
                };
                title.add_css_class ("skeleton");
                title.add_css_class ("skeleton-title");
                sec.append (title);

                var strip = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
                    homogeneous = true, hexpand = true
                };
                for (int i = 0; i < 4; i++) {
                    var card = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) {
                        height_request = 150, hexpand = true
                    };
                    card.add_css_class ("skeleton");
                    strip.append (card);
                }
                sec.append (strip);
                this.skeleton_box.append (sec);
            }

            this.stack.visible_child_name = "loading";
        }

        private GenericArray<LibraryItem> parse_library_items (string json_str, string default_kind) {
            var items = new GenericArray<LibraryItem> ();
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (json_str);
            } catch (Error e) {
                warning ("library parse: %s", e.message);
                return items;
            }

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return items;

            foreach (unowned Json.Node node in root.get_array ().get_elements ()) {
                if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                var o = node.get_object ();

                var item = new LibraryItem ();
                item.kind = this.json_str (o, "kind");
                if (item.kind.length == 0) item.kind = default_kind;
                item.id = this.json_str (o, "id");
                if (item.id.length == 0) continue;
                item.title = this.json_str (o, "title");

                if (o.has_member ("thumb") && !o.get_null_member ("thumb"))
                    item.thumb = o.get_string_member ("thumb");
                if (o.has_member ("duration_seconds") && !o.get_null_member ("duration_seconds"))
                    item.duration = (uint64) o.get_int_member ("duration_seconds");
                if (o.has_member ("is_live") && !o.get_null_member ("is_live"))
                    item.is_live = o.get_boolean_member ("is_live");
                if (o.has_member ("explicit") && !o.get_null_member ("explicit"))
                    item.explicit = o.get_boolean_member ("explicit");

                if (item.kind == "Playlist") {
                    string count = this.json_str (o, "count");
                    if (count.length > 0) {
                        item.subtitle = _("%s songs").printf (count);
                    } else {
                        string desc = this.json_str (o, "description");
                        item.subtitle = desc.length > 0 ? desc : _("Playlist");
                    }
                } else if (item.kind == "Album") {
                    var parts = new GenericArray<string> ();
                    var artists_text = this.join_artists (o);
                    if (artists_text.length > 0) parts.add (artists_text);
                    string item_type = this.json_str (o, "item_type");
                    parts.add (item_type.length > 0 ? item_type : _("Album"));
                    string year = this.json_str (o, "year");
                    if (year.length > 0) parts.add (year);
                    var sb = new StringBuilder ();
                    for (int i = 0; i < parts.length; i++) {
                        if (sb.len > 0) sb.append (" • ");
                        sb.append (parts.get (i));
                    }
                    item.subtitle = sb.str;
                } else if (item.kind == "Artist") {
                    item.subtitle = this.json_str (o, "subscribers");
                } else {
                    item.subtitle = this.join_artists (o);
                }
                items.add (item);
            }
            return items;
        }

        private string join_artists (Json.Object obj) {
            if (!obj.has_member ("artists") || obj.get_null_member ("artists")) return "";
            var node = obj.get_member ("artists");
            if (node.get_node_type () != Json.NodeType.ARRAY) return "";
            var sb = new StringBuilder ();
            foreach (unowned Json.Node n in node.get_array ().get_elements ()) {
                if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                var a = n.get_object ();
                if (!a.has_member ("name") || a.get_null_member ("name")) continue;
                if (sb.len > 0) sb.append (", ");
                sb.append (a.get_string_member ("name"));
            }
            return sb.str;
        }

        private string json_str (Json.Object obj, string key) {
            if (!obj.has_member (key) || obj.get_null_member (key)) return "";
            var n = obj.get_member (key);
            return (n.get_node_type () == Json.NodeType.VALUE) ? n.get_string () : "";
        }

        private void on_item_activated (LibraryItem item) {
            string kind_lower = item.kind.down ();
            if (kind_lower == "artist") {
                this.artist_selected (item.id, item.title);
            } else {
                this.collection_selected (item.id, kind_lower, item.title, item.subtitle, item.thumb);
            }
        }

        private void on_view_toggle_clicked () {
            this.view_mode = (this.view_mode == "grid") ? "list" : "grid";

            if (this.view_mode == "grid") {
                this.view_toggle.icon_name = "view-grid-symbolic";
                this.view_toggle.tooltip_text = _("Switch to list view");
            } else {
                this.view_toggle.icon_name = "view-list-symbolic";
                this.view_toggle.tooltip_text = _("Switch to grid view");
            }

            foreach (var sec in get_sections ()) {
                sec.set_view_mode (this.view_mode);
            }
        }

        private class Section : Object {
            public Gtk.Box root;
            public int count = 0;
            public signal void item_activated (LibraryItem item);

            private Gtk.ListBox list_box;
            private Adw.WrapBox grid_box;
            private Gtk.Stack view_stack;
            private string view_mode = "grid";
            private GenericArray<LibraryItem> all_items;

            private GLib.HashTable<LibraryItem, Gtk.ListBoxRow> row_map;
            private GLib.HashTable<LibraryItem, Timbre.TrackCard> card_map;

            public Section (string title, Gtk.Widget? action_widget) {
                this.all_items = new GenericArray<LibraryItem> ();
                this.row_map = new GLib.HashTable<LibraryItem, Gtk.ListBoxRow> (null, null);
                this.card_map = new GLib.HashTable<LibraryItem, Timbre.TrackCard> (null, null);

                this.root = new Gtk.Box (Gtk.Orientation.VERTICAL, 8) {
                    vexpand = false,
                    valign = Gtk.Align.START
                };
                this.root.visible = false;

                var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) { height_request = 34 };
                var title_label = new Gtk.Label (title) {
                    halign = Gtk.Align.START, valign = Gtk.Align.CENTER, hexpand = true
                };
                title_label.add_css_class ("heading");
                header.append (title_label);
                if (action_widget != null) header.append (action_widget);
                this.root.append (header);

                this.view_stack = new Gtk.Stack () {
                    transition_type = Gtk.StackTransitionType.CROSSFADE,
                    vhomogeneous = false,
                    vexpand = false,
                    valign = Gtk.Align.START
                };

                this.list_box = new Gtk.ListBox () {
                    selection_mode = Gtk.SelectionMode.NONE,
                    vexpand = false,
                    valign = Gtk.Align.START
                };
                this.list_box.add_css_class ("boxed-list");
                this.list_box.add_css_class ("songs-list");
                this.list_box.row_activated.connect (this.on_row_activated);
                this.view_stack.add_named (this.list_box, "list");

                this.grid_box = new Adw.WrapBox () {
                    orientation = Gtk.Orientation.HORIZONTAL,
                    child_spacing = 12,
                    line_spacing = 12,
                    margin_top = 4,
                    margin_bottom = 4,
                    vexpand = false,
                    valign = Gtk.Align.START
                };
                this.view_stack.add_named (this.grid_box, "grid");

                this.view_stack.visible_child_name = this.view_mode;
                this.root.append (this.view_stack);
            }

            private void on_row_activated (Gtk.ListBoxRow row) {
                int idx = row.get_index ();
                if (idx >= 0 && idx < this.all_items.length) {
                    this.item_activated (this.all_items.get (idx));
                }
            }

            public void add_items (GenericArray<LibraryItem> new_items) {
                this.clear_ui ();
                this.all_items = new_items;

                foreach (var item in this.all_items) {
                    var row = new Timbre.TrackRow.simple (
                        item.kind, item.id, item.title, item.subtitle,
                        item.duration, item.thumb, item.is_live, item.explicit);
                    row.valign = Gtk.Align.START;
                    row.vexpand = false;
                    this.list_box.append (row);
                    this.row_map.insert (item, row);

                    var card = new Timbre.TrackCard (
                        item.id, item.kind, item.title,
                        item.subtitle, item.thumb,
                        item.is_live, item.explicit
                    );
                    card.width_request = 160;
                    card.valign = Gtk.Align.START;
                    card.vexpand = false;
                    card.clicked.connect (() => this.item_activated (item));
                    this.grid_box.append (card);
                    this.card_map.insert (item, card);
                }
                this.apply_filter ("");
            }

            public void apply_filter (string query) {
                this.count = 0;
                foreach (var item in this.all_items) {
                    bool match = query.length == 0 || item.title.down ().contains (query) || item.subtitle.down ().contains (query);

                    var row = this.row_map.lookup (item);
                    if (row != null) row.visible = match;

                    var card = this.card_map.lookup (item);
                    if (card != null) card.visible = match;

                    if (match) this.count++;
                }
                this.root.visible = this.count > 0;
                this.view_stack.visible_child_name = this.view_mode;
            }

            private void clear_ui () {
                this.count = 0;
                this.root.visible = false;
                this.row_map.remove_all ();
                this.card_map.remove_all ();

                Gtk.Widget? c = this.list_box.get_first_child ();
                while (c != null) {
                    var next = c.get_next_sibling ();
                    this.list_box.remove (c);
                    c = next;
                }
                c = this.grid_box.get_first_child ();
                while (c != null) {
                    var next = c.get_next_sibling ();
                    this.grid_box.remove (c);
                    c = next;
                }
            }

            public void clear () {
                this.all_items = new GenericArray<LibraryItem> ();
                this.clear_ui ();
            }

            public void set_view_mode (string mode) {
                this.view_mode = mode;
                this.view_stack.visible_child_name = mode;
            }
        }
    }
}
