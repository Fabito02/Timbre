namespace Timbre {

    public class BannerFadeWrapper : Gtk.Box {
        private bool _fade_active = false;
        public bool fade_active {
            get { return _fade_active; }
            set {
                if (_fade_active != value) {
                    _fade_active = value;
                    this.queue_draw ();
                }
            }
        }

        public double fade_start { get; set; default = 0.55; }

        public BannerFadeWrapper (double start = 0.55) {
            Object (
                    orientation: Gtk.Orientation.VERTICAL,
                    fade_start: start.clamp (0.0, 1.0)
            );

            this.set_overflow (Gtk.Overflow.HIDDEN);
        }

        public override void size_allocate (int width, int height, int baseline) {
            base.size_allocate (width, height, baseline);
            this.queue_draw ();
        }

        public override void snapshot (Gtk.Snapshot snapshot) {
            int w = get_width ();
            int h = get_height ();

            if (!fade_active || w <= 0 || h <= 0) {
                base.snapshot (snapshot);
                return;
            }

            var opaque = Gdk.RGBA () { red = 0, green = 0, blue = 0, alpha = 1.0f };
            var clear = Gdk.RGBA () { red = 0, green = 0, blue = 0, alpha = 0.0f };

            var bounds = Graphene.Rect ().init (0, 0, w, h);
            var start_pt = Graphene.Point ().init (0, 0);
            var end_pt = Graphene.Point ().init (0, h);

            Gsk.ColorStop[] stops = {
                Gsk.ColorStop () { offset = 0.0f, color = opaque },
                Gsk.ColorStop () { offset = (float) fade_start, color = opaque },
                Gsk.ColorStop () { offset = 1.0f, color = clear }
            };

            snapshot.push_mask (Gsk.MaskMode.ALPHA);
            snapshot.append_linear_gradient (bounds, start_pt, end_pt, stops);
            snapshot.pop ();

            var child = this.get_first_child ();
            if (child != null) {
                this.snapshot_child (child, snapshot);
            }

            snapshot.pop ();
        }
    }
}
