namespace Timbre {
    public class LoginWindow : Adw.Dialog {
        private const string USER_AGENT =
            "Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0";

        private Gtk.Box webview_container;
        private WebKit.WebView webview;
        private unowned Timbre.Player player;
        private string cookies_path;

        public signal void login_completed ();

        public LoginWindow (Timbre.Player player, string cookies_path) {
            this.title = "Sign in to YouTube Music";
            this.content_width = 500;
            this.content_height = 650;
            this.player = player;
            this.cookies_path = cookies_path;

            this.build_ui ();
            this.setup_webview ();
        }

        private void build_ui () {
            var main_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            main_box.append (new Adw.HeaderBar ());

            this.webview_container = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
                hexpand = true,
                vexpand = true
            };
            main_box.append (this.webview_container);

            this.child = main_box;
        }

        private void setup_webview () {
            this.webview = new WebKit.WebView ();
            this.webview.get_settings ().user_agent = USER_AGENT;
            this.webview.hexpand = true;
            this.webview.vexpand = true;
            this.webview.load_changed.connect (this.on_load_changed);
            this.webview_container.append (this.webview);
            this.webview.load_uri ("https://accounts.google.com/ServiceLogin?continue=https://music.youtube.com");
        }

        private void on_load_changed (WebKit.LoadEvent event) {
            if (event != WebKit.LoadEvent.FINISHED) return;
            string uri = this.webview.get_uri ();
            if ("music.youtube.com" in uri && !("accounts.google.com" in uri)) {
                this.extract_cookies_and_finish ();
            }
        }

        private void extract_cookies_and_finish () {
            var cookies = this.webview.get_network_session ().get_cookie_manager ();

            cookies.get_cookies.begin ("https://music.youtube.com", null, (obj, res) => {
                try {
                    GLib.List<Soup.Cookie> list = cookies.get_cookies.end (res);
                    var sb = new StringBuilder ();
                    foreach (unowned Soup.Cookie c in list) {
                        sb.append_printf ("%s=%s; ", c.get_name (), c.get_value ());
                    }

                    string header = sb.str.strip ();
                    if (header.length == 0) return;

                    var jb = new Json.Builder ();
                    jb.begin_object ();
                    jb.set_member_name ("Cookie");
                    jb.add_string_value (header);
                    jb.set_member_name ("User-Agent");
                    jb.add_string_value (USER_AGENT);
                    jb.end_object ();

                    var gen = new Json.Generator ();
                    gen.set_root (jb.get_root ());
                    GLib.FileUtils.set_contents (this.cookies_path, gen.to_data (null));

                    Timbre.Utils.ImageLoader.get_default ().set_auth_cookie (header);

                    this.player.login (this.cookies_path, (success, error) => {
                        Idle.add (() => {
                            if (!success) {
                                if (error != null) {
                                    warning ("login: %s", (string) error);
                                    Timbre.string_free (error);
                                }
                                return GLib.Source.REMOVE;
                            }
                            this.login_completed ();
                            this.close ();
                            return GLib.Source.REMOVE;
                        });
                    });
                } catch (Error e) {
                    warning ("Failed to extract cookies: %s", e.message);
                }
            });
        }
    }
}
