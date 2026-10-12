use std::sync::Arc;

use serde::Serialize;
use serde_json::{Value, json};

use super::browse::Browse;
use super::items::{
    MRLIR, MTRIR, THUMBNAIL_RENDERER, THUMBNAILS, array_at, detect_kind, is_year,
    last_thumbnail_url, owned_at, parse_album_card, parse_song_row, parse_video_card, str_at,
};
use crate::net::NetError;
use crate::net::media::{ItemKind, MediaItem, Person};

const SECTIONS: &str = "/contents/singleColumnBrowseResultsRenderer/tabs/0/tabRenderer/content/sectionListRenderer/contents";
const CAROUSEL_BROWSE_ID: &str = "/musicCarouselShelfRenderer/header/musicCarouselShelfBasicHeaderRenderer/title/runs/0/navigationEndpoint/browseEndpoint/browseId";
const CAROUSEL_TITLE: &str = "/header/musicCarouselShelfBasicHeaderRenderer/title/runs/0/text";
const CUSTOM_INDEX: &str = "/customIndexColumn/musicCustomIndexColumnRenderer";

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Category {
    pub title: String,
    pub params: String,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct ExploreFeed {
    pub new_releases: Vec<MediaItem>,
    pub new_videos: Vec<MediaItem>,
    pub trending: Vec<MediaItem>,
    pub moods_and_genres: Vec<Category>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub enum Trend {
    Up,
    Down,
    #[default]
    Neutral,
}

#[derive(Clone, Debug, Serialize)]
pub struct ChartArtist {
    pub item: MediaItem,
    pub rank: Option<String>,
    pub trend: Trend,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Charts {
    pub countries: Vec<String>,
    pub videos: Vec<MediaItem>,
    pub daily: Vec<MediaItem>,
    pub weekly: Vec<MediaItem>,
    pub genres: Vec<MediaItem>,
    pub artists: Vec<ChartArtist>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct ExploreData {
    pub feed: ExploreFeed,
    pub for_you: Vec<Category>,
    pub moods: Vec<Category>,
    pub genres: Vec<Category>,
    pub charts: Option<Charts>,
}

#[derive(Clone, Debug, Serialize)]
pub struct CategorySection {
    pub title: String,
    pub items: Vec<MediaItem>,
}

pub async fn load_explore(api: Arc<dyn Browse>, country: String) -> Result<ExploreData, NetError> {
    let categories = {
        let api = api.clone();
        tokio::spawn(async move { get_mood_categories(&api).await })
    };
    let charts = {
        let api = api.clone();
        tokio::spawn(async move { get_charts(&api, &country).await })
    };

    let mut data = ExploreData {
        feed: get_explore(&api).await?,
        ..ExploreData::default()
    };
    match categories.await {
        Ok(Ok(sections)) => {
            data.for_you = section(&sections, "For you");
            data.moods = section(&sections, "Moods & moments");
            data.genres = section(&sections, "Genres");
        }
        Ok(Err(err)) => tracing::warn!(%err, "mood categories failed"),
        Err(_) => {}
    }
    match charts.await {
        Ok(Ok(charts)) => data.charts = Some(charts),
        Ok(Err(err)) => tracing::warn!(%err, "charts failed"),
        Err(_) => {}
    }
    Ok(data)
}

pub async fn get_explore(api: &dyn Browse) -> Result<ExploreFeed, NetError> {
    let response = api
        .post("browse", json!({ "browseId": "FEmusic_explore" }))
        .await?;
    Ok(parse_explore(&response))
}

pub async fn get_mood_categories(
    api: &dyn Browse,
) -> Result<Vec<(String, Vec<Category>)>, NetError> {
    let response = api
        .post("browse", json!({ "browseId": "FEmusic_moods_and_genres" }))
        .await?;
    Ok(parse_mood_categories(&response))
}

pub async fn get_charts(api: &dyn Browse, country: &str) -> Result<Charts, NetError> {
    let mut body = json!({ "browseId": "FEmusic_charts" });
    if !country.is_empty() {
        body["formData"] = json!({ "selectedValues": [country] });
    }
    let response = api.post("browse", body).await?;
    Ok(parse_charts(&response, country))
}

pub async fn get_category_page(
    api: &dyn Browse,
    params: &str,
) -> Result<Vec<CategorySection>, NetError> {
    let body = json!({ "browseId": "FEmusic_moods_and_genres_category", "params": params });
    let response = api.post("browse", body).await?;
    Ok(parse_category_page(&response))
}

pub fn section(sections: &[(String, Vec<Category>)], name: &str) -> Vec<Category> {
    sections
        .iter()
        .find(|(title, _)| title == name)
        .map(|(_, items)| items.clone())
        .unwrap_or_default()
}

pub fn parse_explore(response: &Value) -> ExploreFeed {
    let mut feed = ExploreFeed::default();
    for shelf in array_at(response, SECTIONS) {
        let Some(browse_id) = str_at(shelf, CAROUSEL_BROWSE_ID) else {
            continue;
        };
        let contents = array_at(shelf, "/musicCarouselShelfRenderer/contents");
        match browse_id {
            "FEmusic_new_releases_albums" => {
                feed.new_releases = contents
                    .iter()
                    .filter_map(|c| c.get(MTRIR))
                    .map(parse_album_card)
                    .collect();
            }
            "FEmusic_new_releases_videos" => {
                feed.new_videos = contents
                    .iter()
                    .filter_map(|c| c.get(MTRIR))
                    .filter_map(parse_video_card)
                    .collect();
            }
            "FEmusic_moods_and_genres" => {
                feed.moods_and_genres = contents.iter().filter_map(parse_category).collect();
            }
            id if id.starts_with("VLOLA") => {
                feed.trending = contents
                    .iter()
                    .filter_map(|c| c.get(MRLIR))
                    .filter_map(|row| parse_song_row(row, "Trending"))
                    .collect();
            }
            _ => {}
        }
    }
    feed
}

pub fn parse_mood_categories(response: &Value) -> Vec<(String, Vec<Category>)> {
    array_at(response, SECTIONS)
        .iter()
        .filter_map(|shelf| {
            let title = owned_at(
                shelf,
                "/gridRenderer/header/gridHeaderRenderer/title/runs/0/text",
            )?;
            let items = array_at(shelf, "/gridRenderer/items")
                .iter()
                .filter_map(parse_category)
                .collect();
            Some((title, items))
        })
        .collect()
}

pub fn parse_charts(response: &Value, country: &str) -> Charts {
    let shelves = array_at(response, SECTIONS);
    let mut charts = Charts {
        countries: array_at(response, "/frameworkUpdates/entityBatchUpdate/mutations")
            .iter()
            .filter_map(|m| owned_at(m, "/payload/musicFormBooleanChoice/opaqueToken"))
            .collect(),
        ..Charts::default()
    };

    let mut names: Vec<&str> = vec!["videos"];
    if country == "US" {
        names.push("genres");
    }
    names.push("artists");
    if shelves.len().saturating_sub(1) > names.len() {
        names.splice(0..1, ["daily", "weekly"]);
    }

    for (i, name) in names.iter().enumerate() {
        let Some(shelf) = shelves.get(i + 1) else {
            continue;
        };
        let contents = array_at(shelf, "/musicCarouselShelfRenderer/contents");
        if *name == "artists" {
            charts.artists = contents
                .iter()
                .filter_map(|c| c.get(MRLIR))
                .map(parse_chart_artist)
                .collect();
            continue;
        }
        let playlists: Vec<MediaItem> = contents
            .iter()
            .filter_map(|c| c.get(MTRIR))
            .filter_map(parse_chart_playlist)
            .collect();
        match *name {
            "daily" => charts.daily = playlists,
            "weekly" => charts.weekly = playlists,
            "genres" => charts.genres = playlists,
            _ => charts.videos = playlists,
        }
    }
    charts
}

pub fn parse_category_page(response: &Value) -> Vec<CategorySection> {
    array_at(response, SECTIONS)
        .iter()
        .filter_map(|shelf| {
            let carousel = shelf.get("musicCarouselShelfRenderer")?;
            let title = owned_at(carousel, CAROUSEL_TITLE)?;
            let items: Vec<MediaItem> = array_at(carousel, "/contents")
                .iter()
                .filter_map(|entry| parse_category_item(entry, &title))
                .collect();
            (!items.is_empty()).then_some(CategorySection { title, items })
        })
        .collect()
}

fn parse_category_item(entry: &Value, section_title: &str) -> Option<MediaItem> {
    let (renderer, title, endpoint, thumbs, subtitle_runs) =
        match (entry.get(MRLIR), entry.get(MTRIR)) {
            (Some(r), _) => {
                let column = "/flexColumns/0/musicResponsiveListItemFlexColumnRenderer/text/runs/0";
                let endpoint = r
                    .pointer("/navigationEndpoint")
                    .or_else(|| r.pointer(&format!("{column}/navigationEndpoint")));
                (
                    r,
                    owned_at(r, &format!("{column}/text"))?,
                    endpoint,
                    THUMBNAILS,
                    "/flexColumns/1/musicResponsiveListItemFlexColumnRenderer/text/runs",
                )
            }
            (None, Some(r)) => {
                let endpoint = r
                    .pointer("/navigationEndpoint")
                    .or_else(|| r.pointer("/title/runs/0/navigationEndpoint"));
                (
                    r,
                    owned_at(r, "/title/runs/0/text")?,
                    endpoint,
                    THUMBNAIL_RENDERER,
                    "/subtitle/runs",
                )
            }
            (None, None) => return None,
        };

    let mut item = MediaItem {
        title,
        thumb: last_thumbnail_url(array_at(renderer, thumbs)),
        ..MediaItem::default()
    };
    for run in array_at(renderer, subtitle_runs) {
        let page_type = str_at(
            run,
            "/navigationEndpoint/browseEndpoint/browseEndpointContextSupportedConfigs/browseEndpointContextMusicConfig/pageType",
        );
        match page_type {
            Some("MUSIC_PAGE_TYPE_ARTIST") => item.artists.push(Person {
                name: str_at(run, "/text").unwrap_or_default().to_owned(),
                id: owned_at(run, "/navigationEndpoint/browseEndpoint/browseId"),
            }),
            Some(_) => {}
            None => {
                let text = str_at(run, "/text").unwrap_or_default().trim();
                if is_year(text) {
                    item.year = Some(text.to_owned());
                } else if ["Album", "Single", "EP", "Playlist"].contains(&text) {
                    item.item_type = Some(text.to_owned());
                }
            }
        }
    }

    let endpoint = endpoint?;
    if let Some(video_id) = owned_at(endpoint, "/watchEndpoint/videoId") {
        let video_type = str_at(
            endpoint,
            "/watchEndpoint/watchEndpointMusicSupportedConfigs/watchEndpointMusicConfig/musicVideoType",
        );
        item.kind = detect_kind(video_type, item.thumb.as_deref(), section_title, &item)?;
        item.id = video_id;
    } else {
        let browse_id = owned_at(endpoint, "/browseEndpoint/browseId")?;
        item.kind = if browse_id.starts_with("MPRE") {
            ItemKind::Album
        } else if browse_id.starts_with("UC") {
            ItemKind::Artist
        } else {
            ItemKind::Playlist
        };
        item.id = if item.kind == ItemKind::Playlist {
            browse_id.trim_start_matches("VL").to_owned()
        } else {
            browse_id
        };
    }
    Some(item)
}

fn parse_category(entry: &Value) -> Option<Category> {
    Some(Category {
        title: owned_at(
            entry,
            "/musicNavigationButtonRenderer/buttonText/runs/0/text",
        )?,
        params: owned_at(
            entry,
            "/musicNavigationButtonRenderer/clickCommand/browseEndpoint/params",
        )?,
    })
}

fn parse_chart_playlist(data: &Value) -> Option<MediaItem> {
    let browse_id = str_at(
        data,
        "/title/runs/0/navigationEndpoint/browseEndpoint/browseId",
    )?;
    Some(MediaItem {
        kind: ItemKind::Playlist,
        id: browse_id.trim_start_matches("VL").to_owned(),
        title: owned_at(data, "/title/runs/0/text").unwrap_or_default(),
        thumb: last_thumbnail_url(array_at(data, THUMBNAIL_RENDERER)),
        ..MediaItem::default()
    })
}

fn parse_chart_artist(data: &Value) -> ChartArtist {
    let item = MediaItem {
        kind: ItemKind::Artist,
        id: owned_at(data, "/navigationEndpoint/browseEndpoint/browseId").unwrap_or_default(),
        title: owned_at(
            data,
            "/flexColumns/0/musicResponsiveListItemFlexColumnRenderer/text/runs/0/text",
        )
        .unwrap_or_default(),
        subscribers: owned_at(
            data,
            "/flexColumns/1/musicResponsiveListItemFlexColumnRenderer/text/runs/0/text",
        ),
        thumb: last_thumbnail_url(array_at(data, THUMBNAILS)),
        ..MediaItem::default()
    };
    ChartArtist {
        item,
        rank: owned_at(data, &format!("{CUSTOM_INDEX}/text/runs/0/text")),
        trend: match str_at(data, &format!("{CUSTOM_INDEX}/icon/iconType")) {
            Some("ARROW_DROP_UP") => Trend::Up,
            Some("ARROW_DROP_DOWN") => Trend::Down,
            _ => Trend::Neutral,
        },
    }
}

const COUNTRY_NAMES: &[(&str, &str)] = &[
    ("ZZ", "Global"),
    ("AR", "Argentina"),
    ("AU", "Australia"),
    ("AT", "Austria"),
    ("BE", "Belgium"),
    ("BO", "Bolivia"),
    ("BR", "Brazil"),
    ("CA", "Canada"),
    ("CL", "Chile"),
    ("CO", "Colombia"),
    ("CR", "Costa Rica"),
    ("CZ", "Czechia"),
    ("DK", "Denmark"),
    ("DO", "Dominican Republic"),
    ("EC", "Ecuador"),
    ("EG", "Egypt"),
    ("SV", "El Salvador"),
    ("EE", "Estonia"),
    ("FI", "Finland"),
    ("FR", "France"),
    ("DE", "Germany"),
    ("GT", "Guatemala"),
    ("HN", "Honduras"),
    ("HU", "Hungary"),
    ("IS", "Iceland"),
    ("IN", "India"),
    ("ID", "Indonesia"),
    ("IE", "Ireland"),
    ("IL", "Israel"),
    ("IT", "Italy"),
    ("JP", "Japan"),
    ("KE", "Kenya"),
    ("LU", "Luxembourg"),
    ("MX", "Mexico"),
    ("NL", "Netherlands"),
    ("NZ", "New Zealand"),
    ("NI", "Nicaragua"),
    ("NG", "Nigeria"),
    ("NO", "Norway"),
    ("PA", "Panama"),
    ("PY", "Paraguay"),
    ("PE", "Peru"),
    ("PH", "Philippines"),
    ("PL", "Poland"),
    ("PT", "Portugal"),
    ("RO", "Romania"),
    ("RU", "Russia"),
    ("SA", "Saudi Arabia"),
    ("RS", "Serbia"),
    ("ZA", "South Africa"),
    ("KR", "South Korea"),
    ("ES", "Spain"),
    ("SE", "Sweden"),
    ("CH", "Switzerland"),
    ("TZ", "Tanzania"),
    ("TR", "Turkey"),
    ("UG", "Uganda"),
    ("UA", "Ukraine"),
    ("AE", "UAE"),
    ("GB", "United Kingdom"),
    ("US", "United States"),
    ("UY", "Uruguay"),
    ("VE", "Venezuela"),
    ("VN", "Vietnam"),
    ("ZW", "Zimbabwe"),
];

pub fn country_options(codes: &[String]) -> Vec<(String, String)> {
    let mut options: Vec<(String, String)> = codes
        .iter()
        .map(|code| {
            let name = COUNTRY_NAMES
                .iter()
                .find(|(c, _)| c == code)
                .map(|(_, n)| (*n).to_owned())
                .unwrap_or_else(|| code.clone());
            (code.clone(), name)
        })
        .collect();
    options.sort_by(|a, b| {
        let key = |(code, name): &(String, String)| {
            if code == "ZZ" {
                String::new()
            } else {
                name.clone()
            }
        };
        key(a).cmp(&key(b))
    });
    options
}
