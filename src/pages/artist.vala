namespace Timbre {

    public class ArtistCardSection : Object {
        public string? title { get; set; default = null; }
        public string? browse_id { get; set; default = null; }
        public string? params { get; set; default = null; }
        public GenericArray<MediaItem> results { get; set; }

        public ArtistCardSection () {
            this.results = new GenericArray<MediaItem> ();
        }
    }

    public class ArtistSongSection : Object {
        public string? title { get; set; default = null; }
        public string? browse_id { get; set; default = null; }
        public GenericArray<Track> results { get; set; }

        public ArtistSongSection () {
            this.results = new GenericArray<Track> ();
        }
    }

    public class ArtistData : Object {
        public string name { get; set; default = ""; }
        public string? description { get; set; default = null; }
        public string? views { get; set; default = null; }
        public string? channel_id { get; set; default = null; }
        public string? radio_id { get; set; default = null; }
        public string? subscribers { get; set; default = null; }
        public string? monthly_listeners { get; set; default = null; }
        public bool subscribed { get; set; default = false; }
        public bool is_channel { get; set; default = false; }
        public string? banner_url { get; set; default = null; }
        public string? thumb_url { get; set; default = null; }

        public ArtistSongSection? songs { get; set; default = null; }
        public ArtistCardSection? albums { get; set; default = null; }
        public ArtistCardSection? singles { get; set; default = null; }
        public ArtistCardSection? videos { get; set; default = null; }
        public ArtistCardSection? playlists { get; set; default = null; }
        public ArtistCardSection? featured_on { get; set; default = null; }
        public ArtistCardSection? related { get; set; default = null; }
    }

    namespace ArtistParser {

        private static string? s_str (Json.Object o, string k) {
            if (!o.has_member (k) || o.get_null_member (k)) return null;
            return o.get_string_member (k);
        }

        private static Json.Array? s_arr (Json.Object o, string k) {
            if (!o.has_member (k) || o.get_null_member (k)) return null;
            var n = o.get_member (k);
            if (n.get_node_type () != Json.NodeType.ARRAY) return null;
            return n.get_array ();
        }

        private static string? last_string (Json.Array arr) {
            if (arr.get_length () == 0) return null;
            var n = arr.get_element (arr.get_length () - 1);
            if (n.get_node_type () == Json.NodeType.VALUE) return n.get_string ();
            return null;
        }

        private static LikeStatus parse_like_status (string s) {
            switch (s) {
                case "Like":    return LikeStatus.LIKE;
                case "Dislike": return LikeStatus.DISLIKE;
                default:        return LikeStatus.INDIFFERENT;
            }
        }

        private static string join_artists (Json.Object obj) {
            if (!obj.has_member ("artists") || obj.get_null_member ("artists")) return "";
            var arr = s_arr (obj, "artists");
            if (arr == null) return "";
            var sb = new StringBuilder ();
            foreach (unowned Json.Node n in arr.get_elements ()) {
                if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                var ao = n.get_object ();
                var name = s_str (ao, "name");
                if (name == null || name.length == 0) continue;
                if (sb.len > 0) sb.append (", ");
                sb.append (name);
            }
            return sb.str;
        }

        public static Track? parse_track (Json.Object o) {
            string vid = s_str (o, "video_id") ?? "";
            if (vid.length == 0) return null;

            var t = new Track ();
            t.id = vid;
            t.title = s_str (o, "title") ?? "";

            if (o.has_member ("artists") && !o.get_null_member ("artists")) {
                var arr = s_arr (o, "artists");
                if (arr != null) {
                    foreach (unowned Json.Node n in arr.get_elements ()) {
                        if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                        var ao = n.get_object ();
                        var p = new Person ();
                        var name = s_str (ao, "name");
                        if (name != null) p.name = name;
                        var id = s_str (ao, "id");
                        if (id != null) p.id = id;
                        t.artists.add (p);
                    }
                }
            } else if (o.has_member ("artist") && !o.get_null_member ("artist")) {
                var p = new Person ();
                p.name = o.get_string_member ("artist");
                t.artists.add (p);
            }

            if (o.has_member ("album") && !o.get_null_member ("album")) {
                var al = o.get_member ("album");
                if (al.get_node_type () == Json.NodeType.OBJECT) {
                    var ao = al.get_object ();
                    var named = new Named ();
                    var name = s_str (ao, "name");
                    if (name != null) named.name = name;
                    var id = s_str (ao, "id");
                    if (id != null) named.id = id;
                    t.album = named;
                }
            }

            if (o.has_member ("duration_seconds") && !o.get_null_member ("duration_seconds"))
                t.duration_seconds = (uint) o.get_int_member ("duration_seconds");
            if (o.has_member ("thumb") && !o.get_null_member ("thumb"))
                t.thumb = o.get_string_member ("thumb");
            if (o.has_member ("like_status") && !o.get_null_member ("like_status"))
                t.like_status = parse_like_status (o.get_string_member ("like_status"));

            return t;
        }

        private static MediaItem? parse_card (Json.Object o) {
            string id = s_str (o, "id") ?? "";
            if (id.length == 0) return null;

            var c = new MediaItem ();
            c.id = id;
            c.kind = ItemKind.parse (s_str (o, "kind") ?? "");
            c.title = s_str (o, "title") ?? "";
            c.subscribers = s_str (o, "subscribers");
            c.description = s_str (o, "description");
            c.item_type = s_str (o, "item_type");
            c.year = s_str (o, "year");

            if (c.kind != ItemKind.ARTIST) {
                var arr = s_arr (o, "artists");
                if (arr != null) {
                    foreach (unowned Json.Node n in arr.get_elements ()) {
                        if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                        var ao = n.get_object ();
                        var p = new Person ();
                        var name = s_str (ao, "name");
                        if (name != null) p.name = name;
                        var pid = s_str (ao, "id");
                        if (pid != null) p.id = pid;
                        c.artists.add (p);
                    }
                }
            }

            if (o.has_member ("thumb") && !o.get_null_member ("thumb"))
                c.thumb = o.get_string_member ("thumb");

            return c;
        }

        private static ArtistCardSection? parse_card_section (Json.Object root, string key) {
            if (!root.has_member (key) || root.get_null_member (key)) return null;
            var n = root.get_member (key);
            if (n.get_node_type () != Json.NodeType.OBJECT) return null;
            var o = n.get_object ();

            var sec = new ArtistCardSection ();
            sec.title = s_str (o, "title");
            sec.browse_id = s_str (o, "browse_id");
            sec.params = s_str (o, "params");

            var arr = s_arr (o, "results");
            if (arr != null) {
                foreach (unowned Json.Node item in arr.get_elements ()) {
                    if (item.get_node_type () != Json.NodeType.OBJECT) continue;
                    var c = parse_card (item.get_object ());
                    if (c != null) sec.results.add (c);
                }
            }
            return sec;
        }

        private static ArtistSongSection? parse_song_section (Json.Object root, string key) {
            if (!root.has_member (key) || root.get_null_member (key)) return null;
            var n = root.get_member (key);
            if (n.get_node_type () != Json.NodeType.OBJECT) return null;
            var o = n.get_object ();

            var sec = new ArtistSongSection ();
            sec.title = s_str (o, "title");
            sec.browse_id = s_str (o, "browse_id");

            var arr = s_arr (o, "results");
            if (arr != null) {
                foreach (unowned Json.Node item in arr.get_elements ()) {
                    if (item.get_node_type () != Json.NodeType.OBJECT) continue;
                    var t = parse_track (item.get_object ());
                    if (t != null) sec.results.add (t);
                }
            }
            return sec;
        }

        public static ArtistData? parse (string json_data) {
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (json_data);
            } catch (Error e) {
                warning ("artist json: %s", e.message);
                return null;
            }

            var rn = parser.get_root ();
            if (rn == null || rn.get_node_type () != Json.NodeType.OBJECT) return null;
            var root = rn.get_object ();

            var d = new ArtistData ();
            d.name = s_str (root, "name") ?? "";
            d.description = s_str (root, "description");
            d.views = s_str (root, "views");
            d.channel_id = s_str (root, "channel_id");
            d.radio_id = s_str (root, "radio_id");
            d.subscribers = s_str (root, "subscribers");
            d.monthly_listeners = s_str (root, "monthly_listeners");
            if (root.has_member ("is_channel") && !root.get_null_member ("is_channel"))
                d.is_channel = root.get_boolean_member ("is_channel");
            if (root.has_member ("subscribed") && !root.get_null_member ("subscribed"))
                d.subscribed = root.get_boolean_member ("subscribed");

            var banners = s_arr (root, "banner");
            if (banners != null) d.banner_url = last_string (banners);
            var thumbs = s_arr (root, "thumbnails");
            if (thumbs != null) d.thumb_url = last_string (thumbs);

            d.songs = parse_song_section (root, "songs");
            d.albums = parse_card_section (root, "albums");
            d.singles = parse_card_section (root, "singles");
            d.videos = parse_card_section (root, "videos");
            d.playlists = parse_card_section (root, "playlists");
            d.featured_on = parse_card_section (root, "featured_on");
            d.related = parse_card_section (root, "related");

            return d;
        }
    }

    [GtkTemplate (ui = "/io/github/fabito02/Timbre/pages/artist.ui")]
    public class ArtistPage : Adw.NavigationPage {
        [GtkChild] private unowned Adw.ViewStack stack;
        [GtkChild] private unowned Gtk.Picture banner_picture;
        [GtkChild] private unowned Gtk.Label label_name;
        [GtkChild] private unowned Gtk.Label label_subscribers;
        [GtkChild] private unowned Gtk.Label label_info;
        [GtkChild] private unowned Gtk.Button button_play;
        [GtkChild] private unowned Gtk.Button button_shuffle;
        [GtkChild] private unowned Gtk.Button button_radio;
        [GtkChild] private unowned Gtk.Button button_subscribe;
        [GtkChild] private unowned Gtk.Label button_subscribe_label;
        [GtkChild] private unowned Gtk.Image button_subscribe_image;
        [GtkChild] private unowned Gtk.Label label_description;
        [GtkChild] private unowned Gtk.Label label_read_more;
        [GtkChild] private unowned Gtk.Box sections_box;

        public signal void track_selected (MediaItem item);
        public signal void collection_selected (MediaItem item);
        public signal void show_all_requested (string browse_id, string? params_json,
                                               string title, GenericArray<HomeItemModel> seed);
        public signal void play_songs_requested (GenericArray<Track> tracks, int start_index, bool shuffle);

        private unowned Timbre.Player player;
        private string channel_id;
        private string? initial_name;
        private ArtistData? data = null;
        private bool is_subscribed = false;
        private bool description_expanded = false;
        private string description_full = "";
        private bool released = false;

        private Timbre.Utils.ImageBinding? banner_binding = null;

        private int song_limit = 5;
        private const int SONG_STEP = 20;
        private const int CARD_LIMIT = 10;
        private const int DESCRIPTION_PREVIEW = 280;

        public ArtistPage (Timbre.Player player, string channel_id, string? initial_name) {
            Object (title: initial_name ?? _("Artist"));

            this.player = player;
            this.channel_id = channel_id;
            this.initial_name = initial_name;

            if (initial_name != null && initial_name.length > 0) {
                this.label_name.label = initial_name;
            }

            this.button_play.clicked.connect (() => this.on_play_clicked (false));
            this.button_shuffle.clicked.connect (() => this.on_play_clicked (true));
            this.button_radio.clicked.connect (this.on_radio_clicked);
            this.button_subscribe.clicked.connect (this.on_subscribe_clicked);

            this.label_read_more.activate_link.connect (() => {
                GLib.Idle.add (() => {
                    this.toggle_description ();
                    return GLib.Source.REMOVE;
                });
                return true;
            });

            this.load ();
        }

        protected override void unroot () {
            this.released = true;
            if (this.banner_binding != null) {
                this.banner_binding.dispose ();
                this.banner_binding = null;
            }
            base.unroot ();
        }

        private void load () {
            this.player.get_artist (this.channel_id, (json, error) => {
                GLib.Idle.add (() => {
                    if (this.released) {
                        if (error != null) Timbre.string_free (error);
                        if (json != null) Timbre.string_free (json);
                        return GLib.Source.REMOVE;
                    }
                    if (error != null) {
                        warning ("artist: %s", (string) error);
                        Timbre.string_free (error);
                        this.stack.visible_child_name = "content";
                        this.label_name.label = this.initial_name ?? _("Artist");
                        return GLib.Source.REMOVE;
                    }
                    var parsed = ArtistParser.parse ((string) json);
                    Timbre.string_free (json);
                    if (parsed != null) {
                        this.data = parsed;
                        this.song_limit = 5;
                        this.populate ();
                    }
                    return GLib.Source.REMOVE;
                });
            });
        }

        private static string section_title (string? backend_title, string fallback) {
            if (backend_title != null && backend_title.length > 0) return backend_title;
            return fallback;
        }

        private void populate () {
            var d = this.data;
            if (d == null) return;

            string name = d.name.length > 0 ? d.name : (this.initial_name ?? _("Unknown Artist"));
            this.label_name.label = name;
            this.title = name;

            string? banner = d.banner_url ?? d.thumb_url;
            if (banner != null && banner.length > 0) {
                if (this.banner_binding == null) {
                    this.banner_binding = new Timbre.Utils.ImageBinding (this.banner_picture, 1024);
                }
                this.banner_binding.load (banner);
            }

            var parts = new GenericArray<string> ();
            if (d.monthly_listeners != null && d.monthly_listeners.length > 0)
                parts.add (d.monthly_listeners);
            if (d.views != null && d.views.length > 0)
                parts.add (d.views);

            var sb = new StringBuilder ();
            for (int i = 0; i < parts.length; i++) {
                if (sb.len > 0) sb.append (" • ");
                sb.append (parts.get (i));
            }
            this.label_info.label = sb.str;
            
            if (d.subscribers != null && d.subscribers.length > 0)
                this.label_subscribers.label = d.subscribers;

            this.set_description (d.description);

            this.is_subscribed = d.subscribed;
            this.update_subscribe_button ();

            bool hide = d.is_channel;
            this.button_play.visible = !hide;
            this.button_shuffle.visible = !hide;
            this.button_radio.visible = !hide;

            this.clear_sections ();

            if (d.songs != null && d.songs.results.length > 0)
                this.add_songs_section (
                    section_title (d.songs.title, _("Top Songs")), d.songs);
            if (d.albums != null && d.albums.results.length > 0)
                this.add_card_section (
                    section_title (d.albums.title, _("Albums")), d.albums);
            if (d.singles != null && d.singles.results.length > 0)
                this.add_card_section (
                    section_title (d.singles.title, _("Singles & EPs")), d.singles);
            if (d.videos != null && d.videos.results.length > 0)
                this.add_card_section (
                    section_title (d.videos.title, _("Videos")), d.videos);
            if (d.playlists != null && d.playlists.results.length > 0)
                this.add_card_section (
                    section_title (d.playlists.title, _("Playlists")), d.playlists);
            if (d.featured_on != null && d.featured_on.results.length > 0)
                this.add_card_section (
                    section_title (d.featured_on.title, _("Featured On")), d.featured_on);
            if (d.related != null && d.related.results.length > 0)
                this.add_card_section (
                    section_title (d.related.title, _("Fans Might Also Like")), d.related);

            this.stack.visible_child_name = "content";
        }

        private void clear_sections () {
            Gtk.Widget? c = this.sections_box.get_first_child ();
            while (c != null) {
                var next = c.get_next_sibling ();
                this.sections_box.remove (c);
                c = next;
            }
        }

        private void set_description (string? raw) {
            if (raw == null || raw.length == 0) {
                this.description_full = "";
                this.description_expanded = false;
                this.label_description.visible = false;
                this.label_read_more.visible = false;
                return;
            }

            var clean = raw.replace ("From Wikipedia", "").strip ();
            while (clean.contains ("  ")) clean = clean.replace ("  ", " ");
            while (clean.contains ("\n\n\n")) clean = clean.replace ("\n\n\n", "\n\n");

            this.description_full = clean;
            this.description_expanded = false;

            if (clean.length > DESCRIPTION_PREVIEW) {
                this.label_description.label = this.preview_of (clean);
                this.label_read_more.label = "<a href='toggle'>" + _("Read more") + "</a>";
                this.label_read_more.visible = true;
            } else {
                this.label_description.label = clean;
                this.label_read_more.visible = false;
            }
            this.label_description.visible = true;
        }

        private string preview_of (string text) {
            int cut = int.min (DESCRIPTION_PREVIEW, text.length);
            string head = text.substring (0, cut);
            int sp = head.last_index_of_char (' ');
            if (sp > 0) head = head.substring (0, sp);
            return head + "…";
        }

        private void toggle_description () {
            if (this.description_full.length == 0) return;
            this.description_expanded = !this.description_expanded;
            if (this.description_expanded) {
                this.label_description.label = this.description_full;
                this.label_read_more.label = "<a href='toggle'>" + _("Show less") + "</a>";
            } else {
                this.label_description.label = this.preview_of (this.description_full);
                this.label_read_more.label = "<a href='toggle'>" + _("Read more") + "</a>";
            }
        }

        private void add_songs_section (string title, ArtistSongSection section) {
            var sec_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);

            var header = new Gtk.Label (title) { halign = Gtk.Align.START };
            header.add_css_class ("heading");
            sec_box.append (header);

            var list = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE };
            list.add_css_class ("boxed-list");
            list.add_css_class ("songs-list");

            int total = section.results.length;
            int visible = int.min (total, this.song_limit);
            for (int i = 0; i < visible; i++) {
                var t = section.results.get (i);
                var row = new Timbre.TrackRow (this.player, t);
                list.append (row);
            }

            list.row_activated.connect ((row) => {
                if (this.released) return;
                int idx = row.get_index ();
                if (idx < 0 || idx >= section.results.length) return;
                var tracks = new GenericArray<Track> ();
                for (int j = 0; j < section.results.length; j++)
                    tracks.add (section.results.get (j));
                this.play_songs_requested (tracks, idx, false);
            });

            sec_box.append (list);

            bool has_more_local = total > visible;
            bool has_more_remote = section.browse_id != null && section.browse_id.length > 0;

            if (has_more_local || has_more_remote) {
                var btn_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
                    halign = Gtk.Align.CENTER,
                    margin_top = 12
                };
                var more = new Gtk.Button.with_label (
                    has_more_local ? _("Load More") : _("Show All"));
                more.add_css_class ("pill");
                btn_box.append (more);

                var spinner = new Adw.Spinner () { visible = false };
                btn_box.append (spinner);

                more.clicked.connect (() => {
                    this.on_load_more_songs (section, spinner, more);
                });

                sec_box.append (btn_box);
            }

            this.sections_box.append (sec_box);
        }

        private void on_load_more_songs (ArtistSongSection section,
                                          Adw.Spinner spinner, Gtk.Button btn) {
            if (section.results.length > this.song_limit) {
                this.song_limit += SONG_STEP;
                this.populate ();
                return;
            }

            if (section.browse_id == null || section.browse_id.length == 0) return;

            spinner.visible = true;
            btn.sensitive = false;

            string bid = section.browse_id;
            this.player.get_playlist (bid, (json, error) => {
                GLib.Idle.add (() => {
                    spinner.visible = false;
                    btn.sensitive = true;

                    if (this.released) {
                        if (error != null) Timbre.string_free (error);
                        if (json != null) Timbre.string_free (json);
                        return GLib.Source.REMOVE;
                    }
                    if (error != null) {
                        warning ("load more: %s", (string) error);
                        Timbre.string_free (error);
                        return GLib.Source.REMOVE;
                    }

                    var full = this.parse_playlist_tracks ((string) json);
                    Timbre.string_free (json);
                    if (full.length == 0) return GLib.Source.REMOVE;

                    var d = this.data;
                    if (d != null && d.songs != null) {
                        d.songs.results = full;
                        d.songs.browse_id = null;
                        this.song_limit = full.length;
                        this.populate ();
                    }
                    return GLib.Source.REMOVE;
                });
            });
        }

        private GenericArray<Track> parse_playlist_tracks (string json_str) {
            var tracks = new GenericArray<Track> ();
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (json_str);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return tracks;
                var obj = root.get_object ();
                if (!obj.has_member ("tracks")) return tracks;

                var arr = obj.get_array_member ("tracks");
                foreach (unowned Json.Node node in arr.get_elements ()) {
                    if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                    var t = ArtistParser.parse_track (node.get_object ());
                    if (t != null) tracks.add (t);
                }
            } catch (Error e) {
                debug ("playlist tracks: %s", e.message);
            }
            return tracks;
        }

        private void add_card_section (string title, ArtistCardSection section) {
            var sec_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);

            var header_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            var header = new Gtk.Label (title) {
                hexpand = true,
                halign = Gtk.Align.START
            };
            header.add_css_class ("title-3");
            header_box.append (header);

            if (section.browse_id != null && section.browse_id.length > 0) {
                var more = new Gtk.Button.from_icon_name ("go-next-symbolic") {
                    tooltip_text = _("Show all"),
                    valign = Gtk.Align.CENTER
                };
                more.add_css_class ("flat");
                more.add_css_class ("circular");
                more.clicked.connect (() => this.emit_show_all (title, section));
                header_box.append (more);
            }

            sec_box.append (header_box);

            var scroll = new Gtk.ScrolledWindow () {
                hscrollbar_policy = Gtk.PolicyType.AUTOMATIC,
                vscrollbar_policy = Gtk.PolicyType.NEVER,
                hexpand = true,
                overlay_scrolling = true
            };

            var strip = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            strip.margin_top = 4;
            strip.margin_bottom = 4;

            int n = section.results.length;
            int limit = int.min (n, CARD_LIMIT);
            for (int i = 0; i < limit; i++) {
                var item = section.results.get (i);
                var card = new Timbre.TrackCard (item);
                card.clicked.connect (() => {
                    if (this.released) return;
                    this.on_card_activated (item);
                });
                strip.append (card);
            }

            scroll.child = strip;
            sec_box.append (scroll);
            this.sections_box.append (sec_box);
        }

        private void on_card_activated (MediaItem item) {
            if (item.kind.is_playable ())
                this.track_selected (item);
            else
                this.collection_selected (item);
        }

        private void emit_show_all (string title, ArtistCardSection section) {
            if (section.browse_id == null) return;
            var seed = new GenericArray<HomeItemModel> ();
            for (int i = 0; i < section.results.length; i++) {
                var item = section.results.get (i);
                var hi = new HomeItemModel ();
                hi.id = item.id;
                hi.kind = item.kind;
                hi.title = item.title;
                hi.thumb = item.thumb;
                hi.duration_seconds = item.duration_seconds;
                hi.explicit = item.explicit;
                hi.is_live = item.is_live;
                for (int j = 0; j < item.artists.length; j++) hi.artists.add (item.artists.get (j));
                seed.add (hi);
            }
            this.show_all_requested (section.browse_id, section.params, title, seed);
        }

        private void on_play_clicked (bool shuffle) {
            if (this.data == null || this.data.songs == null) return;
            var songs = this.data.songs;
            if (songs.results.length == 0) return;
            var tracks = new GenericArray<Track> ();
            for (int i = 0; i < songs.results.length; i++)
                tracks.add (songs.results.get (i));
            this.play_songs_requested (tracks, 0, shuffle);
        }

        private void on_radio_clicked () {
            if (this.data == null || this.data.songs == null) return;
            if (this.data.songs.results.length == 0) return;
            string vid = this.data.songs.results.get (Random.int_range (0, this.data.songs.results.length)).id;

            this.player.get_radio (vid, (json, error) => {
                GLib.Idle.add (() => {
                    if (this.released) {
                        if (error != null) Timbre.string_free (error);
                        if (json != null) Timbre.string_free (json);
                        return GLib.Source.REMOVE;
                    }
                    if (error != null) {
                        warning ("radio: %s", (string) error);
                        Timbre.string_free (error);
                        return GLib.Source.REMOVE;
                    }
                    var tracks = this.parse_radio_tracks ((string) json);
                    Timbre.string_free (json);
                    if (tracks.length > 0)
                        this.play_songs_requested (tracks, 0, false);
                    return GLib.Source.REMOVE;
                });
            });
        }

        private GenericArray<Track> parse_radio_tracks (string json_str) {
            var tracks = new GenericArray<Track> ();
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (json_str);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return tracks;
                var obj = root.get_object ();
                if (!obj.has_member ("tracks")) return tracks;
                var arr = obj.get_array_member ("tracks");
                foreach (unowned Json.Node node in arr.get_elements ()) {
                    if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                    var wrapper = node.get_object ();
                    if (!wrapper.has_member ("track")) continue;
                    var t = ArtistParser.parse_track (wrapper.get_object_member ("track"));
                    if (t != null) tracks.add (t);
                }
            } catch (Error e) {
                debug ("radio parse: %s", e.message);
            }
            return tracks;
        }

        private void on_subscribe_clicked () {
            if (this.channel_id.length == 0) return;
            bool target = !this.is_subscribed;
            this.is_subscribed = target;
            this.update_subscribe_button ();

            string cid = this.channel_id;
            this.player.subscribe_artist (cid, target, (success, error) => {
                if (error != null) Timbre.string_free (error);
                if (!success && !this.released) {
                    this.is_subscribed = !target;
                    this.update_subscribe_button ();
                }
            });
        }

        private void update_subscribe_button () {
            if (this.is_subscribed) {
                this.button_subscribe_image.icon_name = "starred-symbolic";
                this.button_subscribe.tooltip_text = _("Unsubscribe");
                this.button_subscribe_label.label = _("Unsubscribe - ");
                this.button_subscribe.add_css_class ("liked-button");
            } else {
                this.button_subscribe_image.icon_name = "non-starred-symbolic";
                this.button_subscribe.tooltip_text = _("Subscribe");
                this.button_subscribe_label.label = _("Subscribe - ");
                this.button_subscribe.remove_css_class ("liked-button");
            }
        }
    }
}
