namespace Timbre {
    [GtkTemplate (ui = "/io/github/fabito02/Timbre/widgets/theme_selector.ui")]
    public class ThemeSelector : Gtk.Widget {
        [GtkChild] private unowned Gtk.Box box;
        [GtkChild] private unowned Gtk.CheckButton follow;
        [GtkChild] private unowned Gtk.CheckButton light;
        [GtkChild] private unowned Gtk.CheckButton dark;

        static construct {
            set_css_name ("themeselector");
            set_layout_manager_type (typeof (Gtk.BinLayout));
        }

        public ThemeSelector () {
            var style_manager = Adw.StyleManager.get_default ();
            
            style_manager.notify["system-supports-color-schemes"].connect (on_supports_color_schemes_changed);
            style_manager.notify["dark"].connect (on_dark_changed);

            on_supports_color_schemes_changed ();
            on_dark_changed ();
        }

        private void on_supports_color_schemes_changed () {
            var style_manager = Adw.StyleManager.get_default ();
            this.follow.visible = style_manager.system_supports_color_schemes;
        }

        private void on_dark_changed () {
            var style_manager = Adw.StyleManager.get_default ();
            if (style_manager.dark) {
                this.add_css_class ("dark");
            } else {
                this.remove_css_class ("dark");
            }
        }
    }
}
