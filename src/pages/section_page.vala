namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/pages/section_page.ui")]
    public class SectionPage : Adw.NavigationPage {
        [GtkChild] private unowned Gtk.Stack stack;
        [GtkChild] private unowned Adw.WrapBox wrap;
        [GtkChild] private unowned Gtk.ScrolledWindow scroller;
        [GtkChild] private unowned Adw.StatusPage empty_page;

        private const int LOAD_THRESHOLD_PX = 300;

        private unowned Timbre.Player player;
        private string browse_id;
        private string? params_json;
        private string? next_token = null;
        private bool loading = false;

        private GLib.HashTable<string, bool> seen_ids;

        public signal void track_selected (MediaItem item);
        public signal void collection_selected (MediaItem item);

        public SectionPage (Timbre.Player player,
                            string browse_id,
                            string? params_json,
                            string title,
                            GenericArray<HomeItemModel> seed) {
            Object (title: title);

            this.player = player;
            this.browse_id = browse_id;
            this.params_json = params_json;
            this.seen_ids = new GLib.HashTable<string, bool> (str_hash, str_equal);

            if (seed != null && seed.length > 0) {
                this.render_items (seed);
                this.stack.visible_child_name = "content";
            } else {
                this.stack.visible_child_name = "loading";
            }

            this.scroller.vadjustment.value_changed.connect (() => {
                if (this.loading) return;
                if (this.next_token == null) return;
                var adj = this.scroller.vadjustment;
                double remaining = adj.upper - (adj.value + adj.page_size);
                if (remaining < LOAD_THRESHOLD_PX) {
                    this.load_next ();
                }
            });

            GLib.Idle.add (() => {
                this.load_next ();
                return GLib.Source.REMOVE;
            });
        }

        private void load_next () {
            if (this.loading) return;

            this.loading = true;

            var args = new Json.Builder ();
            args.begin_object ();
            if (this.next_token != null) {
                args.set_member_name ("continuation");
                args.add_string_value (this.next_token);
            } else {
                args.set_member_name ("browse_id");
                args.add_string_value (this.browse_id);
                if (this.params_json != null && this.params_json.length > 0) {
                    args.set_member_name ("params");
                    args.add_string_value (this.params_json);
                }
            }
            args.end_object ();
            var gen = new Json.Generator ();
            gen.set_root (args.get_root ());
            string args_json = gen.to_data (null);

            this.player.browse_section (args_json, (json, error) => {
                Idle.add (() => {
                    this.loading = false;

                    if (error != null) {
                        warning ("section: %s", (string) error);
                        Timbre.string_free (error);
                        this.next_token = null;
                        if (this.seen_ids.size () == 0) {
                            this.stack.visible_child_name = "empty";
                        }
                        return GLib.Source.REMOVE;
                    }

                    string payload = (string) json;
                    Timbre.string_free (json);

                    this.consume_page (payload);
                    return GLib.Source.REMOVE;
                });
            });
        }

        private void consume_page (string payload) {
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (payload);
            } catch (Error e) {
                warning ("section json: %s", e.message);
                this.next_token = null;
                return;
            }

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                this.next_token = null;
                return;
            }

            var obj = root.get_object ();

            this.next_token = null;
            if (obj.has_member ("continuation") && !obj.get_null_member ("continuation")) {
                this.next_token = obj.get_string_member ("continuation");
            }

            var items = new GenericArray<HomeItemModel> ();
            if (obj.has_member ("items") && !obj.get_null_member ("items")) {
                var arr = obj.get_array_member ("items");
                foreach (unowned Json.Node node in arr.get_elements ()) {
                    if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                    var item = SectionParser.parse_item (node.get_object ());
                    if (item != null) items.add (item);
                }
            }

            bool added = this.render_items (items);

            if (this.seen_ids.size () == 0) {
                this.stack.visible_child_name = "empty";
            } else if (added || this.stack.visible_child_name != "content") {
                this.stack.visible_child_name = "content";
            }
        }

        private bool render_items (GenericArray<HomeItemModel> items) {
            bool any_added = false;

            for (int i = 0; i < items.length; i++) {
                var item = items.get (i);
                if (item.id == null || item.id.length == 0) continue;
                if (this.seen_ids.contains (item.id)) continue;
                this.seen_ids.insert (item.id, true);

                var card = new Timbre.TrackCard (item, false);

                card.clicked.connect (() => {
                    if (item.kind.is_playable ())
                        this.track_selected (item);
                    else
                        this.collection_selected (item);
                });

                this.wrap.append (card);
                any_added = true;
            }

            return any_added;
        }
    }
}
