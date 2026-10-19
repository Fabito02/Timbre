using Timbre.Utils;

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

        private bool slider_locked = false;
        private uint slider_unlock_id = 0;
        private double pending_seek_target = -1.0;
        private bool loading_track = false;
        private bool radio_loading = false;

        private string current_track_id = "";
        private int like_fetch_gen = 0;
        private double metadata_duration = 0.0;
        private Timbre.TrackItem? pending_track = null;

        private bool play_recorded = false;
        private string recorded_track_id = "";
        private int64 last_tick_us = 0;

        [GtkChild] private unowned Gtk.Scale scale_progress;
        [GtkChild] private unowned Gtk.Adjustment adjustment_progress;
        [GtkChild] private unowned Gtk.Label label_time_current;
        [GtkChild] private unowned Gtk.Label label_time_total;
        [GtkChild] private unowned Gtk.Button button_play_pause;
        [GtkChild] private unowned Gtk.Button button_prev;
        [GtkChild] private unowned Gtk.Button button_next;

        [GtkChild] private unowned Adw.OverlaySplitView split_view;
        [GtkChild] private unowned Gtk.ToggleButton button_toggle_queue;
        [GtkChild] private unowned Gtk.ToggleButton fullscreen_button_toggle_queue;
        [GtkChild] private unowned Gtk.Button button_open_fullscreen;
        [GtkChild] private unowned Gtk.Button button_close_fullscreen;
        [GtkChild] private unowned Gtk.ListView queue_list;
        [GtkChild] private unowned Gtk.Label label_queue_count;
        [GtkChild] private unowned Gtk.Button button_clear_queue;
        [GtkChild] private unowned Gtk.Button button_repeat;
        [GtkChild] private unowned Gtk.ToggleButton button_shuffle;

        [GtkChild] private unowned Gtk.Label label_current_title;
        [GtkChild] private unowned Gtk.Label label_current_artist;
        [GtkChild] private unowned Gtk.Picture image_cover;
        [GtkChild] private unowned Gtk.Picture image_fullscreen;
        [GtkChild] private unowned Gtk.Box like_slot;
        [GtkChild] private unowned Gtk.Box live_widget;
        [GtkChild] private unowned Gtk.Box time_labels;

        [GtkChild] private unowned Gtk.SearchBar searchbar;
        [GtkChild] private unowned Gtk.Button button_back;
        [GtkChild] private unowned Gtk.SearchEntry searchentry;
        [GtkChild] private unowned Adw.ViewStack main_stack;
        [GtkChild] private unowned Adw.NavigationView navigation_view;
        [GtkChild] private unowned Adw.NavigationView library_view;
        [GtkChild] private unowned Adw.NavigationView search_view;
        [GtkChild] private unowned Gtk.Revealer bottom_bar_revealer;

        [GtkChild] private unowned Adw.BottomSheet fullscreen_sheet;
        [GtkChild] private unowned Adw.ToolbarView fullscreen_sheet_content;

        [GtkChild] private unowned Adw.ViewSwitcher switcher;
        [GtkChild] private unowned Adw.ViewSwitcherBar switcher_bar;
        [GtkChild] private unowned Timbre.LibraryPage library_page;

        [GtkChild] private unowned Timbre.SearchPage search_page;
        [GtkChild] private unowned Timbre.HomePage home_page;

        private Gtk.SingleSelection queue_selection;
        private Timbre.Utils.ImageBinding cover_binding;
        private Timbre.Utils.ImageBinding cover_fullscreen_binding;
        private Timbre.LikeButton? bar_like_btn = null;
        public Timbre.Services.Mpris? mpris { get; private set; default = null; }

        private string previous_tab = "home";

        private class TrackInfo {
            public LikeStatus status = LikeStatus.INDIFFERENT;
            public double duration = 0.0;
        }

        public Window (Timbre.Application app) {
            Object (application: app);

            this.player = app.get_player ();
            this.cookies_path = app.cookies_path;
            this.queue = new Timbre.QueueManager ();

            this.switcher.stack = this.main_stack;
            this.switcher_bar.stack = this.main_stack;

            this.search_page.set_player (this.player);
            this.home_page.set_player (this.player);
            this.library_page.set_player (this.player);
            this.main_stack.visible_child_name = "home";

            var key_ctrl = new Gtk.EventControllerKey ();
            key_ctrl.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            key_ctrl.key_pressed.connect ((keyval, keycode, state) => {
                if (this.searchbar.search_mode_enabled) return false;
                if ((state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SUPER_MASK)) != 0) return false;

                var focused = this.get_focus ();
                if (focused is Gtk.Editable || focused is Gtk.TextView) return false;

                unichar c = (unichar) Gdk.keyval_to_unicode (keyval);
                if (c != 0 && c.isprint ()) {
                    this.searchbar.search_mode_enabled = true;
                    this.searchentry.set_text (c.to_string ());
                    this.searchentry.set_position (-1);
                    this.searchentry.grab_focus ();
                    return true;
                }
                return false;
            });
            ((Gtk.Widget)this).add_controller (key_ctrl);

            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 48);
            this.cover_fullscreen_binding = new Timbre.Utils.ImageBinding (this.image_fullscreen, 512);

            this.bar_like_btn = new Timbre.LikeButton (this.player);
            this.like_slot.append (this.bar_like_btn);

            this.setup_navigation ();
            this.setup_queue_view ();
            this.setup_search ();
            this.setup_switcher ();
            this.update_nav_buttons ();
            this.setup_mpris ();

            this.fullscreen_sheet.notify["open"].connect (() => {
                if (this.fullscreen_sheet.open) {
                    if (this.pending_track != null) {
                        this.cover_fullscreen_binding.load (this.pending_track.thumbnail_url);
                    }
                } else {
                    this.bottom_bar_revealer.reveal_child = true;

                    GLib.Idle.add (() => {
                        this.fullscreen_sheet_content.height_request = -1;
                        return GLib.Source.REMOVE;
                    });
                }
            });

            this.main_stack.notify["visible-child-name"].connect (() => {
                if (this.main_stack.visible_child_name != "search") {
                    this.previous_tab = this.main_stack.visible_child_name;
                }
                if (this.main_stack.visible_child_name == "library") {
                    this.library_page.load_library_data (false);
                }
                this.update_back_button ();
            });

            this.close_request.connect (() => {
                this.finish_recording ();
                return false;
            });

            this.queue.repeat_changed.connect ((mode) => {
                switch (mode) {
                    case Timbre.QueueManager.RepeatMode.OFF:
                        this.button_repeat.icon_name = "media-playlist-no-repeat-symbolic";
                        this.button_repeat.remove_css_class ("accent");
                        this.button_repeat.add_css_class ("flat");
                        this.button_repeat.tooltip_text = _("Repeat: off");
                        break;
                    case Timbre.QueueManager.RepeatMode.ALL:
                        this.button_repeat.icon_name = "media-playlist-repeat-symbolic";
                        this.button_repeat.add_css_class ("accent");
                        this.button_repeat.remove_css_class ("flat");
                        this.button_repeat.tooltip_text = _("Repeat: all");
                        break;
                    case Timbre.QueueManager.RepeatMode.ONE:
                        this.button_repeat.icon_name = "song-repeat-symbolic";
                        this.button_repeat.add_css_class ("accent");
                        this.button_repeat.remove_css_class ("flat");
                        this.button_repeat.tooltip_text = _("Repeat: one");
                        break;
                }
            });

            this.queue.shuffle_changed.connect ((enabled) => {
                this.button_shuffle.active = enabled;

                if (enabled) {
                    this.button_shuffle.icon_name = "media-playlist-shuffle-symbolic";
                    this.button_shuffle.add_css_class ("accent");
                    this.button_shuffle.tooltip_text = _("Unshuffle");
                } else {
                    this.button_shuffle.icon_name = "media-playlist-consecutive-symbolic";
                    this.button_shuffle.remove_css_class ("accent");
                    this.button_shuffle.tooltip_text = _("Shuffle");
                }
            });

            this.button_repeat.clicked.connect (() => {
                this.queue.cycle_repeat ();
            });

            this.button_shuffle.clicked.connect (() => {
                this.queue.set_shuffle (!this.queue._shuffle);
            });
        }

        public override void size_allocate (int width, int height, int baseline) {
            base.size_allocate (width, height, baseline);

            if (this.fullscreen_sheet.open) {
                this.fullscreen_sheet_content.height_request = height;
            }
        }

        public void open_preferences () {
            var settings_win = new Timbre.SettingsWindow (
                this.player, this.cookies_path, this.home_page);
            settings_win.present (this);
        }

        private void setup_mpris () {
            this.mpris = new Timbre.Services.Mpris (this.player, this.queue);

            this.mpris.raise_requested.connect (() => {
                this.set_visible (true);
                this.present ();
                this.present_with_time ((uint32) time_t ());
            });

            this.mpris.quit_requested.connect (() => {
                if (this.application != null) {
                    this.application.quit ();
                }
            });

            this.mpris.set_position_provider (() => this.adjustment_progress.value);
            this.mpris.set_duration_provider (() => {
                if (this.metadata_duration > 0.0) return this.metadata_duration;
                return this.adjustment_progress.upper;
            });

            this.mpris.start ();
        }

        private void setup_switcher () {
            this.searchbar.notify["search-mode-enabled"].connect (this.update_switcher_visibility);
            this.switcher_bar.notify["reveal"].connect (this.update_switcher_visibility);

            this.update_switcher_visibility ();
        }

        private void update_switcher_visibility () {
            bool search_on = this.searchbar.search_mode_enabled;
            bool bar_on = this.switcher_bar.reveal;

            this.switcher.visible = !search_on && !bar_on;
        }

        private void open_collection (string id, string type_name,
                                      string title, string subtitle,
                                      string? cover, Adw.NavigationView? target_view = null) {
            string kind = type_name.down ();
            if (kind == "artist") {
                this.open_artist (id, title, target_view);
                return;
            }
            var page = new Timbre.CollectionPage (
                this.player, id, type_name, title, subtitle, cover);
            page.play_collection.connect ((tracks, start_index) => {
                this.queue.play_list (tracks, start_index);
            });
            var nav = target_view ?? this.navigation_view;
            nav.push (page);
        }

        public void open_artist (string channel_id, string? name, Adw.NavigationView? target_view = null) {
            var page = new Timbre.ArtistPage (this.player, channel_id, name);
            this.wire_artist_page (page, target_view);
            var nav = target_view ?? this.navigation_view;
            nav.push (page);
        }

        private void wire_artist_page (Timbre.ArtistPage page, Adw.NavigationView? target_view) {
            page.track_selected.connect ((id, duration, title, artist, cover) => {
                this.queue.play_single (new Timbre.TrackItem.with_data (
                    id, title, artist, duration, cover));
            });

            page.collection_selected.connect ((id, type_name, title, subtitle, cover) => {
                this.open_collection (id, type_name, title, subtitle, cover, target_view);
            });

            page.play_songs_requested.connect ((tracks, start_index, shuffle) => {
                if (tracks.length == 0) return;
                if (shuffle) {
                    var shuffled = new GenericArray<TrackItem> ();
                    for (int i = 0; i < tracks.length; i++) shuffled.add (tracks.get (i));
                    for (int i = shuffled.length - 1; i > 0; i--) {
                        int j = Random.int_range (0, i + 1);
                        var tmp = shuffled.get (i);
                        shuffled.set (i, shuffled.get (j));
                        shuffled.set (j, tmp);
                    }
                    this.queue.play_list (shuffled, 0);
                } else {
                    int idx = start_index < 0 ? 0 : start_index;
                    this.queue.play_list (tracks, idx);
                }
            });

            page.show_all_requested.connect ((browse_id, params_json, title, seed) => {
                var sp = new Timbre.SectionPage (
                    this.player, browse_id, params_json, title, seed);

                sp.track_selected.connect ((id, duration, t, artist, cover) => {
                    this.queue.play_single (new Timbre.TrackItem.with_data (
                        id, t, artist, duration, cover));
                });

                sp.collection_selected.connect ((id, type_name, t, subtitle, cover) => {
                    this.open_collection (id, type_name, t, subtitle, cover, target_view);
                });

                var nav = target_view ?? this.navigation_view;
                nav.push (sp);
            });
        }

        private void setup_navigation () {
            this.button_back.clicked.connect (() => {
                string current = this.main_stack.visible_child_name;
                if (current == "search") {
                    if (this.search_view.navigation_stack.get_n_items () > 1) {
                        this.search_view.pop ();
                    } else {
                        this.searchbar.search_mode_enabled = false;
                    }
                } else if (current == "library") {
                    if (this.searchbar.search_mode_enabled) {
                        this.searchbar.search_mode_enabled = false;
                    } else {
                        this.library_view.pop ();
                    }
                } else {
                    this.navigation_view.pop ();
                }
            });

            this.navigation_view.pushed.connect (this.update_back_button);
            this.navigation_view.popped.connect (() => {
                this.update_back_button ();
                Timbre.Utils.ImageLoader.get_default ().shrink_to (4);
                Timbre.Utils.trim_memory ();
            });

            this.library_view.pushed.connect (this.update_back_button);
            this.library_view.popped.connect (() => {
                this.update_back_button ();
                Timbre.Utils.ImageLoader.get_default ().shrink_to (4);
                Timbre.Utils.trim_memory ();
            });

            this.search_view.pushed.connect (this.update_back_button);
            this.search_view.popped.connect (this.update_back_button);

            this.button_toggle_queue.toggled.connect (() => {
                this.split_view.show_sidebar = this.button_toggle_queue.active;
            });

            this.fullscreen_button_toggle_queue.toggled.connect (() => {
                this.split_view.show_sidebar = this.fullscreen_button_toggle_queue.active;
            });

            this.split_view.notify["show-sidebar"].connect (() => {
                this.button_toggle_queue.active = this.split_view.show_sidebar;
                this.fullscreen_button_toggle_queue.active = this.split_view.show_sidebar;
            });

            this.home_page.collection_selected.connect ((id, type_name, title, subtitle, cover) => {
                this.open_collection (id, type_name, title, subtitle, cover, this.navigation_view);
            });

            this.home_page.track_selected.connect ((id, duration, title, artist, cover) => {
                this.queue.play_single (new Timbre.TrackItem.with_data (
                    id, title, artist, duration, cover));
            });

            this.home_page.show_all_requested.connect ((browse_id, params_json, title, seed) => {
                var page = new Timbre.SectionPage (
                    this.player, browse_id, params_json, title, seed);

                page.track_selected.connect ((id, duration, t, artist, cover) => {
                    this.queue.play_single (new Timbre.TrackItem.with_data (
                        id, t, artist, duration, cover));
                });

                page.collection_selected.connect ((id, type_name, t, subtitle, cover) => {
                    this.open_collection (id, type_name, t, subtitle, cover, this.navigation_view);
                });

                this.navigation_view.push (page);
            });

            this.library_page.collection_selected.connect ((id, kind, title, subtitle, cover) => {
                this.open_collection (id, kind, title, subtitle, cover, this.library_view);
            });

            this.library_page.artist_selected.connect ((id, name) => {
                this.open_artist (id, name, this.library_view);
            });
        }

        private void update_back_button () {
            string current = this.main_stack.visible_child_name;
            if (current == "library") {
                this.button_back.visible = this.library_view.navigation_stack.get_n_items () > 1 || this.searchbar.search_mode_enabled;
            } else if (current == "home") {
                this.button_back.visible = this.navigation_view.navigation_stack.get_n_items () > 1;
            } else if (current == "search") {
                this.button_back.visible = this.search_view.navigation_stack.get_n_items () > 1 || this.searchbar.search_mode_enabled;
            } else {
                this.button_back.visible = false;
            }
        }

        [GtkCallback]
        public void open_fullscreen_clicked () {
            this.bottom_bar_revealer.reveal_child = false;

            if (this.pending_track != null) {
                this.cover_fullscreen_binding.load (this.pending_track.thumbnail_url);
            }

            this.fullscreen_sheet_content.height_request = this.get_height();
            this.fullscreen_sheet.open = true;
        }

        [GtkCallback]
        public void close_fullscreen_clicked () {
            this.fullscreen_sheet.open = false;
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

            factory.teardown.connect ((item) => {
                var list_item = (Gtk.ListItem) item;
                var row = (Timbre.QueueRow) list_item.get_child ();
                if (row != null) {
                    row.unbind ();
                    list_item.set_child (null);
                }
            });

            this.queue_list.factory = factory;

            this.queue.track_changed.connect ((track) => {
                this.play_track (track);
                this.update_nav_buttons ();
            });

            this.queue.queue_updated.connect (() => {
                this.update_nav_buttons ();
                int total = this.queue.length;
                this.label_queue_count.label = (total == 1) ? _("1 track") : _("%d tracks").printf (total);
            });

            this.button_clear_queue.clicked.connect (() => {
                this.fullscreen_sheet.open = false;
                this.split_view.show_sidebar = false;
                this.bottom_bar_revealer.reveal_child = false;
                this.finish_recording ();
                this.queue.clear ();
                this.player.reset ();
                this.is_playing = false;
                this.slider_locked = false;
                this.pending_seek_target = -1.0;
                this.metadata_duration = 0.0;
                this.pending_track = null;
                if (this.slider_unlock_id != 0) {
                    GLib.Source.remove (this.slider_unlock_id);
                    this.slider_unlock_id = 0;
                }
                this.button_play_pause.icon_name = "media-playback-start-symbolic";
                this.label_current_title.label = "No track selected";
                this.label_current_artist.label = "Artista";
                this.label_time_current.label = "0:00";
                this.label_time_total.label = "0:00";
                this.adjustment_progress.value = 0.0;
                this.cover_binding.load (null);
                this.cover_fullscreen_binding.load (null);

                this.current_track_id = "";
                this.like_fetch_gen++;
                if (this.bar_like_btn != null) {
                    this.bar_like_btn.set_target (null);
                }
            });
        }

        private void setup_search () {
            this.search_page.track_selected.connect ((id, duration, title, artist, cover) => {
                this.queue.play_single (new Timbre.TrackItem.with_data (
                    id, title, artist, duration, cover));
            });

            this.search_page.collection_selected.connect ((id, type_name, title, subtitle, cover) => {
                this.open_collection (id, type_name, title, subtitle, cover, this.search_view);
            });

            this.searchbar.notify["search-mode-enabled"].connect (() => {
                if (this.searchbar.search_mode_enabled) {
                    if (this.previous_tab == "library") {
                        this.searchentry.grab_focus ();
                    } else {
                        this.main_stack.visible_child_name = "search";
                        this.searchentry.grab_focus ();
                    }
                } else {
                    if (this.previous_tab == "library") {
                        this.library_page.filter_content ("");
                    } else {
                        this.main_stack.visible_child_name = this.previous_tab;
                        this.search_page.clear ();
                        while (this.search_view.navigation_stack.get_n_items () > 1) {
                            this.search_view.pop ();
                        }
                    }
                }
                this.update_switcher_visibility ();
                this.update_back_button ();
            });

            this.searchentry.search_changed.connect (() => {
                if (this.search_debounce_id != 0) {
                    GLib.Source.remove (this.search_debounce_id);
                    this.search_debounce_id = 0;
                }

                string query = this.searchentry.text.strip ();

                if (this.previous_tab == "library") {
                    this.library_page.filter_content (query);
                    return;
                }

                if (query.length == 0) {
                    this.search_page.clear ();
                    return;
                }

                this.search_debounce_id = GLib.Timeout.add (100, () => {
                    this.search_debounce_id = 0;
                    this.execute_search (query);
                    return GLib.Source.REMOVE;
                });
            });
        }

        private void execute_search (string query) {
            this.search_page.show_loading ();

            this.player.search (query, (json, error) => {
                Idle.add (() => {
                    if (error != null) {
                        warning ("search: %s", (string) error);
                        Timbre.string_free (error);
                        this.search_page.clear ();
                        return GLib.Source.REMOVE;
                    }
                    this.search_page.set_results_json ((string) json);
                    Timbre.string_free (json);
                    return GLib.Source.REMOVE;
                });
            });
        }

        private void update_nav_buttons () {
            this.button_next.sensitive = this.queue.has_next ();
        }

        private string format_time (double total_seconds) {
            int s = (int) total_seconds;
            return "%d:%02d".printf (s / 60, s % 60);
        }

        private void set_slider_silently (double value) {
            this.slider_locked = true;
            this.adjustment_progress.value = value;
            this.slider_locked = false;
        }

        private static LikeStatus parse_like_status (string s) {
            switch (s) {
                case "Like":    return LikeStatus.LIKE;
                case "Dislike": return LikeStatus.DISLIKE;
                default:        return LikeStatus.INDIFFERENT;
            }
        }

        public void play_track (Timbre.TrackItem track) {
            this.finish_recording ();

            if (this.player != null) {
                this.player.stop ();
            }
            this.is_playing = false;
            this.button_play_pause.icon_name = "media-playback-start-symbolic";
            this.loading_track = true;

            if (track.duration_secs == 0) {
                this.pending_track = track;
                this.like_fetch_gen++;
                int my_gen = this.like_fetch_gen;
                this.fetch_and_play (track, my_gen);
                return;
            }
            this.start_playback (track, track.duration_secs);
        }

        private void fetch_and_play (Timbre.TrackItem track, int gen) {
            this.player.get_watch_playlist (track.id, "", (json, error) => {
                Idle.add (() => {
                    if (gen != this.like_fetch_gen) {
                        if (json != null) Timbre.string_free (json);
                        if (error != null) Timbre.string_free (error);
                        return GLib.Source.REMOVE;
                    }
                    uint64 dur = track.duration_secs;
                    if (error == null) {
                        var info = this.extract_track_info ((string) json, track.id);
                        if (info.duration > 0) dur = (uint64) info.duration;
                    }
                    if (json != null) Timbre.string_free (json);
                    if (error != null) Timbre.string_free (error);
                    this.start_playback (track, dur);
                    if (!this.fullscreen_sheet.open) {
                        bottom_bar_revealer.reveal_child = true;
                    }
                    return GLib.Source.REMOVE;
                });
            });
        }

        private void start_playback (Timbre.TrackItem track, uint64 duration) {
            message ("start_playback: id=%s dur=%lu title=%s".printf (
                track.id, (ulong) duration, track.title));

            this.pending_track = track;

            if (this.slider_unlock_id != 0) {
                GLib.Source.remove (this.slider_unlock_id);
                this.slider_unlock_id = 0;
            }
            this.slider_locked = false;
            this.pending_seek_target = -1.0;
            this.loading_track = true;

            this.metadata_duration = (duration > 0)
                ? (double) duration
                : 0.0;

            this.label_current_title.label = track.title;
            this.label_current_artist.label = track.artist;

            this.cover_binding.load (track.thumbnail_url);

            if (this.fullscreen_sheet.open) {
                this.cover_fullscreen_binding.load (track.thumbnail_url);
            }

            this.set_slider_silently (0.0);
            this.label_time_current.label = "0:00";
            if (duration > 0) {
                this.label_time_total.label = this.format_time ((double) duration);
                this.adjustment_progress.upper = (double) duration;
                this.live_widget.visible = track.is_live;
                this.time_labels.visible = !track.is_live;
            } else {
                this.live_widget.visible = track.is_live;
                this.time_labels.visible = !track.is_live;
                this.adjustment_progress.upper = 0.0;
            }

            this.button_play_pause.sensitive = false;
            this.is_playing = false;
            this.button_play_pause.icon_name = "media-playback-start-symbolic";

            this.current_track_id = track.id;
            this.recorded_track_id = track.id;
            this.play_recorded = false;
            this.last_tick_us = 0;

            this.like_fetch_gen++;
            int my_fetch_gen = this.like_fetch_gen;

            bool need_like_fetch = false;
            bool need_duration_fetch = (duration == 0);

            if (this.bar_like_btn != null) {
                if (track.like_status != null) {
                    this.bar_like_btn.set_target (track.id, track.like_status);
                } else {
                    this.bar_like_btn.set_target (track.id, null);
                    need_like_fetch = true;
                }
            }

            bool need_metadata_fetch = need_like_fetch || need_duration_fetch;

            string track_id = track.id;
            this.player.play_track_id (track_id, duration, (success, error) => {
                Idle.add (() => {
                    this.loading_track = false;

                    var err_msg = error != null ? (string) error : "(none)";
                    message ("play callback: id=%s success=%s error=%s".printf (
                        track_id, success.to_string (), err_msg));

                    this.button_play_pause.sensitive = true;

                    if (!success) {
                        if (error != null) {
                            Timbre.string_free (error);
                        }
                        return GLib.Source.REMOVE;
                    }

                    this.log_player_stats ();

                    if (this.tick_id == 0) {
                        this.tick_id = GLib.Timeout.add (250, this.update_ui_tick);
                    }

                    if (need_metadata_fetch && my_fetch_gen == this.like_fetch_gen) {
                        this.fetch_track_metadata (track_id, my_fetch_gen);
                    }

                    if (!this.fullscreen_sheet.open) {
                        bottom_bar_revealer.reveal_child = true;
                    }

                    if (!this.queue.has_next ()
                        && this.queue.repeat_mode != Timbre.QueueManager.RepeatMode.ALL) {
                        this.play_radio_from_current ();
                    }

                    return GLib.Source.REMOVE;
                });
            });
        }

        private void fetch_track_metadata (string track_id, int gen) {
            this.player.get_watch_playlist (track_id, "", (json, error) => {
                Idle.add (() => {
                    if (gen != this.like_fetch_gen) {
                        if (error != null) Timbre.string_free (error);
                        if (json != null) Timbre.string_free (json);
                        return GLib.Source.REMOVE;
                    }

                    if (error != null) {
                        Timbre.string_free (error);
                        return GLib.Source.REMOVE;
                    }

                    string json_str = (string) json;
                    Timbre.string_free (json);

                    var info = this.extract_track_info (json_str, track_id);

                    if (this.current_track_id != track_id) {
                        return GLib.Source.REMOVE;
                    }

                    if (this.bar_like_btn != null) {
                        this.bar_like_btn.set_target (track_id, info.status);
                    }

                    if (info.duration > 0.0) {
                        this.metadata_duration = info.duration;
                        if (Math.fabs (this.adjustment_progress.upper
                                       - this.metadata_duration) > 0.5) {
                            this.adjustment_progress.upper = this.metadata_duration;
                            this.label_time_total.label =
                                this.format_time (this.metadata_duration);
                        }
                    }
                    return GLib.Source.REMOVE;
                });
            });
        }

        private TrackInfo extract_track_info (string json_str, string track_id) {
            var info = new TrackInfo ();
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (json_str);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                    return info;
                }
                var obj = root.get_object ();
                if (!obj.has_member ("tracks")) return info;

                var arr = obj.get_array_member ("tracks");
                foreach (unowned Json.Node node in arr.get_elements ()) {
                    if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                    var wrapper = node.get_object ();
                    if (!wrapper.has_member ("track")) continue;
                    var t = wrapper.get_object_member ("track");
                    if (!t.has_member ("video_id")) continue;
                    if (t.get_string_member ("video_id") != track_id) continue;

                    if (t.has_member ("like_status") && !t.get_null_member ("like_status")) {
                        info.status = parse_like_status (t.get_string_member ("like_status"));
                    }

                    if (t.has_member ("duration_seconds")
                        && !t.get_null_member ("duration_seconds")) {
                        info.duration = (double) t.get_int_member ("duration_seconds");
                    }
                    break;
                }
            } catch (Error e) {
                debug ("extract_track_info: %s", e.message);
            }
            return info;
        }

        private void record_playback (string track_id) {
            string tid = track_id.dup ();
            this.player.record_play_start (tid, (success, error) => {
                if (!success && error != null) {
                    warning ("record_play_start failed for %s: %s", tid, (string) error);
                }
                if (error != null) {
                    Timbre.string_free (error);
                }
            });
        }

        private void finish_recording () {
            if (!this.play_recorded) return;
            this.play_recorded = false;
            string tid = this.recorded_track_id;
            this.recorded_track_id = "";
            if (tid.length > 0) {
                this.player.record_play_end (tid);
            }
        }

        private void log_player_stats () {
            var raw = this.player.get_stats ();
            if (raw == null) return;

            var json_str = (string) raw;
            Timbre.string_free (raw);

            try {
                var parser = new Json.Parser ();
                parser.load_from_data (json_str);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return;

                var obj = root.get_object ();
                string codec = obj.has_member ("acodec") && !obj.get_null_member ("acodec")
                    ? obj.get_string_member ("acodec") : "unknown";
                string container = obj.has_member ("ext") && !obj.get_null_member ("ext")
                    ? obj.get_string_member ("ext") : "unknown";
                string itag = obj.has_member ("format_id") && !obj.get_null_member ("format_id")
                    ? obj.get_string_member ("format_id") : "?";
                string protocol = obj.has_member ("protocol") && !obj.get_null_member ("protocol")
                    ? obj.get_string_member ("protocol") : "?";
                int bitrate = obj.has_member ("bitrate_kbps") && !obj.get_null_member ("bitrate_kbps")
                    ? (int) obj.get_int_member ("bitrate_kbps") : 0;
                int rate = obj.has_member ("sample_rate_hz") && !obj.get_null_member ("sample_rate_hz")
                    ? (int) obj.get_int_member ("sample_rate_hz") : 0;
                int channels = obj.has_member ("channels") && !obj.get_null_member ("channels")
                    ? (int) obj.get_int_member ("channels") : 0;
                bool cached = obj.has_member ("from_cache") && !obj.get_null_member ("from_cache")
                    ? obj.get_boolean_member ("from_cache") : false;

                var line = "codec=%s container=%s itag=%s bitrate=%d kbps rate=%.1f kHz channels=%d protocol=%s cached=%s".printf (
                    codec, container, itag, bitrate, rate / 1000.0, channels, protocol,
                    cached ? "yes" : "no"
                );
                message ("player stats: %s", line);
            } catch (Error e) {
                warning ("player stats parse: %s", e.message);
            }
        }

        private void settle_pending_seek () {
            if (!this.slider_locked || this.pending_seek_target < 0.0) return;

            double pos = this.player.get_position ();
            if (Math.fabs (pos - this.pending_seek_target) > 0.5) return;

            if (this.slider_unlock_id != 0) {
                GLib.Source.remove (this.slider_unlock_id);
                this.slider_unlock_id = 0;
            }
            this.pending_seek_target = -1.0;
            this.slider_locked = false;
        }

        private bool update_ui_tick () {
            if (this.player == null) return true;

            if (this.loading_track) return true;

            int state = this.player.get_state ();
            bool backend_playing = (state == 1);
            if (backend_playing != this.is_playing) {
                this.is_playing = backend_playing;
                this.button_play_pause.icon_name = this.is_playing
                    ? "media-playback-pause-symbolic"
                    : "media-playback-start-symbolic";

                if (backend_playing
                    && !this.play_recorded
                    && this.recorded_track_id.length > 0
                    && this.recorded_track_id == this.current_track_id) {
                    this.play_recorded = true;
                    this.record_playback (this.recorded_track_id);
                }

                if (this.player.is_finished () && this.player.get_position () > 0.0) {
                    this.finish_recording ();

                    this.queue.next ();
                }
            }

            this.settle_pending_seek ();

            if (this.slider_locked) return true;

            double current_pos = this.player.get_position ();
            this.set_slider_silently (current_pos);
            this.label_time_current.label = format_time (current_pos);

            if (this.play_recorded && backend_playing && this.recorded_track_id.length > 0) {
                int64 now_us = GLib.get_monotonic_time ();
                if (now_us - this.last_tick_us >= 1000000) {
                    this.last_tick_us = now_us;
                    this.player.record_play_tick (this.recorded_track_id, current_pos);
                }
            }

            double effective = this.metadata_duration;
            if (effective > 0.0
                && Math.fabs (this.adjustment_progress.upper - effective) > 0.5) {
                this.set_slider_silently (this.adjustment_progress.value);
                this.adjustment_progress.upper = effective;
                this.label_time_total.label = format_time (effective);
            }

            return true;
        }

        private void play_radio_from_current () {
            if (this.radio_loading) return;

            string seed = this.current_track_id;
            if (seed.length == 0) return;

            this.radio_loading = true;

            this.player.get_radio (seed, (json, error) => {
                Idle.add (() => {
                    this.radio_loading = false;

                    if (error != null) {
                        warning ("radio: %s", (string) error);
                        Timbre.string_free (error);
                        if (json != null) Timbre.string_free (json);
                        return GLib.Source.REMOVE;
                    }

                    var tracks = this.parse_radio_tracks ((string) json);
                    Timbre.string_free (json);

                    if (tracks.length > 0) {
                        tracks.remove_index (0);
                        this.queue.add_to_queue (tracks);
                    }
                    return GLib.Source.REMOVE;
                });
            });
        }

        private GenericArray<TrackItem> parse_radio_tracks (string json_str) {
            var tracks = new GenericArray<TrackItem> ();
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (json_str);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                    return tracks;
                }
                var obj = root.get_object ();
                if (!obj.has_member ("tracks")) return tracks;

                var arr = obj.get_array_member ("tracks");
                foreach (unowned Json.Node node in arr.get_elements ()) {
                    if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                    var wrapper = node.get_object ();
                    if (!wrapper.has_member ("track")) continue;
                    var t = wrapper.get_object_member ("track");

                    string vid = "";
                    if (t.has_member ("video_id") && !t.get_null_member ("video_id"))
                        vid = t.get_string_member ("video_id");
                    if (vid.length == 0) continue;

                    string title = t.has_member ("title") && !t.get_null_member ("title")
                        ? t.get_string_member ("title") : "";
                    string artist = t.has_member ("artist") && !t.get_null_member ("artist")
                        ? t.get_string_member ("artist") : "";
                    string? thumb = t.has_member ("thumb") && !t.get_null_member ("thumb")
                        ? t.get_string_member ("thumb") : null;
                    uint64 dur = t.has_member ("duration_seconds") && !t.get_null_member ("duration_seconds")
                        ? (uint64) t.get_int_member ("duration_seconds") : 0;

                    tracks.add (new Timbre.TrackItem.with_data (
                        vid, title, artist, dur, thumb));
                }
            } catch (Error e) {
                debug ("parse_radio_tracks: %s", e.message);
            }
            return tracks;
        }

        [GtkCallback]
        private void on_seek_changed () {
            if (this.slider_locked) return;
            if (this.is_seeking) return;

            double target_pos = this.adjustment_progress.value;
            int total_secs = (int) target_pos;
            this.label_time_current.label = "%d:%02d".printf (total_secs / 60, total_secs % 60);

            if (this.seek_debounce_id != 0) GLib.Source.remove (this.seek_debounce_id);
            this.seek_debounce_id = GLib.Timeout.add (250, () => {
                this.seek_debounce_id = 0;

                this.slider_locked = true;
                this.pending_seek_target = target_pos;

                if (this.slider_unlock_id != 0) {
                    GLib.Source.remove (this.slider_unlock_id);
                }
                this.slider_unlock_id = GLib.Timeout.add (3000, () => {
                    this.slider_unlock_id = 0;
                    this.slider_locked = false;
                    this.pending_seek_target = -1.0;
                    return GLib.Source.REMOVE;
                });

                this.player.seek (target_pos);
                if (this.mpris != null) {
                    this.mpris.notify_seeked (target_pos);
                }
                return GLib.Source.REMOVE;
            });
        }

        [GtkCallback]
        private void on_play_pause_clicked () {
            int state = this.player.get_state ();
            if (state == 1) {
                this.player.pause ();
                this.is_playing = false;
                this.button_play_pause.icon_name = "media-playback-start-symbolic";
            } else {
                this.player.resume ();
                this.is_playing = true;
                this.button_play_pause.icon_name = "media-playback-pause-symbolic";
            }
        }

        [GtkCallback]
        private void on_prev_clicked () {
            if (this.player.get_position () > 3.0 || !this.queue.has_prev ()) {
                this.player.seek (0.0);
                return;
            }

            this.queue.prev ();
        }

        [GtkCallback]
        private void on_next_clicked () {
            this.queue.next ();
        }
    }
}
