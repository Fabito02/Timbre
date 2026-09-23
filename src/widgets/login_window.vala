namespace Timbre {

    public class LoginWindow : Adw.Dialog {
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

            build_ui ();
            setup_webview ();
        }

        private void build_ui () {
            var main_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            var header_bar = new Adw.HeaderBar ();

            webview_container = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
                hexpand = true,
                vexpand = true
            };

            main_box.append (header_bar);
            main_box.append (webview_container);

            this.child = main_box;
        }

        private void setup_webview () {
            webview = new WebKit.WebView ();
            var settings = webview.get_settings ();
            settings.user_agent = "Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0";

            webview.hexpand = true;
            webview.vexpand = true;
            webview.load_changed.connect (on_load_changed);

            webview_container.append (webview);
            webview.load_uri ("https://accounts.google.com/ServiceLogin?continue=https://music.youtube.com");
        }

        private void on_load_changed (WebKit.LoadEvent load_event) {
            if (load_event != WebKit.LoadEvent.FINISHED) return;
            string uri = webview.get_uri ();

            if ("music.youtube.com" in uri && !("accounts.google.com" in uri)) {
                extract_cookies_and_finish ();
            }
        }

        private void extract_cookies_and_finish () {
            var network_session = webview.get_network_session ();
            var cookie_manager = network_session.get_cookie_manager ();

            cookie_manager.get_cookies.begin ("https://music.youtube.com", null, (obj, res) => {
                try {
                    GLib.List<Soup.Cookie> cookies = cookie_manager.get_cookies.end (res);
                    var builder = new StringBuilder ();

                    foreach (unowned Soup.Cookie cookie in cookies) {
                        builder.append_printf ("%s=%s; ", cookie.get_name (), cookie.get_value ());
                    }

                    string cookie_header = builder.str;

                    if (cookie_header.length > 0) {
                        GLib.FileUtils.set_contents (this.cookies_path, cookie_header);

                        this.player.login (cookie_header, this.cookies_path);
                        login_completed ();
                        this.close ();
                    }
                } catch (Error e) {
                    warning ("Failed to extract cookies: %s", e.message);
                }
            });
        }
    }
}
