namespace Timbre.HomeSection {

    private const int SPEED_DIAL_SPACING = 8;
    private const int SPEED_DIAL_BLEED = 8;

    private void attach_binding (Gtk.Picture pic, Timbre.Utils.ImageBinding b) {
        pic.set_data ("timbre-image-binding", b);
    }

    public Gtk.Widget build_header (HomePage page, HomeSectionModel section, bool show_all = false) {
        var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            halign = Gtk.Align.FILL,
            valign = Gtk.Align.CENTER,
            margin_bottom = 4
        };

        if (section.strapline_thumb != null && section.strapline_thumb.length > 0) {
            var class = (section.kind == "hero_dial") ? "home-section-user-cover" : "home-section-artist-cover";
            var pic = new Gtk.Picture () {
                width_request = 32, height_request = 32,
                content_fit = Gtk.ContentFit.COVER,
                valign = Gtk.Align.CENTER,
                css_classes = { class }
            };
            var b = new Timbre.Utils.ImageBinding (pic, 32);
            attach_binding (pic, b);
            header.append (pic);
            b.load (section.strapline_thumb);
        }

        var text_col = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) {
            valign = Gtk.Align.CENTER,
            hexpand = true
        };

        bool has_strapline = section.strapline != null && section.strapline.length > 0;

        if (has_strapline) {
            text_col.append (new Gtk.Label (section.strapline) {
                halign = Gtk.Align.START,
                css_classes = { "title-3" }
            });

            text_col.append (new Gtk.Label (section.title) {
                halign = Gtk.Align.START,
                css_classes = { "caption", "dim-label", "home-section-strapline" }
            });
        } else {
            text_col.append (new Gtk.Label (section.title) {
                halign = Gtk.Align.START,
                css_classes = { "title-3" }
            });
        }

        header.append (text_col);

        if (show_all
            && section.browse_id != null
            && section.browse_id.length > 0) {
            var more = new Gtk.Button.from_icon_name ("go-next-symbolic") {
                halign = Gtk.Align.END,
                valign = Gtk.Align.CENTER,
                tooltip_text = _("Show all"),
                css_classes = { "flat", "circular" }
            };

            string b = section.browse_id;
            string? p = section.params_json;
            string t = section.title;
            var seed = new GenericArray<HomeItemModel> ();
            for (int i = 0; i < section.items.length; i++) {
                seed.add (section.items.get (i));
            }

            more.clicked.connect (() => {
                page.show_all_requested (b, p, t, seed);
            });
            header.append (more);
        }

        return header;
    }

    public void add_section (HomePage page, Gtk.Box parent, HomeSectionModel section) {
        if (section.items.length == 0) return;
        add_card_strip (page, parent, section);
    }

    public void add_speed_dial (HomePage page, Gtk.Box parent,
                                HomeSectionModel section, int rows,
                                string? fixed_title = null) {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        box.append (build_header (page, section, true));

        var scroll_box = new Timbre.Utils.HorizontalScrollBox ();
        scroll_box.add_css_class ("home-speed-scroll");

        var wrap = new Adw.WrapBox () {
            orientation = Gtk.Orientation.VERTICAL,
            line_homogeneous = true,
            line_spacing = SPEED_DIAL_SPACING,
            child_spacing = SPEED_DIAL_SPACING,
            valign = Gtk.Align.START,
            margin_top = SPEED_DIAL_BLEED,
            margin_bottom = SPEED_DIAL_BLEED,
            margin_start = SPEED_DIAL_BLEED,
            margin_end = SPEED_DIAL_BLEED
        };

        for (int i = 0; i < section.items.length; i++) {
            var item = section.items.get (i);
            var tile = new Timbre.HomeSpeedTile (
                item.id, item.kind, item.title,
                item.subtitle ?? "", item.duration_secs,
                item.thumbnail_url
            );

            string i_id = item.id;
            uint64 i_dur = item.duration_secs;
            string i_title = item.title;
            string i_sub = item.subtitle ?? "";
            string? i_thumb = item.thumbnail_url;
            string i_kind = item.kind;

            tile.clicked.connect (() => {
                if (i_kind == "Song" || i_kind == "Video")
                    page.track_selected (i_id, i_dur, i_title, i_sub, i_thumb);
                else
                    page.collection_selected (i_id, i_kind, i_title, i_sub, i_thumb);
            });

            wrap.append (tile);
        }

        scroll_box.set_content (wrap);
        box.append (scroll_box);
        parent.append (box);

        fix_dial_height (wrap, rows);
    }

    private void fix_dial_height (Adw.WrapBox wrap, int rows) {
        var first = wrap.get_first_child ();
        if (first == null) return;

        int min_h, nat_h, min_b, nat_b;
        first.measure (Gtk.Orientation.VERTICAL, -1,
                       out min_h, out nat_h, out min_b, out nat_b);

        if (nat_h > 0) {
            wrap.height_request = rows * nat_h + (rows - 1) * SPEED_DIAL_SPACING;
            return;
        }

        ulong id = 0;
        id = first.notify["height"].connect (() => {
            int h = first.get_height ();
            if (h > 0) {
                wrap.height_request = rows * h + (rows - 1) * SPEED_DIAL_SPACING;
                if (id != 0) {
                    first.disconnect (id);
                    id = 0;
                }
            }
        });
    }

    private void add_card_strip (HomePage page, Gtk.Box parent, HomeSectionModel section) {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        box.append (build_header (page, section, true));

        var scroll_box = new Timbre.Utils.HorizontalScrollBox ();
        scroll_box.add_css_class ("home-card-strip");

        var strip = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        strip.margin_start = SPEED_DIAL_BLEED;
        strip.margin_end = SPEED_DIAL_BLEED;
        strip.margin_top = SPEED_DIAL_BLEED;
        strip.margin_bottom = SPEED_DIAL_BLEED;

        for (int i = 0; i < section.items.length; i++) {
            var item = section.items.get (i);
            var card = new Timbre.TrackCard (
                item.id, item.kind, item.title,
                item.subtitle ?? "", item.thumbnail_url);

            string i_id = item.id;
            uint64 i_dur = item.duration_secs;
            string i_title = item.title;
            string i_sub = item.subtitle ?? "";
            string? i_thumb = item.thumbnail_url;
            string i_kind = item.kind;

            card.clicked.connect (() => {
                if (i_kind == "Song" || i_kind == "Video")
                    page.track_selected (i_id, i_dur, i_title, i_sub, i_thumb);
                else
                    page.collection_selected (i_id, i_kind, i_title, i_sub, i_thumb);
            });

            strip.append (card);
        }

        scroll_box.set_content (strip);
        box.append (scroll_box);
        parent.append (box);
    }
}
