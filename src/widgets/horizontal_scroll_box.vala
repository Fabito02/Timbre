namespace Timbre.Utils {
    public class HorizontalScrollBox : Gtk.Box {
        private const uint   FRAME_MS      = 16;
        private const double EASE          = 0.15;
        private const double PAGE_FRACTION = 0.8;

        private Gtk.Overlay overlay;
        private Gtk.ScrolledWindow scrolled;
        private Gtk.Button left_btn;
        private Gtk.Button right_btn;

        private bool   hovered   = false;
        private bool   animating = false;
        private double target    = 0.0;
        private uint   anim_id   = 0;

        public HorizontalScrollBox () {
            Object (orientation: Gtk.Orientation.HORIZONTAL, hexpand: true);

            this.overlay = new Gtk.Overlay () {
                hexpand = true,
                vexpand = true
            };
            this.append (this.overlay);

            this.scrolled = new Gtk.ScrolledWindow () {
                hscrollbar_policy = Gtk.PolicyType.AUTOMATIC,
                vscrollbar_policy = Gtk.PolicyType.NEVER,
                hexpand = true,
                vexpand = true
            };
            this.overlay.set_child (this.scrolled);

            this.left_btn = new Gtk.Button.from_icon_name ("go-previous-symbolic") {
                valign = Gtk.Align.CENTER,
                halign = Gtk.Align.START,
                margin_start = 8,
                visible = false,
                can_focus = false
            };
            this.left_btn.add_css_class ("circular");
            this.left_btn.add_css_class ("osd");

            this.right_btn = new Gtk.Button.from_icon_name ("go-next-symbolic") {
                valign = Gtk.Align.CENTER,
                halign = Gtk.Align.END,
                margin_end = 8,
                visible = false,
                can_focus = false
            };
            this.right_btn.add_css_class ("circular");
            this.right_btn.add_css_class ("osd");

            this.overlay.add_overlay (this.left_btn);
            this.overlay.add_overlay (this.right_btn);

            var adj = this.scrolled.hadjustment;
            adj.value_changed.connect (() => this.update_buttons ());
            adj.changed.connect       (() => this.update_buttons ());

            var motion = new Gtk.EventControllerMotion ();
            motion.enter.connect ((x, y) => {
                this.hovered = true;
                this.update_buttons ();
            });
            motion.leave.connect (() => {
                this.hovered = false;
                this.update_buttons ();
            });
            this.add_controller (motion);

            this.left_btn.clicked.connect (() => {
                var a = this.scrolled.hadjustment;
                this.animate_to (double.max (
                    a.value - a.page_size * PAGE_FRACTION, a.lower));
            });
            this.right_btn.clicked.connect (() => {
                var a = this.scrolled.hadjustment;
                this.animate_to (double.min (
                    a.value + a.page_size * PAGE_FRACTION,
                    a.upper - a.page_size));
            });

            var scroll = new Gtk.EventControllerScroll (
                Gtk.EventControllerScrollFlags.VERTICAL);
            scroll.scroll.connect ((dx, dy) => {
                var state = scroll.get_current_event_state ();
                if ((state & Gdk.ModifierType.SHIFT_MASK) == 0) return false;

                var a = this.scrolled.hadjustment;
                double step = a.page_size * 0.15;
                double max = double.max (a.lower, a.upper - a.page_size);
                a.value = (a.value - dy * step).clamp (a.lower, max);
                return true;
            });
            this.add_controller (scroll);

            var hscroll = new Gtk.EventControllerScroll (
                Gtk.EventControllerScrollFlags.HORIZONTAL);
            this.add_controller (hscroll);
        }

        public void set_content (Gtk.Widget child) {
            this.scrolled.child = child;
            GLib.Idle.add (() => {
                this.update_buttons ();
                return GLib.Source.REMOVE;
            });
        }

        public Gtk.Adjustment hadjustment {
            get { return this.scrolled.hadjustment; }
        }

        private void animate_to (double t) {
            this.target = t;
            if (this.animating) return;

            this.animating = true;
            this.anim_id = GLib.Timeout.add (FRAME_MS, () => {
                var adj = this.scrolled.hadjustment;
                double diff = this.target - adj.value;
                if (Math.fabs (diff) < 2.0) {
                    adj.value = this.target;
                    this.animating = false;
                    this.anim_id = 0;
                    return GLib.Source.REMOVE;
                }
                adj.value = adj.value + diff * EASE;
                return GLib.Source.CONTINUE;
            });
        }

        private void update_buttons () {
            if (!this.hovered) {
                this.left_btn.visible = false;
                this.right_btn.visible = false;
                return;
            }
            var adj = this.scrolled.hadjustment;
            this.left_btn.visible  = adj.value > adj.lower + 1.0;
            this.right_btn.visible = adj.value + adj.page_size < adj.upper - 1.0;
        }

        public override void dispose () {
            if (this.anim_id != 0) {
                GLib.Source.remove (this.anim_id);
                this.anim_id = 0;
            }
            base.dispose ();
        }
    }
}
