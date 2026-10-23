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

        private double _fade_start = 0.35;
        public double fade_start {
            get { return _fade_start; }
            set {
                var v = value.clamp (0.0, 1.0);
                if (_fade_start != v) {
                    _fade_start = v;
                    this.queue_draw ();
                }
            }
        }

        public BannerFadeWrapper (double start = 0.35) {
            Object (orientation: Gtk.Orientation.VERTICAL);
            this._fade_start = start.clamp (0.0, 1.0);
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

            var bounds = Graphene.Rect ().init (0, 0, w, h);
            var start_pt = Graphene.Point ().init (0, 0);
            var end_pt = Graphene.Point ().init (0, h);

            Gsk.ColorStop[] stops = {
                { 0.00f, mask_color (1.00f) },
                { 0.35f, mask_color (1.00f) },
                { 0.55f, mask_color (0.80f) },
                { 0.75f, mask_color (0.40f) },
                { 0.85f, mask_color (0.15f) },
                { 0.95f, mask_color (0.00f) },
                { 1.00f, mask_color (0.00f) }
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

        private static Gdk.RGBA mask_color (float alpha) {
            return Gdk.RGBA () {
                       red = 1.0f,
                       green = 1.0f,
                       blue = 1.0f,
                       alpha = alpha
            };
        }
    }
}
