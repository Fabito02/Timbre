namespace Timbre {
    public class HomeItemModel : Object {
        public string id { get; set; default = ""; }
        public string kind { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public string? subtitle { get; set; default = null; }
        public string? thumbnail_url { get; set; default = null; }
        public uint64 duration_secs { get; set; default = 0; }

        public bool is_playable () {
            return this.kind == "Song" || this.kind == "Video";
        }
    }

    public class HomeSectionModel : Object {
        public string title { get; set; default = ""; }
        public string kind { get; set; default = ""; }
        public string? browse_id { get; set; default = null; }
        public string? params_json { get; set; default = null; }
        public string? strapline { get; set; default = null; }
        public string? strapline_thumb { get; set; default = null; }
        public GenericArray<HomeItemModel> items { get; set; }

        public HomeSectionModel (string title) {
            this.title = title;
            this.items = new GenericArray<HomeItemModel> ();
        }
    }
}
