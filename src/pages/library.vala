namespace Timbre {

    [GtkTemplate (ui = "/io/github/fabito02/Timbre/pages/library.ui")]
    public class LibraryPage : Adw.NavigationPage {

        [GtkChild] private unowned Gtk.Stack stack;
        [GtkChild] private unowned Gtk.Box content_box;
        [GtkChild] private unowned Adw.StatusPage status_page;

        private unowned Timbre.Player? player = null;

        public LibraryPage () {
            Object ();
            this.stack.visible_child_name = "placeholder";
        }

        public void set_player (Timbre.Player player) {
            this.player = player;
        }

        public void show_content () {
            this.stack.visible_child_name = "content";
        }

        public void show_placeholder () {
            this.stack.visible_child_name = "placeholder";
        }

        public void set_status (string icon, string title, string description) {
            this.status_page.icon_name = icon;
            this.status_page.title = title;
            this.status_page.description = description;
            this.stack.visible_child_name = "status";
        }

        public void clear_content () {
            Gtk.Widget? child = this.content_box.get_first_child ();
            while (child != null) {
                var next = child.get_next_sibling ();
                this.content_box.remove (child);
                child = next;
            }
        }

        public void add_widget (Gtk.Widget widget) {
            this.content_box.append (widget);
        }
    }
}
