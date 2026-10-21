namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/widgets/theme_selector.ui")]
    public class ThemeSelector : Gtk.Widget {
        [GtkChild] private unowned Gtk.CheckButton follow;

        static construct {
            set_css_name ("themeselector");
            set_layout_manager_type (typeof (Gtk.BinLayout));
        }

        public ThemeSelector () {
            var style_manager = Adw.StyleManager.get_default ();
            style_manager.notify["system-supports-color-schemes"].connect (this.on_supports_color_schemes_changed);
            style_manager.notify["dark"].connect (this.on_dark_changed);

            this.on_supports_color_schemes_changed ();
            this.on_dark_changed ();
        }

        private void on_supports_color_schemes_changed () {
            this.follow.visible = Adw.StyleManager.get_default ().system_supports_color_schemes;
        }

        private void on_dark_changed () {
            if (Adw.StyleManager.get_default ().dark) {
                this.add_css_class ("dark");
            } else {
                this.remove_css_class ("dark");
            }
        }
    }
}
