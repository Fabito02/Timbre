public class Timbre.Application : Adw.Application {
    private Timbre.Player _player;
    public string cookies_path { get; private set; default = ""; }

    public unowned Timbre.Player get_player () {
        return this._player;
    }

    public Application () {
        Object (
            application_id: "io.github.fabito02.Timbre",
            flags: ApplicationFlags.DEFAULT_FLAGS,
            resource_base_path: "/io/github/fabito02/Timbre"
        );

        this.add_main_option (
            "debug",
            'd',
            GLib.OptionFlags.NONE,
            GLib.OptionArg.NONE,
            "Enable debug logging on stderr",
            null
        );
    }

    protected override int handle_local_options (GLib.VariantDict options) {
        Timbre.set_log_level (options.contains ("debug") ? 2 : 1);
        return -1;
    }

    protected override void startup () {
        base.startup ();

        var provider = new Gtk.CssProvider ();
        provider.load_from_resource ("/io/github/fabito02/Timbre/style.css");
        Gtk.StyleContext.add_provider_for_display (
            Gdk.Display.get_default (),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        );

        string hl = detect_hl ();
        string gl = detect_gl ();
        message ("locale: hl=%s gl=%s", hl, gl);
        Timbre.set_locale (hl, gl);

        this._player = new Timbre.Player ();

        string data_dir = GLib.Path.build_filename (GLib.Environment.get_user_data_dir (), "timbre");
        GLib.DirUtils.create_with_parents (data_dir, 0755);
        this.cookies_path = GLib.Path.build_filename (data_dir, "headers_auth.json");

        this.restore_image_auth ();

        setup_actions ();
    }

    // Locale
    private string detect_hl () {
        unowned string[] names = Intl.get_language_names ();
        if (names.length == 0) return "en";
        string first = names[0];
        if (first == "C" || first == "POSIX" || first.has_prefix ("C.")) return "en";

        int dot = first.index_of_char ('.');
        if (dot >= 0) first = first.substring (0, dot);
        return first.replace ("_", "-");
    }

    private string detect_gl () {
        string hl = detect_hl ();
        int dash = hl.index_of_char ('-');
        if (dash >= 0 && hl.length > dash + 1) {
            return hl.substring (dash + 1).up ();
        }
        return "";
    }

    private void restore_image_auth () {
        if (!GLib.FileUtils.test (this.cookies_path, GLib.FileTest.EXISTS)) return;

        try {
            var file = GLib.File.new_for_path (this.cookies_path);
            uint8[] raw;
            string etag;
            if (!file.load_contents (null, out raw, out etag)) return;
            if (raw.length == 0) return;

            string json_str = (string) raw;

            var parser = new Json.Parser ();
            parser.load_from_data (json_str);

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return;

            var obj = root.get_object ();
            if (obj.has_member ("Cookie") && !obj.get_null_member ("Cookie")) {
                Timbre.Utils.ImageLoader.get_default ().set_auth_cookie (
                    obj.get_string_member ("Cookie"));
            }
        } catch (Error e) {
            debug ("restore_image_auth: %s", e.message);
        }
    }

    private void setup_actions () {
        var quit_action = new SimpleAction ("quit", null);
        quit_action.activate.connect (() => { this.quit (); });
        this.add_action (quit_action);

        var prefs_action = new SimpleAction ("preferences", null);
        prefs_action.activate.connect (on_preferences_action);
        this.add_action (prefs_action);

        var about_action = new SimpleAction ("about", null);
        about_action.activate.connect (on_about_action);
        this.add_action (about_action);

        var theme_action = new SimpleAction.stateful (
            "color-scheme",
            VariantType.STRING,
            new Variant.string ("default")
        );
        theme_action.change_state.connect ((action, state) => {
            action.set_state (state);
            var style_manager = Adw.StyleManager.get_default ();
            switch (state.get_string ()) {
                case "light": style_manager.color_scheme = Adw.ColorScheme.FORCE_LIGHT; break;
                case "dark":  style_manager.color_scheme = Adw.ColorScheme.FORCE_DARK;  break;
                default:      style_manager.color_scheme = Adw.ColorScheme.DEFAULT;    break;
            }
        });
        this.add_action (theme_action);

        this.set_accels_for_action ("app.quit", { "<Primary>q" });
        this.set_accels_for_action ("app.preferences", { "<Primary>comma" });
        this.set_accels_for_action ("app.win.show-help-overlay", { "<Primary>question", "F1" });
    }

    public override void activate () {
        base.activate ();

        typeof (Timbre.ThemeSelector).ensure ();

        var win = this.active_window;
        if (win == null) {
            win = new Timbre.Window (this);
        }

        win.set_visible (true);
        win.present ();
        win.present_with_time (Gdk.CURRENT_TIME);
    }

    private void on_about_action () {
        var about = new Adw.AboutDialog () {
            application_name = "Timbre",
            application_icon = "io.github.fabito02.Timbre",
            developer_name = "Fabito02",
            version = "0.1.0",
            developers = { "Fabiano Júnior Lima Barbosa https://github.com/Fabito02" },
            copyright = "© 2026 Fabiano Júnior Lima Barbosa",
            license_type = Gtk.License.GPL_3_0,
            website = "https://github.com/Fabito02/Timbre",
            issue_url = "https://github.com/Fabito02/Timbre/issues",
            translator_credits = _("translator-credits"),
        };
        about.present (this.active_window);
    }

    private void on_preferences_action () {
        var settings_win = new Timbre.SettingsWindow (this._player, this.cookies_path);
        settings_win.present (this.active_window);
    }
}
