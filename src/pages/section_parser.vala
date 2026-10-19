namespace Timbre.SectionParser {

    public HomeItemModel? parse_item (Json.Object obj) {
        var item = new HomeItemModel ();

        if (obj.has_member ("kind") && !obj.get_null_member ("kind"))
            item.kind = ItemKind.parse (obj.get_string_member ("kind"));
        if (obj.has_member ("id") && !obj.get_null_member ("id"))
            item.id = obj.get_string_member ("id");
        if (obj.has_member ("title") && !obj.get_null_member ("title"))
            item.title = obj.get_string_member ("title");
        if (obj.has_member ("duration_seconds") && !obj.get_null_member ("duration_seconds"))
            item.duration_seconds = (uint) obj.get_int_member ("duration_seconds");

        if (obj.has_member ("artists") && !obj.get_null_member ("artists")) {
            var artists = obj.get_member ("artists");
            if (artists.get_node_type () == Json.NodeType.ARRAY) {
                foreach (unowned Json.Node a in artists.get_array ().get_elements ()) {
                    if (a.get_node_type () != Json.NodeType.OBJECT) continue;
                    var ao = a.get_object ();
                    var p = new Person ();
                    if (ao.has_member ("name") && !ao.get_null_member ("name"))
                        p.name = ao.get_string_member ("name");
                    if (ao.has_member ("id") && !ao.get_null_member ("id"))
                        p.id = ao.get_string_member ("id");
                    item.artists.add (p);
                }
            }
        }

        if (obj.has_member ("album") && !obj.get_null_member ("album")) {
            var al = obj.get_member ("album");
            if (al.get_node_type () == Json.NodeType.OBJECT) {
                var ao = al.get_object ();
                var named = new Named ();
                if (ao.has_member ("name") && !ao.get_null_member ("name"))
                    named.name = ao.get_string_member ("name");
                if (ao.has_member ("id") && !ao.get_null_member ("id"))
                    named.id = ao.get_string_member ("id");
                item.album = named;
            }
        }

        if (obj.has_member ("description") && !obj.get_null_member ("description"))
            item.description = obj.get_string_member ("description");
        if (obj.has_member ("subscribers") && !obj.get_null_member ("subscribers"))
            item.subscribers = obj.get_string_member ("subscribers");
        if (obj.has_member ("item_type") && !obj.get_null_member ("item_type"))
            item.item_type = obj.get_string_member ("item_type");
        if (obj.has_member ("year") && !obj.get_null_member ("year"))
            item.year = obj.get_string_member ("year");
        if (obj.has_member ("thumb") && !obj.get_null_member ("thumb"))
            item.thumb = obj.get_string_member ("thumb");

        return item;
    }
}
