namespace Timbre {
    public class HomeItemModel : Object {
        public string id { get; set; }
        public string type_name { get; set; }
        public string title { get; set; }
        public string? subtitle { get; set; }
        public string? thumbnail_url { get; set; }
        public uint64 duration_secs { get; set; default = 0; }
    }

    public class HomeSectionModel : Object {
        public string title { get; set; }
        public GenericArray<HomeItemModel> items { get; set; }

        public HomeSectionModel (string title) {
            this.title = title;
            this.items = new GenericArray<HomeItemModel> ();
        }
    }
}
