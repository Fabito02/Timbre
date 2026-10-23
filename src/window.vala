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

        private const double BG_DARKNESS_DARK = 0.35;
        private const double BG_DARKNESS_LIGHT = 0.15;
        private const double BG_MIN_ALPHA_DARK = 0.25;

        private uint nav_trim_id = 0;

        private GLib.GenericSet<string> pending_blurs = new GLib.GenericSet<string> (str_hash, str_equal);
        private string? pending_blur_url = null;
        private string? blur_processing_url = null;
        private string? blur_queued_url = null;
        private GLib.Cancellable? blur_cancel = null;

        private GLib.HashTable<string, Gdk.Texture> blur_texture_cache =
            new GLib.HashTable<string, Gdk.Texture> (str_hash, str_equal);
        private GLib.GenericArray<string> blur_texture_order = new GLib.GenericArray<string> ();

        private Gtk.CssProvider dynamic_bg_css = new Gtk.CssProvider ();
        private string? current_blur_path = null;
        private string? last_css_blur_path = null;
        private double current_blur_median = 0.0;
        private double current_blur_p2 = 0.0;

        private bool slider_locked = false;
        private uint slider_unlock_id = 0;
        private double pending_seek_target = -1.0;
        private bool loading_track = false;
        private bool radio_loading = false;

        private string current_track_id = "";
        private int like_fetch_gen = 0;
        private double metadata_duration = 0.0;
        private Timbre.Track? pending_track = null;

        private bool play_recorded = false;
        private string recorded_track_id = "";
        private int64 last_tick_us = 0;

        [GtkChild] private unowned Gtk.Adjustment adjustment_progress;
        [GtkChild] private unowned Gtk.Label label_time_current;
        [GtkChild] private unowned Gtk.Label label_time_total;
        [GtkChild] private unowned Gtk.Button button_play_pause;
        [GtkChild] private unowned Gtk.Button button_next;

        [GtkChild] private unowned Adw.OverlaySplitView split_view;
        [GtkChild] private unowned Gtk.ToggleButton button_toggle_queue;
        [GtkChild] private unowned Gtk.ToggleButton fullscreen_button_toggle_queue;
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

        [GtkChild] private unowned Adw.NavigationView root_nav;
        [GtkChild] private unowned Gtk.SearchBar searchbar;
        [GtkChild] private unowned Gtk.SearchEntry searchentry;
        [GtkChild] private unowned Adw.ViewStack main_stack;
        [GtkChild] private unowned Adw.NavigationView search_view;
        [GtkChild] private unowned Gtk.Revealer bottom_bar_revealer;

        [GtkChild] private unowned Adw.BottomSheet fullscreen_sheet;
        [GtkChild] private unowned Gtk.Overlay fs_sheet_overlay;

        [GtkChild] private unowned Adw.ViewSwitcher switcher;
        [GtkChild] private unowned Adw.ViewSwitcherBar switcher_bar;
        [GtkChild] private unowned Timbre.LibraryPage library_page;

        [GtkChild] private unowned Timbre.SearchPage search_page;
        [GtkChild] private unowned Timbre.HomePage home_page;

        [GtkChild] private unowned Gtk.Picture bg_picture;
        [GtkChild] private unowned Gtk.Picture fs_bg_picture;

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
            Object (application : app);

            Gtk.StyleContext.add_provider_for_display (
                                                       Gdk.Display.get_default (),
                                                       this.dynamic_bg_css,
                                                       Gtk.STYLE_PROVIDER_PRIORITY_USER + 1
            );

            var sm = Adw.StyleManager.get_default ();
            this.dynamic_bg_css.prefers_color_scheme = sm.dark
                ? Gtk.InterfaceColorScheme.DARK
                : Gtk.InterfaceColorScheme.LIGHT;

            sm.notify["dark"].connect (() => {
                this.dynamic_bg_css.prefers_color_scheme = sm.dark
                    ? Gtk.InterfaceColorScheme.DARK
                    : Gtk.InterfaceColorScheme.LIGHT;

                this.last_css_blur_path = null;
                if (this.current_blur_path != null) {
                    this.update_background_css ();
                }
            });

            this.close_request.connect (() => {
                if (this.blur_cancel != null) {
                    this.blur_cancel.cancel ();
                    this.blur_cancel = null;
                }
                if (this.pending_blur_url != null) {
                    this.pending_blurs.remove (this.pending_blur_url);
                    this.pending_blur_url = null;
                }
                this.blur_queued_url = null;

                if (this.is_playing) {
                    this.bg_picture.set_paintable (null);
                    this.fs_bg_picture.set_paintable (null);
                    this.last_css_blur_path = null;
                    this.dynamic_bg_css.load_from_string ("");
                    this.remove_css_class ("cover-bg-active");
                    this.hide ();
                    return true;
                }
                return false;
            });

            this.map.connect (() => {
                if (this.current_blur_path != null) {
                    this.update_background_css ();
                }
            });

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
                if (this.searchbar.search_mode_enabled)return false;
                if ((state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SUPER_MASK)) != 0)return false;

                var focused = this.get_focus ();
                if (focused is Gtk.Editable || focused is Gtk.TextView)return false;

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
            ((Gtk.Widget) this).add_controller (key_ctrl);

            this.cover_binding = new Timbre.Utils.ImageBinding (this.image_cover, 48);
            this.cover_fullscreen_binding = new Timbre.Utils.ImageBinding (this.image_fullscreen, 384);

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
                        this.cover_fullscreen_binding.load (this.pending_track.thumb);
                    }
                    if (this.current_blur_path != null) {
                        this.update_background_css ();
                    }
                } else {
                    this.bottom_bar_revealer.reveal_child = true;

                    GLib.Idle.add (() => {
                        this.fs_sheet_overlay.height_request = -1;
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
            });

            this.close_request.connect (() => {
                this.finish_recording ();
                return false;
            });

            this.queue.repeat_changed.connect ((mode) => {
                switch (mode) {
                    case Timbre.QueueManager.RepeatMode.OFF :
                        this.button_repeat.icon_name = "media-playlist-no-repeat-symbolic";
                        this.button_repeat.remove_css_class ("accent");
                        this.button_repeat.add_css_class ("flat");
                        this.button_repeat.tooltip_text = _("Repeat: off");
                        break;
                    case Timbre.QueueManager.RepeatMode.ALL :
                        this.button_repeat.icon_name = "media-playlist-repeat-symbolic";
                        this.button_repeat.add_css_class ("accent");
                        this.button_repeat.remove_css_class ("flat");
                        this.button_repeat.tooltip_text = _("Repeat: all");
                        break;
                    case Timbre.QueueManager.RepeatMode.ONE :
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
                this.fs_sheet_overlay.height_request = height;
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
            });

            this.mpris.quit_requested.connect (() => {
                if (this.application != null) {
                    this.application.quit ();
                }
            });

            this.mpris.set_position_provider (() => this.adjustment_progress.value);
            this.mpris.set_duration_provider (() => {
                if (this.metadata_duration > 0.0)return this.metadata_duration;
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

        private static string kind_to_lower (ItemKind kind) {
            switch (kind) {
            case ItemKind.SONG:     return "song";
            case ItemKind.VIDEO:    return "video";
            case ItemKind.ALBUM:    return "album";
            case ItemKind.ARTIST:   return "artist";
            case ItemKind.PLAYLIST: return "playlist";
            default:                return "song";
            }
        }

        public void open_collection (string id, string type_name,
                                     string title, string subtitle,
                                     string? cover, Adw.NavigationView? target_view = null) {
            string kind = type_name.down ();
            if (kind == "artist") {
                this.open_artist (id, title, target_view);
                return;
            }
            var page = new Timbre.CollectionPage (
                                                  this.player, id, type_name, title, subtitle, cover);
            page.play_collection.connect ((tracks, start_index, shuffle) => {
                if (tracks.length == 0)return;

                if (shuffle) {
                    int random_index = Random.int_range (0, tracks.length);

                    this.queue.play_list (tracks, random_index);
                    this.queue.set_shuffle (true);
                } else {
                    this.queue.play_list (tracks, start_index);
                }
            });

            this.root_nav.push (page);
        }

        public void open_artist (string channel_id, string? name, Adw.NavigationView? target_view = null) {
            var page = new Timbre.ArtistPage (this.player, channel_id, name);
            this.wire_artist_page (page, target_view);

            this.root_nav.push (page);
        }

        private void wire_artist_page (Timbre.ArtistPage page, Adw.NavigationView? target_view) {
            page.track_selected.connect ((item) => {
                this.queue.play_single (item.to_track ());
            });

            page.collection_selected.connect ((item) => {
                this.open_collection (item.id, kind_to_lower (item.kind),
                                      item.title, item.subtitle_text (), item.thumb, target_view);
            });

            page.play_songs_requested.connect ((tracks, start_index, shuffle) => {
                if (tracks.length == 0)return;

                if (shuffle) {
                    int random_index = Random.int_range (0, tracks.length);

                    this.queue.play_list (tracks, random_index);
                    this.queue.set_shuffle (true);
                } else {
                    this.queue.play_list (tracks, start_index);
                }
            });

            page.show_all_requested.connect ((browse_id, params_json, title, seed) => {
                var sp = new Timbre.SectionPage (
                                                 this.player, browse_id, params_json, title, seed);

                sp.track_selected.connect ((item) => {
                    this.queue.play_single (item.to_track ());
                });

                sp.collection_selected.connect ((item) => {
                    this.open_collection (item.id, kind_to_lower (item.kind),
                                          item.title, item.subtitle_text (), item.thumb, target_view);
                });

                this.root_nav.push (sp);
            });
        }

        private void schedule_nav_trim () {
            if (this.nav_trim_id != 0) {
                GLib.Source.remove (this.nav_trim_id);
                this.nav_trim_id = 0;
            }

            this.nav_trim_id = GLib.Timeout.add (500, () => {
                this.nav_trim_id = 0;

                Timbre.Utils.ImageLoader.get_default ().trim_now ();

                this.blur_texture_cache.remove_all ();
                this.blur_texture_order = new GLib.GenericArray<string> ();

                Timbre.Utils.trim_memory ();

                return GLib.Source.REMOVE;
            });
        }

        private void setup_navigation () {
            this.root_nav.pushed.connect (() => {
                this.schedule_nav_trim ();
            });
            this.root_nav.popped.connect (() => {
                this.schedule_nav_trim ();
            });

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

            this.home_page.collection_selected.connect ((item) => {
                this.open_collection (item.id, kind_to_lower (item.kind),
                                      item.title, item.subtitle_text (), item.thumb);
            });

            this.home_page.track_selected.connect ((item) => {
                this.queue.play_single (item.to_track ());
            });

            this.home_page.show_all_requested.connect ((browse_id, params_json, title, seed) => {
                var page = new Timbre.SectionPage (
                                                   this.player, browse_id, params_json, title, seed);

                page.track_selected.connect ((item) => {
                    this.queue.play_single (item.to_track ());
                });

                page.collection_selected.connect ((item) => {
                    this.open_collection (item.id, kind_to_lower (item.kind),
                                          item.title, item.subtitle_text (), item.thumb);
                });

                this.root_nav.push (page);
            });

            this.library_page.collection_selected.connect ((item) => {
                this.open_collection (item.id, kind_to_lower (item.kind),
                                      item.title, item.subtitle_text (), item.thumb);
            });

            this.library_page.artist_selected.connect ((id, name) => {
                this.open_artist (id, name);
            });
        }

        [GtkCallback]
        public void open_fullscreen_clicked () {
            this.bottom_bar_revealer.reveal_child = false;

            if (this.pending_track != null) {
                this.cover_fullscreen_binding.load (this.pending_track.thumb);
            }

            this.fs_sheet_overlay.height_request = this.get_height ();
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

                if (this.blur_cancel != null) {
                    this.blur_cancel.cancel ();
                    this.blur_cancel = null;
                }
                if (this.pending_blur_url != null) {
                    this.pending_blurs.remove (this.pending_blur_url);
                    this.pending_blur_url = null;
                }
                this.blur_queued_url = null;
                this.bg_picture.set_paintable (null);
                this.fs_bg_picture.set_paintable (null);
                this.blur_texture_cache.remove_all ();
                this.blur_texture_order = new GLib.GenericArray<string> ();
                this.current_blur_path = null;
                this.last_css_blur_path = null;
                this.current_blur_median = 0.0;
                this.current_blur_p2 = 0.0;
                this.remove_css_class ("cover-bg-active");

                this.current_track_id = "";
                this.like_fetch_gen++;
                if (this.bar_like_btn != null) {
                    this.bar_like_btn.set_target (null);
                }
            });
        }

        private void setup_search () {
            this.search_page.track_selected.connect ((item) => {
                this.queue.play_single (item.to_track ());
            });

            this.search_page.collection_selected.connect ((item) => {
                this.open_collection (item.id, kind_to_lower (item.kind),
                                      item.title, item.subtitle_text (), item.thumb);
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

                this.search_debounce_id = GLib.Timeout.add (350, () => {
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
            case "Like" : return LikeStatus.LIKE;
            case "Dislike" : return LikeStatus.DISLIKE;
                default : return LikeStatus.INDIFFERENT;
            }
        }

        public void play_track (Timbre.Track track) {
            this.finish_recording ();

            if (this.player != null) {
                this.player.stop ();
            }
            this.is_playing = false;
            this.button_play_pause.icon_name = "media-playback-start-symbolic";
            this.loading_track = true;

            if (track.duration_seconds == null || track.duration_seconds == 0) {
                this.pending_track = track;
                this.like_fetch_gen++;
                int my_gen = this.like_fetch_gen;
                this.fetch_and_play (track, my_gen);
                return;
            }
            this.start_playback (track, track.duration_seconds);
        }

        private void fetch_and_play (Timbre.Track track, int gen) {
            this.player.get_watch_playlist (track.id, "", (json, error) => {
                Idle.add (() => {
                    if (gen != this.like_fetch_gen) {
                        if (json != null)Timbre.string_free (json);
                        if (error != null)Timbre.string_free (error);
                        return GLib.Source.REMOVE;
                    }
                    uint64 dur = track.duration_seconds ?? 0;
                    if (error == null) {
                        var info = this.extract_track_info ((string) json, track.id);
                        if (info.duration > 0)dur = (uint64) info.duration;
                    }
                    if (json != null)Timbre.string_free (json);
                    if (error != null)Timbre.string_free (error);
                    this.start_playback (track, dur);
                    if (!this.fullscreen_sheet.open) {
                        bottom_bar_revealer.reveal_child = true;
                    }
                    return GLib.Source.REMOVE;
                });
            });
        }

        private void start_playback (Timbre.Track track, uint64 duration) {
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
            this.label_current_artist.label = track.artists_text ();

            this.cover_binding.load (track.thumb);

            if (this.fullscreen_sheet.open) {
                this.cover_fullscreen_binding.load (track.thumb);
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
                if (track.like_status != LikeStatus.INDIFFERENT) {
                    this.bar_like_btn.set_target (track.id, track.like_status);
                } else {
                    this.bar_like_btn.set_target (track.id, null);
                    need_like_fetch = true;
                }
            }

            bool need_metadata_fetch = need_like_fetch || need_duration_fetch;
            this.apply_blurred_background_async.begin (track.thumb);

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
                        this.play_radio (this.current_track_id, true);
                    }

                    return GLib.Source.REMOVE;
                });
            });
        }

        private void fetch_track_metadata (string track_id, int gen) {
            this.player.get_watch_playlist (track_id, "", (json, error) => {
                Idle.add (() => {
                    if (gen != this.like_fetch_gen) {
                        if (error != null)Timbre.string_free (error);
                        if (json != null)Timbre.string_free (json);
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
                if (!obj.has_member ("tracks"))return info;

                var arr = obj.get_array_member ("tracks");
                foreach (unowned Json.Node node in arr.get_elements ()) {
                    if (node.get_node_type () != Json.NodeType.OBJECT)continue;
                    var wrapper = node.get_object ();
                    if (!wrapper.has_member ("track"))continue;
                    var t = wrapper.get_object_member ("track");
                    if (!t.has_member ("video_id"))continue;
                    if (t.get_string_member ("video_id") != track_id)continue;

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
            if (!this.play_recorded)return;
            this.play_recorded = false;
            string tid = this.recorded_track_id;
            this.recorded_track_id = "";
            if (tid.length > 0) {
                this.player.record_play_end (tid);
            }
        }

        private void log_player_stats () {
            var raw = this.player.get_stats ();
            if (raw == null)return;

            var json_str = (string) raw;
            Timbre.string_free (raw);

            try {
                var parser = new Json.Parser ();
                parser.load_from_data (json_str);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT)return;

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
            if (!this.slider_locked || this.pending_seek_target < 0.0)return;

            double pos = this.player.get_position ();
            if (Math.fabs (pos - this.pending_seek_target) > 0.5)return;

            if (this.slider_unlock_id != 0) {
                GLib.Source.remove (this.slider_unlock_id);
                this.slider_unlock_id = 0;
            }
            this.pending_seek_target = -1.0;
            this.slider_locked = false;
        }

        private bool update_ui_tick () {
            if (this.player == null)return true;

            if (this.loading_track)return true;

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

            if (this.slider_locked)return true;

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

        public void play_radio (string id, bool increment) {
            if (this.radio_loading)return;

            if (id.length == 0)return;

            this.radio_loading = true;

            this.player.get_radio (id, (json, error) => {
                Idle.add (() => {
                    this.radio_loading = false;

                    if (error != null) {
                        warning ("radio: %s", (string) error);
                        Timbre.string_free (error);
                        if (json != null)Timbre.string_free (json);
                        return GLib.Source.REMOVE;
                    }

                    var tracks = this.parse_radio_tracks ((string) json);
                    Timbre.string_free (json);

                    if (increment) {
                        tracks.remove_index (0);
                        this.queue.add_to_queue (tracks);
                    } else {
                        this.queue.play_list (tracks);
                    }
                    return GLib.Source.REMOVE;
                });
            });
        }

        public void play_next (GenericArray<Track> tracks) {
            this.queue.play_next (tracks);
        }

        public void add_to_queue (GenericArray<Track> tracks) {
            this.queue.add_to_queue (tracks);
        }

        public void open_collection_from_row (string id, string type_name, string title, string subtitle, string? cover) {
            this.open_collection (id, type_name, title, subtitle, cover, this.root_nav);
        }

        public void open_artist_from_row (string channel_id, string? name) {
            this.open_artist (channel_id, name, this.root_nav);
        }

        private GenericArray<Track> parse_radio_tracks (string json_str) {
            var tracks = new GenericArray<Track> ();
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (json_str);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                    return tracks;
                }
                var obj = root.get_object ();
                if (!obj.has_member ("tracks"))return tracks;

                var arr = obj.get_array_member ("tracks");
                foreach (unowned Json.Node node in arr.get_elements ()) {
                    if (node.get_node_type () != Json.NodeType.OBJECT)continue;
                    var wrapper = node.get_object ();
                    if (!wrapper.has_member ("track"))continue;
                    var t = wrapper.get_object_member ("track");

                    string vid = "";
                    if (t.has_member ("video_id") && !t.get_null_member ("video_id"))
                        vid = t.get_string_member ("video_id");
                    if (vid.length == 0)continue;

                    var track = new Timbre.Track ();
                    track.id = vid;
                    track.title = t.has_member ("title") && !t.get_null_member ("title")
                        ? t.get_string_member ("title") : "";

                    if (t.has_member ("artists") && !t.get_null_member ("artists")) {
                        var a_node = t.get_member ("artists");
                        if (a_node.get_node_type () == Json.NodeType.ARRAY) {
                            foreach (unowned Json.Node an in a_node.get_array ().get_elements ()) {
                                if (an.get_node_type () != Json.NodeType.OBJECT)continue;
                                var ao = an.get_object ();
                                var p = new Person ();
                                if (ao.has_member ("name") && !ao.get_null_member ("name"))
                                    p.name = ao.get_string_member ("name");
                                track.artists.add (p);
                            }
                        }
                    } else if (t.has_member ("artist") && !t.get_null_member ("artist")) {
                        var p = new Person ();
                        p.name = t.get_string_member ("artist");
                        track.artists.add (p);
                    }

                    if (t.has_member ("thumb") && !t.get_null_member ("thumb"))
                        track.thumb = t.get_string_member ("thumb");
                    if (t.has_member ("duration_seconds") && !t.get_null_member ("duration_seconds"))
                        track.duration_seconds = (uint) t.get_int_member ("duration_seconds");

                    tracks.add (track);
                }
            } catch (Error e) {
                debug ("parse_radio_tracks: %s", e.message);
            }
            return tracks;
        }

        private Gdk.Texture? get_blur_texture (string path) {
            var cached = this.blur_texture_cache.lookup (path);
            if (cached != null)return cached;

            try {
                var file = GLib.File.new_for_path (path);
                var tex = Gdk.Texture.from_file (file);

                while (this.blur_texture_order.length >= 1) {
                    string oldest = this.blur_texture_order.get (0);
                    this.blur_texture_order.remove_index (0);
                    this.blur_texture_cache.remove (oldest);
                }

                this.blur_texture_cache.insert (path, tex);
                this.blur_texture_order.add (path);
                return tex;
            } catch (Error e) {
                warning ("blur texture: %s", e.message);
                return null;
            }
        }

        private void finish_blur_job (string cover_url) {
            this.pending_blurs.remove (cover_url);
            if (this.pending_blur_url == cover_url)this.pending_blur_url = null;
            if (this.blur_processing_url == cover_url)this.blur_processing_url = null;
            if (this.blur_processing_url == null)this.blur_cancel = null;

            if (this.blur_queued_url != null) {
                string next = this.blur_queued_url;
                this.blur_queued_url = null;
                this.apply_blurred_background_async.begin (next);
            }
        }

        public async void apply_blurred_background_async (string cover_url) {
            if (cover_url == null || cover_url.strip ().length == 0)return;
            if (this.pending_blurs.contains (cover_url))return;

            if (this.blur_processing_url != null) {
                this.blur_queued_url = cover_url;
                return;
            }

            if (this.blur_cancel != null) {
                this.blur_cancel.cancel ();
                this.blur_cancel = null;
            }

            var cancel = new GLib.Cancellable ();
            this.blur_cancel = cancel;
            this.blur_processing_url = cover_url;
            this.pending_blur_url = cover_url;
            this.pending_blurs.add (cover_url);

            var loader = Timbre.Utils.ImageLoader.get_default ();
            int blur_size = 120;

            bool ok = yield loader.ensure_downloaded_async (cover_url, blur_size, 1, cancel);

            if (!ok || cancel.is_cancelled ()) {
                this.finish_blur_job (cover_url);
                return;
            }

            string? local_path = loader.find_cached_path (cover_url, blur_size);
            if (local_path == null || cancel.is_cancelled ()) {
                this.finish_blur_job (cover_url);
                return;
            }

            string base_path = local_path;

            new GLib.Thread<void*> ("blur-worker", () => {
                if (cancel.is_cancelled ()) {
                    Idle.add (() => {
                        this.finish_blur_job (cover_url);
                        return Source.REMOVE;
                    });
                    return null;
                }

                string? blur_path = Timbre.BlurCache.blur_image_to_cache_from_file (base_path, 40);

                double median = 0.0;
                double p2 = 0.0;
                bool stats_ok = false;
                if (blur_path != null && !cancel.is_cancelled ()) {
                    stats_ok = loader.measure_stats (blur_path, out median, out p2);
                }

                Idle.add (() => {
                    bool was_cancelled = cancel.is_cancelled ();
                    this.finish_blur_job (cover_url);

                    if (was_cancelled)return Source.REMOVE;
                    if (blur_path == null || !stats_ok)return Source.REMOVE;

                    this.current_blur_path = blur_path;
                    this.current_blur_median = median;
                    this.current_blur_p2 = p2;
                    this.last_css_blur_path = null;
                    this.update_background_css ();
                    return Source.REMOVE;
                });
                return null;
            });
        }

        private static string css_alpha (double a) {
            int milli = (int) (a.clamp (0.0, 1.0) * 1000.0 + 0.5);
            return "%d.%03d".printf (milli / 1000, milli % 1000);
        }

        private static double overlay_alpha (double median, double p2, bool dark) {
            double raw;
            if (dark) {
                if (median <= 0.025)raw = 0.0;
                else {
                    double gain = GLib.Math.pow (0.025 / median, 1.0 / 2.4);
                    raw = 1.0 - gain;
                }
                double result = raw + (1.0 - raw) * BG_DARKNESS_DARK;
                result = Math.fmax (result, BG_MIN_ALPHA_DARK);
                return result.clamp (0.0, 0.95);
            } else {
                if (p2 >= 0.35)raw = 0.0;
                else raw = (0.35 - p2) / (1.0 - p2);
                double result = raw + (1.0 - raw) * BG_DARKNESS_LIGHT;
                return result.clamp (0.0, 0.95);
            }
        }

        private void update_background_css () {
            if (this.current_blur_path != null
                && this.current_blur_path == this.last_css_blur_path) {
                return;
            }

            if (this.current_blur_path == null) {
                this.last_css_blur_path = null;
                this.remove_css_class ("cover-bg-active");
                string empty_css = """
                    .bg-tint { background-color: transparent; }
                """;
                this.dynamic_bg_css.load_from_string (empty_css);
                return;
            }

            var tex = this.get_blur_texture (this.current_blur_path);
            if (tex == null) {
                return;
            }

            this.last_css_blur_path = this.current_blur_path;
            this.add_css_class ("cover-bg-active");

            this.bg_picture.set_paintable (tex);
            this.fs_bg_picture.set_paintable (tex);

            bool dark = Adw.StyleManager.get_default ().dark;
            double a = overlay_alpha (this.current_blur_median, this.current_blur_p2, dark);
            string a_str = css_alpha (a);
            string tint = dark ? "black" : "white";

            string css = """
                window.cover-bg-active .bg-tint {
                    background-color: alpha(%s, %s);
                }
            """.printf (tint, a_str);

            this.dynamic_bg_css.load_from_string (css);
        }

        [GtkCallback]
        private void on_seek_changed () {
            if (this.slider_locked)return;
            if (this.is_seeking)return;

            double target_pos = this.adjustment_progress.value;
            int total_secs = (int) target_pos;
            this.label_time_current.label = "%d:%02d".printf (total_secs / 60, total_secs % 60);

            if (this.seek_debounce_id != 0)GLib.Source.remove (this.seek_debounce_id);
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
