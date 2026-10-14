namespace Timbre.HomeParser {

    public GenericArray<HomeSectionModel> parse_sections (string json_data) {
        var list = new GenericArray<HomeSectionModel> ();

        var parser = new Json.Parser ();
        try {
            parser.load_from_data (json_data);
        } catch (Error e) {
            warning ("home json: %s", e.message);
            return list;
        }

        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.ARRAY) {
            return list;
        }

        foreach (unowned Json.Node sec_node in root.get_array ().get_elements ()) {
            if (sec_node.get_node_type () != Json.NodeType.OBJECT) continue;
            var sec_obj = sec_node.get_object ();

            string sec_title = sec_obj.has_member ("title") && !sec_obj.get_null_member ("title")
                ? sec_obj.get_string_member ("title") : "";
            var section = new HomeSectionModel (sec_title);

            if (sec_obj.has_member ("kind") && !sec_obj.get_null_member ("kind")) {
                section.kind = sec_obj.get_string_member ("kind");
            }
            if (sec_obj.has_member ("browse_id") && !sec_obj.get_null_member ("browse_id")) {
                section.browse_id = sec_obj.get_string_member ("browse_id");
            }
            if (sec_obj.has_member ("params") && !sec_obj.get_null_member ("params")) {
                section.params_json = sec_obj.get_string_member ("params");
            }
            if (sec_obj.has_member ("strapline") && !sec_obj.get_null_member ("strapline")) {
                section.strapline = sec_obj.get_string_member ("strapline");
            }
            if (sec_obj.has_member ("strapline_thumb") && !sec_obj.get_null_member ("strapline_thumb")) {
                section.strapline_thumb = sec_obj.get_string_member ("strapline_thumb");
            }

            if (!sec_obj.has_member ("items")) {
                list.add (section);
                continue;
            }
            var items_node = sec_obj.get_member ("items");
            if (items_node.get_node_type () != Json.NodeType.ARRAY) {
                list.add (section);
                continue;
            }

            foreach (unowned Json.Node item_node in items_node.get_array ().get_elements ()) {
                if (item_node.get_node_type () != Json.NodeType.OBJECT) continue;
                var item = parse_item (item_node.get_object ());
                if (item != null) section.items.add (item);
            }

            list.add (section);
        }

        return list;
    }

    private HomeItemModel? parse_item (Json.Object obj) {
        var item = new HomeItemModel ();

        if (obj.has_member ("kind") && !obj.get_null_member ("kind"))
            item.kind = obj.get_string_member ("kind");
        if (obj.has_member ("id") && !obj.get_null_member ("id"))
            item.id = obj.get_string_member ("id");
        if (obj.has_member ("title") && !obj.get_null_member ("title"))
            item.title = obj.get_string_member ("title");
        if (obj.has_member ("duration_seconds") && !obj.get_null_member ("duration_seconds"))
            item.duration_secs = (uint64) obj.get_int_member ("duration_seconds");

        if (item.kind == "Playlist"
            && obj.has_member ("description")
            && !obj.get_null_member ("description")) {
            item.subtitle = obj.get_string_member ("description");
        } else if (item.kind == "Artist"
            && obj.has_member ("subscribers")
            && !obj.get_null_member ("subscribers")) {
            item.subtitle = obj.get_string_member ("subscribers");
        } else if (obj.has_member ("artists") && !obj.get_null_member ("artists")) {
            var artists_node = obj.get_member ("artists");
            if (artists_node.get_node_type () == Json.NodeType.ARRAY) {
                var sb = new StringBuilder ();
                foreach (unowned Json.Node a_node in artists_node.get_array ().get_elements ()) {
                    if (a_node.get_node_type () != Json.NodeType.OBJECT) continue;
                    var ao = a_node.get_object ();
                    if (ao.has_member ("name") && !ao.get_null_member ("name")) {
                        if (sb.len > 0) sb.append (", ");
                        sb.append (ao.get_string_member ("name"));
                    }
                }
                if (sb.len > 0) item.subtitle = sb.str;
            }
        } else if (obj.has_member ("description") && !obj.get_null_member ("description")) {
            item.subtitle = obj.get_string_member ("description");
        }

        if (obj.has_member ("thumb") && !obj.get_null_member ("thumb"))
            item.thumbnail_url = obj.get_string_member ("thumb");

        return item;
    }
}
