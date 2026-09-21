namespace Timbre {

    [GtkTemplate (ui = "/io/github/fabito02/Timbre/pages/home.ui")]
    public class HomePage : Adw.NavigationPage {

        [GtkChild]
        private unowned Gtk.Box content_box;

        private unowned Timbre.Player? player;
        private GenericArray<HomeSectionModel> sections;

        public signal void track_selected (
            string id,
            uint64 duration,
            string title,
            string artist,
            string? cover
        );

        public signal void collection_selected (
            string id,
            string type_name,
            string title,
            string subtitle,
            string? cover
        );

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

            new Thread<void*> ("home-worker", () => {
                char* raw_ptr = this.player.get_home_json ();

                if (raw_ptr == null) {
                    return null;
                }

                string json_data = (string) raw_ptr;

                Timbre.string_free (raw_ptr);

                var parsed_sections = this.parse_sections (json_data);

                GLib.Idle.add (() => {
                    this.set_results (parsed_sections);
                    return GLib.Source.REMOVE;
                });

                return null;
            });
        }

        private GenericArray<HomeSectionModel> parse_sections (string json_data) {
            var list = new GenericArray<HomeSectionModel> ();

            var parser = new Json.Parser ();
            parser.load_from_data (json_data);

            var root_array = parser.get_root ().get_array ();

            foreach (unowned Json.Node sec_node in root_array.get_elements ()) {
                var sec_obj = sec_node.get_object ();

                var section = new HomeSectionModel (
                    sec_obj.get_string_member ("title")
                );

                var items_array = sec_obj.get_array_member ("items");

                foreach (unowned Json.Node item_node in items_array.get_elements ()) {
                    var obj = item_node.get_object ();
                    var item = new HomeItemModel ();

                    item.type_name = obj.get_string_member ("type");

                    if (obj.has_member ("browse_id")) {
                        item.id = obj.get_string_member ("browse_id");
                    } else if (obj.has_member ("video_id") && !obj.get_null_member ("video_id")) {
                        item.id = obj.get_string_member ("video_id");
                    } else if (obj.has_member ("id")) {
                        item.id = obj.get_string_member ("id");
                    }

                    item.title = obj.get_string_member ("title");

                    if (obj.has_member ("duration_secs") && !obj.get_null_member ("duration_secs")) {
                        item.duration_secs = (uint64) obj.get_int_member ("duration_secs");
                    } else if (obj.has_member ("duration") && !obj.get_null_member ("duration")) {
                        var dur_node = obj.get_member ("duration");
                        if (dur_node.get_node_type () == Json.NodeType.VALUE) {
                            item.duration_secs = (uint64) obj.get_int_member ("duration");
                        }
                    }

                    if (obj.has_member ("author") && !obj.get_null_member ("author")) {
                        item.subtitle = obj.get_string_member ("author");
                    } else if (obj.has_member ("artists") && !obj.get_null_member ("artists")) {
                        var artists_node = obj.get_member ("artists");
                        if (artists_node.get_node_type () == Json.NodeType.ARRAY) {
                            var art_arr = artists_node.get_array ();
                            var art_names = new GenericArray<string> ();

                            foreach (unowned Json.Node a_node in art_arr.get_elements ()) {
                                if (a_node.get_node_type () == Json.NodeType.OBJECT) {
                                    var a_obj = a_node.get_object ();
                                    if (a_obj.has_member ("name")) {
                                        art_names.add (a_obj.get_string_member ("name"));
                                    }
                                }
                            }
                            item.subtitle = string.joinv (", ", art_names.data);
                        } else if (artists_node.get_node_type () == Json.NodeType.VALUE) {
                            item.subtitle = obj.get_string_member ("artists");
                        }
                    }

                    if (obj.has_member ("thumbnails") && !obj.get_null_member ("thumbnails")) {
                        var thumbs_arr = obj.get_array_member ("thumbnails");
                        if (thumbs_arr.get_length () > 0) {
                            var last_thumb = thumbs_arr.get_element (thumbs_arr.get_length () - 1).get_object ();
                            if (last_thumb.has_member ("url")) {
                                item.thumbnail_url = last_thumb.get_string_member ("url");
                            }
                        }
                    } else if (obj.has_member ("thumbnail_url") && !obj.get_null_member ("thumbnail_url")) {
                        item.thumbnail_url = obj.get_string_member ("thumbnail_url");
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
                        item.id,
                        item.type_name,
                        item.title,
                        item.subtitle ?? "",
                        item.thumbnail_url
                    );

                    // Captura as variáveis no escopo local pro closure não pegar lixo
                    string item_id = item.id;
                    uint64 item_duration = item.duration_secs; // <--- AQUI! Captura a duração
                    string item_type = item.type_name;
                    string item_title = item.title;
                    string item_sub = item.subtitle ?? "";
                    string? item_thumb = item.thumbnail_url;

                    card.clicked.connect (() => {
                        if (item_type == "Track") {
                            this.track_selected (
                                item_id,
                                item_duration, // <--- AGORA PASSA A DURAÇÃO CORRETA
                                item_title,
                                item_sub,
                                item_thumb
                            );
                        } else {
                            this.collection_selected (
                                item_id,
                                item_type,
                                item_title,
                                item_sub,
                                item_thumb
                            );
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
