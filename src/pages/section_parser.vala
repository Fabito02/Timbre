namespace Timbre.SectionParser {

    public HomeItemModel? parse_item (Json.Object obj) {
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
            var artists = obj.get_member ("artists");
            if (artists.get_node_type () == Json.NodeType.ARRAY) {
                var sb = new StringBuilder ();
                foreach (unowned Json.Node a in artists.get_array ().get_elements ()) {
                    if (a.get_node_type () != Json.NodeType.OBJECT) continue;
                    var ao = a.get_object ();
                    if (ao.has_member ("name") && !ao.get_null_member ("name")) {
                        if (sb.len > 0) sb.append (", ");
                        sb.append (ao.get_string_member ("name"));
                    }
                }
                if (sb.len > 0) item.subtitle = sb.str;
            }
        }

        if (item.subtitle == null && obj.has_member ("subscribers") && !obj.get_null_member ("subscribers"))
            item.subtitle = obj.get_string_member ("subscribers");
        if (item.subtitle == null && obj.has_member ("item_type") && !obj.get_null_member ("item_type"))
            item.subtitle = obj.get_string_member ("item_type");
        if (item.subtitle == null && obj.has_member ("description") && !obj.get_null_member ("description"))
            item.subtitle = obj.get_string_member ("description");

        if (obj.has_member ("thumb") && !obj.get_null_member ("thumb"))
            item.thumbnail_url = obj.get_string_member ("thumb");

        return item;
    }
}
