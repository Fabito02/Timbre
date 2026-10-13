namespace Timbre {
    public class SettingsWindow : Adw.PreferencesDialog {
        private unowned Timbre.Player player;
        private unowned Timbre.HomePage home;
        private string cookies_path;

        public SettingsWindow (Timbre.Player player, string cookies_path, Timbre.HomePage home) {
            this.player = player;
            this.cookies_path = cookies_path;
            this.home = home;
            this.build_ui ();
        }

        private void build_ui () {
            bool connected = GLib.FileUtils.test (this.cookies_path, GLib.FileTest.EXISTS);

            var page = new Adw.PreferencesPage ();

            var account_group = new Adw.PreferencesGroup () {
                title = "YouTube Music",
                description = "Connect your account to access your library and history."
            };

            var login_row = new Adw.ActionRow () {
                title = "Authentication",
                subtitle = connected ? "Connected" : "Log in to access your account."
            };

            var login_btn = new Gtk.Button.with_label (connected ? "Connected" : "Entrar") {
                valign = Gtk.Align.CENTER,
                css_classes = { "suggested-action", "pill" },
                sensitive = !connected
            };

            login_btn.clicked.connect (() => {
                var login_win = new Timbre.LoginWindow (this.player, this.cookies_path);
                login_win.login_completed.connect (() => {
                    login_row.subtitle = "Account connected.";
                    login_btn.label = "Connected";
                    login_btn.sensitive = false;
                    this.home.refresh ();
                });
                login_win.present (this);
            });

            login_row.add_suffix (login_btn);
            account_group.add (login_row);
            page.add (account_group);
            this.add (page);
        }
    }
}
