/* application.vala
 *
 * Copyright 2026 Unknown
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

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
        this.cookies_path = GLib.Path.build_filename (config_dir, "cookies.txt");

        if (GLib.FileUtils.test (this.cookies_path, GLib.FileTest.EXISTS)) {
            try {
                string cookie_data;
                GLib.FileUtils.get_contents (this.cookies_path, out cookie_data);
                if (cookie_data.strip ().length > 0) {
                    this._player.login (cookie_data.strip (), this.cookies_path);
                }
            } catch (Error e) {
                warning ("Error loading cookies: %s", e.message);
            }
        }

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
            string scheme_val = state.get_string ();
            var style_manager = Adw.StyleManager.get_default ();

            if (scheme_val == "light") {
                style_manager.color_scheme = Adw.ColorScheme.FORCE_LIGHT;
            } else if (scheme_val == "dark") {
                style_manager.color_scheme = Adw.ColorScheme.FORCE_DARK;
            } else {
                style_manager.color_scheme = Adw.ColorScheme.DEFAULT;
            }
        });
        this.add_action (theme_action);

        this.set_accels_for_action ("app.quit", { "<Primary>q" });
        this.set_accels_for_action ("app.preferences", { "<Primary>comma" });
        this.set_accels_for_action ("win.show-help-overlay", { "<Primary>question", "F1" });
    }

    public override void activate () {
        base.activate ();
        
        typeof (Timbre.ThemeSelector).ensure ();
        
        var win = this.active_window ?? new Timbre.Window (this);
        win.present ();
    }

    private void on_about_action () {
        string[] developers = { "Fabito02" };
        var about = new Adw.AboutDialog () {
            application_name = "Timbre",
            application_icon = "io.github.fabito02.Timbre",
            developer_name = "Fabito02",
            translator_credits = _("translator-credits"),
            version = "0.1.0",
            developers = developers,
            copyright = "© 2026 Fabito02",
        };

        about.present (this.active_window);
    }

    private void on_preferences_action () {
        var settings_win = new Timbre.SettingsWindow (this._player, this.cookies_path);
        settings_win.present (this.active_window);
    }
}
