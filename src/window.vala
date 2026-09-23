namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/window.ui")]
    public class Window : Adw.ApplicationWindow {
        private unowned Timbre.Player player;
        private Timbre.QueueManager queue;
        private bool is_playing = false;
        private bool is_seeking = false;
        private uint tick_id = 0;
        private uint seek_debounce_id = 0;
        private uint search_debounce_id = 0;
        private string cookies_path;

        [GtkChild] private unowned Gtk.Scale scale_progress;
        [GtkChild] private unowned Gtk.Adjustment adjustment_progress;
        [GtkChild] private unowned Gtk.Label label_time_current;
        [GtkChild] private unowned Gtk.Label label_time_total;
        [GtkChild] private unowned Gtk.Button button_play_pause;
        [GtkChild] private unowned Gtk.Button button_prev;
        [GtkChild] private unowned Gtk.Button button_next;

        [GtkChild] private unowned Adw.OverlaySplitView split_view;
        [GtkChild] private unowned Gtk.ToggleButton button_toggle_queue;
        [GtkChild] private unowned Gtk.ListView queue_list;
        [GtkChild] private unowned Gtk.Label label_queue_count;
        [GtkChild] private unowned Gtk.Button button_clear_queue;

        [GtkChild] private unowned Gtk.Label label_current_title;
        [GtkChild] private unowned Gtk.Label label_current_artist;
        [GtkChild] private unowned Gtk.Picture image_cover;

        [GtkChild] private unowned Gtk.SearchBar searchbar;
        [GtkChild] private unowned Gtk.Button button_back;
        [GtkChild] private unowned Gtk.SearchEntry searchentry;
        [GtkChild] private unowned Adw.ViewStack main_stack;
        [GtkChild] private unowned Adw.NavigationView navigation_view;

        [GtkChild] private unowned Timbre.SearchPage search_page;
        [GtkChild] private unowned Timbre.HomePage home_page;

        private Gtk.SingleSelection queue_selection;

        public Window (Timbre.Application app) {
            Object (application: app);

            this.player = app.get_player ();
            this.cookies_path = app.cookies_path;
            this.queue = new Timbre.QueueManager ();

            this.search_page.set_player (this.player);
            this.home_page.set_player (this.player);
            this.main_stack.visible_child_name = "home";

            this.searchbar.key_capture_widget = this;

            this.setup_navigation ();
            this.setup_queue_view ();
            this.setup_search ();
            this.update_nav_buttons ();
        }

        private void setup_navigation () {
            this.button_back.clicked.connect (() => {
                this.navigation_view.pop ();
            });

            this.navigation_view.pushed.connect (() => {
                this.button_back.visible = true;
            });

            this.navigation_view.popped.connect (() => {
                var stack = this.navigation_view.navigation_stack;
                this.button_back.visible = (stack.get_n_items () > 1);
            });

            this.button_toggle_queue.toggled.connect (() => {
                this.split_view.show_sidebar = this.button_toggle_queue.active;
            });

            this.split_view.notify["show-sidebar"].connect (() => {
                this.button_toggle_queue.active = this.split_view.show_sidebar;
            });

            this.home_page.collection_selected.connect ((id, type_name, title, subtitle, cover) => {
                var page = new Timbre.CollectionPage (this.player, id, type_name, title, subtitle, cover);
                page.play_collection.connect ((tracks, start_index) => {
                    this.queue.play_list (tracks, start_index);
                });
                this.navigation_view.push (page);
            });
            this.home_page.track_selected.connect ((id, duration, title, artist, cover) => {
                this.queue.play_single (new Timbre.TrackItem.with_data (id, title, artist, duration, cover));
            });
        }

        private void setup_queue_view () {
            this.queue_selection = new Gtk.SingleSelection (this.queue.store);
            this.queue_selection.autoselect = false;
            this.queue_list.model = this.queue_selection;

            this.queue_list.single_click_activate = true;

            this.queue_list.activate.connect ((position) => {
                this.queue.play_index ((int) position);
            });

            var factory = new Gtk.SignalListItemFactory ();

            factory.setup.connect ((item) => {
                var row = new Timbre.QueueRow ();
                row.item_moved.connect ((from_idx, to_idx) => {
                    this.queue.move_item (from_idx, to_idx);
                });
                ((Gtk.ListItem) item).set_child (row);
            });

            factory.bind.connect ((item) => {
                var list_item = (Gtk.ListItem) item;
                var row = (Timbre.QueueRow) list_item.get_child ();
                var queue_item = (Timbre.QueueItem) list_item.get_item ();
                row.bind (queue_item);
            });

            factory.unbind.connect ((item) => {
                var list_item = (Gtk.ListItem) item;
                var row = (Timbre.QueueRow) list_item.get_child ();
                if (row != null) {
                    row.unbind ();
                }
            });

            this.queue_list.factory = factory;

            this.queue.track_changed.connect ((track) => {
                this.play_track (track.id, track.duration_secs, track.title, track.artist, track.thumbnail_url);
                this.update_nav_buttons ();
            });

            this.queue.queue_updated.connect (() => {
                this.update_nav_buttons ();
                int total = this.queue.length;
                this.label_queue_count.label = (total == 1) ? "1 faixa" : "%d faixas".printf (total);
            });

            if (this.button_clear_queue != null) {
                this.button_clear_queue.clicked.connect (() => {
                    this.queue.clear ();
                    this.player.stop ();
                    this.is_playing = false;
                    this.button_play_pause.icon_name = "media-playback-start-symbolic";
                    this.label_current_title.label = "No track selected";
                    this.label_current_artist.label = "Artist";
                    this.label_time_current.label = "0:00";
                    this.label_time_total.label = "0:00";
                    this.adjustment_progress.value = 0.0;
                });
            }
        }

        private void setup_search () {
            this.search_page.track_selected.connect ((id, duration, title, artist, cover) => {
                this.queue.play_single (new Timbre.TrackItem.with_data (id, title, artist, duration, cover));
            });

            this.search_page.collection_selected.connect ((id, type_name, title, subtitle, cover) => {
                var page = new Timbre.CollectionPage (this.player, id, type_name, title, subtitle, cover);
                page.play_collection.connect ((tracks, start_index) => {
                    this.queue.play_list (tracks, start_index);
                });

                this.navigation_view.push (page);

                this.searchbar.search_mode_enabled = false;
            });

            this.searchbar.notify["search-mode-enabled"].connect (() => {
                if (this.searchbar.search_mode_enabled) {
                    this.main_stack.visible_child_name = "search";
                } else {
                    this.main_stack.visible_child_name = "home";
                }
            });

            this.searchentry.search_changed.connect (() => {
                if (this.search_debounce_id != 0) {
                    GLib.Source.remove (this.search_debounce_id);
                    this.search_debounce_id = 0;
                }

                string query = this.searchentry.text.strip ();
                if (query.length == 0) {
                    this.search_page.clear ();
                    return;
                }

                this.search_debounce_id = GLib.Timeout.add (500, () => {
                    this.search_debounce_id = 0;
                    this.execute_search (query);
                    return GLib.Source.REMOVE;
                });
            });
        }

        private void execute_search (string query) {
            this.search_page.show_loading ();
            new Thread<void*> ("search-thread", () => {
                var resultsSuggestions = this.player.search_suggestions (query);
                var resultsMusics = this.player.search_tracks (query);
                var resultsAlbums = this.player.search_albums (query);
                var resultsPlaylists = this.player.search_playlists (query);
                var resultsArtists = this.player.search_artists (query);

                GLib.Idle.add (() => {
                    this.search_page.set_results (resultsSuggestions, resultsMusics, resultsAlbums, resultsPlaylists, resultsArtists);
                    return GLib.Source.REMOVE;
                });
                return null;
            });
        }

        private void update_nav_buttons () {
            this.button_prev.sensitive = this.queue.has_prev ();
            this.button_next.sensitive = this.queue.has_next ();
        }

        private string format_time (double total_seconds) {
            int s = (int) total_seconds;
            return "%d:%02d".printf (s / 60, s % 60);
        }

        public void play_track (string track_id, uint64 duration_secs, string title, string artist, string? cover_url) {
            this.label_current_title.label = title;
            this.label_current_artist.label = artist;

            var display = this.get_display () ?? Gdk.Display.get_default ();
            int scale = this.get_scale_factor ();

            if (display != null && cover_url != null) {
                Timbre.Utils.ImageLoader.get_default ().load_paintable_async.begin (
                    cover_url,
                    display,
                    50,
                    scale,
                    "audio-x-generic-symbolic",
                    (obj, res) => {
                        this.image_cover.paintable = Timbre.Utils.ImageLoader.get_default ().load_paintable_async.end (res);
                    }
                );
            }

            this.label_time_current.label = "0:00";
            this.adjustment_progress.value = 0.0;
            this.button_play_pause.sensitive = false;

            if (duration_secs > 0) {
                this.label_time_total.label = this.format_time ((double) duration_secs);
                this.adjustment_progress.upper = (double) duration_secs;
            } else {
                this.label_time_total.label = "--:--";
                this.adjustment_progress.upper = 0.0;
            }

            new Thread<void*> ("player-loader", () => {
                bool success = this.player.play_track_id (track_id, duration_secs);

                GLib.Idle.add (() => {
                    this.button_play_pause.sensitive = true;

                    if (success) {
                        if (duration_secs > 0) {
                            this.adjustment_progress.upper = (double) duration_secs;
                            this.label_time_total.label = this.format_time ((double) duration_secs);
                        }
                        this.is_playing = true;
                        this.button_play_pause.icon_name = "media-playback-pause-symbolic";

                        if (this.tick_id == 0) {
                            this.tick_id = GLib.Timeout.add (250, this.update_ui_tick);
                        }
                    } else {
                        this.label_time_total.label = "0:00";
                    }
                    return GLib.Source.REMOVE;
                });
                return null;
            });
        }

        private bool update_ui_tick () {
            if (this.player == null) {
                return true;
            }

            double current_pos = this.player.get_position ();
            this.adjustment_progress.value = current_pos;
            this.label_time_current.label = format_time (current_pos);

            if (this.adjustment_progress.upper == 0.0) {
                double duration = this.player.get_duration ();
                if (duration > 0.0) {
                    this.adjustment_progress.upper = duration;
                    this.label_time_total.label = format_time (duration);
                }
            }

            return true;
        }

        [GtkCallback]
        private void on_seek_changed () {
            if (this.is_seeking) return;

            double target_pos = this.adjustment_progress.value;
            int total_secs = (int) target_pos;
            this.label_time_current.label = "%d:%02d".printf (total_secs / 60, total_secs % 60);

            if (this.seek_debounce_id != 0) GLib.Source.remove (this.seek_debounce_id);

            this.seek_debounce_id = GLib.Timeout.add (250, () => {
                this.player.seek (target_pos);
                this.seek_debounce_id = 0;
                return GLib.Source.REMOVE;
            });
        }

        [GtkCallback]
        private void on_play_pause_clicked () {
            if (this.is_playing) {
                this.player.pause ();
                this.button_play_pause.icon_name = "media-playback-start-symbolic";
                this.is_playing = false;
            } else {
                this.player.resume ();
                this.button_play_pause.icon_name = "media-playback-pause-symbolic";
                this.is_playing = true;
            }
        }

        [GtkCallback]
        private void on_prev_clicked () {
            this.queue.prev ();
        }

        [GtkCallback]
        private void on_next_clicked () {
            this.queue.next ();
        }
    }
}
