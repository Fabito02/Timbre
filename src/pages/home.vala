namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/pages/home.ui")]
    public class HomePage : Adw.NavigationPage {
        [GtkChild] private unowned Gtk.Box content_box;

        private unowned Timbre.Player? player;
        private GenericArray<HomeSectionModel> sections;

        public signal void track_selected (string id, uint64 duration, string title, string artist, string? cover);
        public signal void collection_selected (string id, string type_name, string title, string subtitle, string? cover);

        public HomePage () {
            Object ();
            this.sections = new GenericArray<HomeSectionModel> ();
        }

        public void set_player (Timbre.Player player) {
            this.player = player;
            this.load_home_data ();
        }

        private void load_home_data () {
            if (this.player == null) return;

            this.player.get_home ((json, error) => {
                Idle.add (() => {
                    if (error != null) {
                        warning ("home: %s", (string) error);
                        Timbre.string_free (error);
                        return GLib.Source.REMOVE;
                    }
                    this.set_results (this.parse_sections ((string) json));
                    Timbre.string_free (json);
                    return GLib.Source.REMOVE;
                });
            });
        }

        private GenericArray<HomeSectionModel> parse_sections (string json_data) {
            var list = new GenericArray<HomeSectionModel> ();

            var parser = new Json.Parser ();
            try {
                parser.load_from_data (json_data);
            } catch (Error e) {
                warning ("home json: %s", e.message);
                return list;
            }

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.ARRAY) {
                return list;
            }

            foreach (unowned Json.Node sec_node in root.get_array ().get_elements ()) {
                if (sec_node.get_node_type () != Json.NodeType.OBJECT) continue;
                var sec_obj = sec_node.get_object ();

                string sec_title = sec_obj.has_member ("title") && !sec_obj.get_null_member ("title")
                    ? sec_obj.get_string_member ("title")
                    : "";
                var section = new HomeSectionModel (sec_title);

                if (!sec_obj.has_member ("items")) {
                    list.add (section);
                    continue;
                }

                foreach (unowned Json.Node item_node in sec_obj.get_array_member ("items").get_elements ()) {
                    if (item_node.get_node_type () != Json.NodeType.OBJECT) continue;
                    var obj = item_node.get_object ();
                    var item = new HomeItemModel ();

                    if (obj.has_member ("kind")) {
                        item.type_name = obj.get_string_member ("kind");
                    }
                    if (obj.has_member ("id") && !obj.get_null_member ("id")) {
                        item.id = obj.get_string_member ("id");
                    }
                    if (obj.has_member ("title") && !obj.get_null_member ("title")) {
                        item.title = obj.get_string_member ("title");
                    }
                    if (obj.has_member ("duration_seconds") && !obj.get_null_member ("duration_seconds")) {
                        item.duration_secs = (uint64) obj.get_int_member ("duration_seconds");
                    }

                    if (obj.has_member ("artists") && !obj.get_null_member ("artists")) {
                        var artists_node = obj.get_member ("artists");
                        if (artists_node.get_node_type () == Json.NodeType.ARRAY) {
                            var sb = new StringBuilder ();
                            foreach (unowned Json.Node a_node in artists_node.get_array ().get_elements ()) {
                                if (a_node.get_node_type () == Json.NodeType.OBJECT) {
                                    var ao = a_node.get_object ();
                                    if (ao.has_member ("name")) {
                                        if (sb.len > 0) sb.append (", ");
                                        sb.append (ao.get_string_member ("name"));
                                    }
                                }
                            }
                            if (sb.len > 0) {
                                item.subtitle = sb.str;
                            }
                        }
                    } else if (obj.has_member ("description") && !obj.get_null_member ("description")) {
                        item.subtitle = obj.get_string_member ("description");
                    }

                    if (obj.has_member ("thumb") && !obj.get_null_member ("thumb")) {
                        item.thumbnail_url = obj.get_string_member ("thumb");
                    }

                    section.items.add (item);
                }

                list.add (section);
            }

            return list;
        }

        private void set_results (GenericArray<HomeSectionModel> sections) {
            this.clear_list ();

            for (int i = 0; i < sections.length; i++) {
                var section = sections.get (i);

                var section_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
                    margin_top = 12,
                    margin_bottom = 12,
                    margin_start = 18,
                    margin_end = 18
                };

                var title_label = new Gtk.Label (section.title) {
                    halign = Gtk.Align.START,
                    xalign = 0
                };
                title_label.add_css_class ("title-2");
                section_box.append (title_label);

                var cards_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);

                for (int j = 0; j < section.items.length; j++) {
                    HomeItemModel item = section.items.get (j);

                    var card = new Timbre.TrackCard (
                        item.id, item.type_name, item.title, item.subtitle ?? "", item.thumbnail_url);

                    string item_id = item.id;
                    uint64 item_duration = item.duration_secs;
                    string item_type = item.type_name;
                    string item_title = item.title;
                    string item_sub = item.subtitle ?? "";
                    string? item_thumb = item.thumbnail_url;

                    card.clicked.connect (() => {
                        if (item_type == "Song" || item_type == "Video") {
                            this.track_selected (item_id, item_duration, item_title, item_sub, item_thumb);
                        } else {
                            this.collection_selected (item_id, item_type, item_title, item_sub, item_thumb);
                        }
                    });

                    cards_box.append (card);
                }

                var scroll = new Gtk.ScrolledWindow () {
                    hscrollbar_policy = Gtk.PolicyType.AUTOMATIC,
                    vscrollbar_policy = Gtk.PolicyType.NEVER,
                    hexpand = true,
                    overlay_scrolling = true,
                    child = cards_box,
                    margin_bottom = 24
                };

                section_box.append (scroll);
                this.content_box.append (section_box);
            }
        }

        private void clear_list () {
            Gtk.Widget? child = this.content_box.get_first_child ();
            while (child != null) {
                var next = child.get_next_sibling ();
                this.content_box.remove (child);
                child = next;
            }
        }
    }
}
