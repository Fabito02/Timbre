namespace Timbre {
    public class HomeItemModel : MediaItem {
        public HomeItemModel () {
            base ();
        }
    }

    public class HomeSectionModel : Object {
        public string title { get; set; default = ""; }
        public string? browse_id { get; set; default = null; }
        public string? params_json { get; set; default = null; }
        public string? strapline { get; set; default = null; }
        public string? strapline_thumb { get; set; default = null; }
        public string kind { get; set; default = ""; }
        public GenericArray<HomeItemModel> items { get; set; }

        public HomeSectionModel (string title) {
            this.title = title;
            this.items = new GenericArray<HomeItemModel> ();
        }
    }
}
