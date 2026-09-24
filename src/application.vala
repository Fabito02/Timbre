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

        // Registered here, not in startup: the command line is parsed
        // between the constructor and startup, so --debug would be
        // rejected before handle_local_options ever ran.
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

        this._player = new Timbre.Player ();

        string config_dir = GLib.Path.build_filename (GLib.Environment.get_user_config_dir (), "timbre");
        GLib.DirUtils.create_with_parents (config_dir, 0755);
        this.cookies_path = GLib.Path.build_filename (config_dir, "headers_auth.json");

        setup_actions ();
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
        var win = this.active_window ?? new Timbre.Window (this);
        win.present ();
    }

    private void on_about_action () {
        var about = new Adw.AboutDialog () {
            application_name = "Timbre",
            application_icon = "io.github.fabito02.Timbre",
            developer_name = "Fabito02",
            translator_credits = _("translator-credits"),
            version = "0.1.0",
            developers = { "Fabito02" },
            copyright = "© 2026 Fabito02",
        };
        about.present (this.active_window);
    }

    private void on_preferences_action () {
        var settings_win = new Timbre.SettingsWindow (this._player, this.cookies_path);
        settings_win.present (this.active_window);
    }
}
