namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/pages/home.ui")]
    public class HomePage : Adw.NavigationPage {
        [CCode (cname = "g_object_run_dispose", cheader_filename = "glib-object.h")]

        [GtkChild] private unowned Gtk.Stack stack;
        [GtkChild] private unowned Gtk.Box content_box;
        [GtkChild] private unowned Gtk.Box skeleton_box;
        [GtkChild] private unowned Adw.StatusPage status_page;
        [GtkChild] private unowned Gtk.ScrolledWindow feed_scroll;

        private unowned Timbre.Player? player;
        private bool loaded = false;
        private bool loading = false;
        private bool released = false;
        private int retry_count = 0;
        private int64 last_refresh_usec = 0;

        private int populate_gen = 0;
        private int populate_idx = 0;
        private HomeSectionModel[] populate_queue = new HomeSectionModel[0];

        public signal void track_selected (MediaItem item);
        public signal void collection_selected (MediaItem item);
        public signal void show_all_requested (string browse_id, string? params_json, string title, GenericArray<HomeItemModel> seed);

        public HomePage () {
            Object ();
            this.show_skeleton ();

            this.feed_scroll.edge_overshot.connect ((pos) => {
                if (this.released)return;
                if (pos != Gtk.PositionType.TOP)return;
                if (this.loading)return;
                int64 now = GLib.get_monotonic_time ();
                if (now - this.last_refresh_usec < 2000000)return;
                this.last_refresh_usec = now;
                this.load_home_data (true);
            });
        }

        protected override void unroot () {
            this.released = true;
            this.populate_gen++;
            this.loading = false;
            this.populate_queue = new HomeSectionModel[0];
            this.clear_list ();
            this.player = null;
            base.unroot ();
        }

        public void set_player (Timbre.Player player) {
            this.player = player;
            this.load_home_data (false);
        }

        public void refresh () {
            this.load_home_data (true);
        }

        public void load_home_data (bool force) {
            if (this.released)return;
            if (this.player == null)return;
            if (this.loading)return;
            if (this.loaded && !force)return;

            this.loading = true;
            if (force)this.loaded = false;

            this.show_skeleton ();

            this.player.get_home ((json, error) => {
                Idle.add (() => {
                    this.loading = false;

                    if (this.released) {
                        if (error != null)Timbre.string_free (error);
                        if (json != null)Timbre.string_free (json);
                        return GLib.Source.REMOVE;
                    }

                    if (error != null) {
                        warning ("home: %s", (string) error);
                        Timbre.string_free (error);
                        this.on_load_failed ();
                        return GLib.Source.REMOVE;
                    }

                    string json_str = (string) json;
                    message (json_str);
                    var sections = HomeParser.parse_sections (json_str);
                    Timbre.string_free (json);

                    if (sections.length == 0) {
                        this.show_empty ();
                        return GLib.Source.REMOVE;
                    }

                    this.loaded = true;
                    this.retry_count = 0;
                    this.populate_async (sections);
                    this.stack.visible_child_name = "feed";
                    return GLib.Source.REMOVE;
                });
            });
        }

        private void on_load_failed () {
            if (this.released)return;
            this.retry_count++;
            if (this.retry_count < 3) {
                uint delay = (uint) (1500 * this.retry_count);
                GLib.Timeout.add (delay, () => {
                    if (this.released)return GLib.Source.REMOVE;
                    this.load_home_data (true);
                    return GLib.Source.REMOVE;
                });
                return;
            }
            this.show_offline ();
        }

        private void show_offline () {
            this.show_status ("network-offline-symbolic",
                              _("You're offline"),
                              _("Home requires an internet connection.\nYour downloaded songs are still available."),
                              true);
        }

        private void show_empty () {
            this.show_status ("folder-symbolic",
                              _("Nothing new here"),
                              _("There's nothing to show right now. Check back later."),
                              true);
        }

        private void show_status (string icon, string title, string description, bool with_retry) {
            if (this.released)return;
            this.status_page.icon_name = icon;
            this.status_page.title = title;
            this.status_page.description = description;

            if (with_retry) {
                var retry = new Gtk.Button.with_label (_("Retry")) {
                    halign = Gtk.Align.CENTER
                };
                retry.add_css_class ("pill");
                retry.add_css_class ("suggested-action");
                retry.clicked.connect (() => {
                    if (this.released)return;
                    this.retry_count = 0;
                    this.load_home_data (true);
                });
                this.status_page.child = retry;
            } else {
                this.status_page.child = null;
            }

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
                    height_request = 20,
                    width_request = 160,
                    halign = Gtk.Align.START
                };
                title.add_css_class ("skeleton");
                title.add_css_class ("skeleton-title");
                sec.append (title);

                var strip = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
                    homogeneous = true,
                    hexpand = true
                };
                for (int i = 0; i < 4; i++) {
                    var card = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) {
                        height_request = 150,
                        hexpand = true
                    };
                    card.add_css_class ("skeleton");
                    strip.append (card);
                }
                sec.append (strip);
                this.skeleton_box.append (sec);
            }
        }

        private void populate_async (GenericArray<HomeSectionModel> sections) {
            if (this.released)return;

            this.populate_gen++;
            int gen = this.populate_gen;

            this.clear_list ();

            int n = sections.length;
            this.populate_queue = new HomeSectionModel[n];
            for (int i = 0; i < n; i++) {
                this.populate_queue[i] = sections.get (i);
            }
            this.populate_idx = 0;

            GLib.Idle.add_full (GLib.Priority.LOW, () => {
                if (this.released)return GLib.Source.REMOVE;
                if (this.populate_gen != gen)return GLib.Source.REMOVE;
                if (this.populate_idx >= this.populate_queue.length) {
                    return GLib.Source.REMOVE;
                }

                var sec = this.populate_queue[this.populate_idx];
                this.populate_idx++;

                if (sec.kind == "hero_dial") {
                    HomeSection.add_speed_dial (this, this.content_box, sec, 3);
                } else if (sec.kind == "hero_dial_cards") {
                    HomeSection.add_speed_dial_card (this, this.content_box, sec, 2);
                } else {
                    HomeSection.add_section (this, this.content_box, sec);
                }

                return GLib.Source.CONTINUE;
            });
        }

        private void clear_list () {
            var cards = new GenericArray<unowned Timbre.TrackCard> ();
            var tiles = new GenericArray<unowned Timbre.HomeSpeedTile> ();

            this.collect_releasables (this.content_box, cards, tiles);

            foreach (unowned var c in cards)c.release ();
            foreach (unowned var t in tiles)t.release ();

            Gtk.Widget? child = this.content_box.get_first_child ();
            while (child != null) {
                var next = child.get_next_sibling ();
                this.content_box.remove (child);
                child = next;
            }
        }

        private void collect_releasables (Gtk.Widget widget,
                                          GenericArray<unowned Timbre.TrackCard> cards,
                                          GenericArray<unowned Timbre.HomeSpeedTile> tiles) {
            if (widget is Timbre.TrackCard) {
                cards.add ((Timbre.TrackCard) widget);
                return;
            }
            if (widget is Timbre.HomeSpeedTile) {
                tiles.add ((Timbre.HomeSpeedTile) widget);
                return;
            }
            Gtk.Widget? child = widget.get_first_child ();
            while (child != null) {
                this.collect_releasables (child, cards, tiles);
                child = child.get_next_sibling ();
            }
        }
    }
}
