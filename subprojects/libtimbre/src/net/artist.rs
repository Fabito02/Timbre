use std::sync::Arc;
use std::time::Duration;

use serde::Serialize;
use serde_json::{Value, json};

use super::browse::Browse;
use crate::net::NetError;
use crate::net::items::*;
use crate::net::library::parse_two_row;
use crate::net::media::{ItemKind, MediaItem, Track};
use crate::net::playlists;

const SINGLE_SECTIONS: &str = "/contents/singleColumnBrowseResultsRenderer/tabs/0/tabRenderer/content/sectionListRenderer/contents";
const TWO_COLUMN_SECTIONS: &str = "/contents/twoColumnBrowseResultsRenderer/tabs/0/tabRenderer/content/sectionListRenderer/contents";
const DEEP_FETCH_TIMEOUT: Duration = Duration::from_secs(10);
const ARTIST_PAGE_ALBUMS: usize = 10;

#[derive(Debug, Clone, Default, Serialize)]
pub struct CardSection {
    pub title: Option<String>,
    pub browse_id: Option<String>,
    pub params: Option<String>,
    pub results: Vec<MediaItem>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct SongSection {
    pub title: Option<String>,
    pub browse_id: Option<String>,
    pub results: Vec<Track>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ArtistData {
    pub name: String,
    pub description: Option<String>,
    pub views: Option<String>,
    pub channel_id: Option<String>,
    pub shuffle_id: Option<String>,
    pub radio_id: Option<String>,
    pub subscribers: Option<String>,
    pub monthly_listeners: Option<String>,
    pub subscribed: bool,
    pub thumbnails: Vec<String>,
    pub banner: Vec<String>,
    pub is_channel: bool,
    pub songs: Option<SongSection>,
    pub albums: Option<CardSection>,
    pub singles: Option<CardSection>,
    pub videos: Option<CardSection>,
    pub playlists: Option<CardSection>,
    pub featured_on: Option<CardSection>,
    pub related: Option<CardSection>,
}

fn page_sections(response: &Value) -> &[Value] {
    let single = array_at(response, SINGLE_SECTIONS);
    if single.is_empty() {
        array_at(response, TWO_COLUMN_SECTIONS)
    } else {
        single
    }
}

fn carousel_title_run(carousel: &Value) -> Option<&Value> {
    carousel.pointer("/header/musicCarouselShelfBasicHeaderRenderer/title/runs/0")
}

fn carousel_title(carousel: &Value) -> Option<String> {
    owned_at(
        carousel,
        "/header/musicCarouselShelfBasicHeaderRenderer/title/runs/0/text",
    )
}

fn carousel_title_lower(carousel: &Value) -> String {
    carousel_title(carousel)
        .map(|s| s.to_lowercase())
        .unwrap_or_default()
}

fn carousel_browse_id(carousel: &Value) -> Option<String> {
    carousel_title_run(carousel)
        .and_then(|r| owned_at(r, "/navigationEndpoint/browseEndpoint/browseId"))
}

fn carousel_params(carousel: &Value) -> Option<String> {
    carousel_title_run(carousel)
        .and_then(|r| owned_at(r, "/navigationEndpoint/browseEndpoint/params"))
}

fn dot_separator_index(runs: &[Value]) -> usize {
    runs.iter()
        .position(|r| r.get("text").and_then(Value::as_str) == Some(" • "))
        .unwrap_or(runs.len())
}

fn parse_video(data: &Value) -> Option<MediaItem> {
    let runs = array_at(data, "/subtitle/runs");
    let artists_len = dot_separator_index(runs);
    let video_id = owned_at(data, "/navigationEndpoint/watchEndpoint/videoId").or_else(|| {
        array_at(data, "/menu/menuRenderer/items")
            .iter()
            .find_map(|e| {
                owned_at(
                    e,
                    "/menuServiceItemRenderer/serviceEndpoint/queueAddEndpoint/queueTarget/videoId",
                )
            })
    })?;
    let artists = parse_artists_runs(&runs[..artists_len]);
    Some(MediaItem {
        kind: ItemKind::Video,
        id: video_id,
        title: owned_at(data, "/title/runs/0/text").unwrap_or_default(),
        artists,
        thumb: last_thumbnail_url(array_at(
            data,
            "/thumbnailRenderer/musicThumbnailRenderer/thumbnail/thumbnails",
        )),
        views: runs
            .last()
            .and_then(|r| r.get("text"))
            .and_then(Value::as_str)
            .and_then(|t| t.split(' ').next())
            .map(str::to_owned),
        ..MediaItem::default()
    })
}

fn parse_related_artist(data: &Value) -> Option<MediaItem> {
    Some(MediaItem {
        kind: ItemKind::Artist,
        id: owned_at(
            data,
            "/title/runs/0/navigationEndpoint/browseEndpoint/browseId",
        )?,
        title: owned_at(data, "/title/runs/0/text").unwrap_or_default(),
        subscribers: owned_at(data, "/subtitle/runs/0/text"),
        thumb: last_thumbnail_url(array_at(
            data,
            "/thumbnailRenderer/musicThumbnailRenderer/thumbnail/thumbnails",
        )),
        ..MediaItem::default()
    })
}

#[derive(Clone, Copy)]
enum Category {
    Albums,
    Singles,
    Videos,
    Playlists,
    Related,
    Featured,
}

impl Category {
    fn parse(self, entry: &Value) -> Option<MediaItem> {
        let data = entry.get(MTRIR)?;
        match self {
            Category::Albums | Category::Singles => parse_two_row(entry, ItemKind::Album),
            Category::Videos => parse_video(data),
            Category::Playlists => parse_two_row(entry, ItemKind::Playlist),
            Category::Related => parse_related_artist(data),
            Category::Featured => parse_two_row(entry, ItemKind::Album)
                .or_else(|| parse_two_row(entry, ItemKind::Playlist)),
        }
    }
}

fn detect_item_kind(entry: &Value) -> Option<(ItemKind, Option<String>)> {
    let data = entry.get(MTRIR)?;

    if let Some(bid) = owned_at(data, "/navigationEndpoint/browseEndpoint/browseId") {
        if bid.starts_with("MPRE") || bid.contains("release_detail") {
            let subtype = str_at(data, "/subtitle/runs/0/text").map(str::to_owned);
            return Some((ItemKind::Album, subtype));
        }
        if bid.starts_with("UC") || bid.contains("artist_detail") {
            return Some((ItemKind::Artist, None));
        }
        return Some((ItemKind::Playlist, None));
    }

    if owned_at(data, "/navigationEndpoint/watchEndpoint/videoId").is_some() {
        return Some((ItemKind::Video, None));
    }
    if owned_at(data, "/navigationEndpoint/watchPlaylistEndpoint/playlistId").is_some() {
        return Some((ItemKind::Playlist, None));
    }
    None
}

fn classify(title_lower: &str, contents: &[Value]) -> Category {
    if title_lower.contains("single") || title_lower.contains("ep") {
        return Category::Singles;
    }
    if title_lower.contains("album") {
        return Category::Albums;
    }
    if title_lower.contains("video") {
        return Category::Videos;
    }
    if title_lower.contains("featured")
        || title_lower.contains("appears")
        || title_lower.contains("aparece")
        || title_lower.contains("featuring")
    {
        return Category::Featured;
    }
    if title_lower.contains("playlist") || title_lower.contains("mix") {
        return Category::Playlists;
    }
    if title_lower.contains("fans")
        || title_lower.contains("related")
        || title_lower.contains("similar")
        || title_lower.contains("parecidos")
    {
        return Category::Related;
    }

    for entry in contents {
        match detect_item_kind(entry) {
            Some((ItemKind::Album, subtype)) => {
                return match subtype.as_deref() {
                    Some("Single") | Some("EP") => Category::Singles,
                    _ => Category::Albums,
                };
            }
            Some((ItemKind::Playlist, _)) => return Category::Playlists,
            Some((ItemKind::Video, _)) | Some((ItemKind::Song, _)) => return Category::Videos,
            Some((ItemKind::Artist, _)) => return Category::Related,
            None => continue,
        }
    }
    Category::Albums
}

fn parse_all_carousels(sections: &[Value]) -> ArtistData {
    let mut out = ArtistData::default();
    for section in sections {
        let Some(carousel) = section.get("musicCarouselShelfRenderer") else {
            continue;
        };
        let contents = array_at(carousel, "/contents");
        if contents.is_empty() {
            continue;
        }

        let title_text = carousel_title(carousel);
        let title_lower = title_text
            .as_deref()
            .map(str::to_lowercase)
            .unwrap_or_default();
        let cat = classify(&title_lower, contents);

        let results: Vec<MediaItem> = contents.iter().filter_map(|e| cat.parse(e)).collect();
        if results.is_empty() {
            continue;
        }

        let card = CardSection {
            title: title_text,
            browse_id: carousel_browse_id(carousel),
            params: carousel_params(carousel),
            results,
        };

        match cat {
            Category::Albums => {
                if out.albums.is_none() {
                    out.albums = Some(card)
                }
            }
            Category::Singles => {
                if out.singles.is_none() {
                    out.singles = Some(card)
                }
            }
            Category::Videos => {
                if out.videos.is_none() {
                    out.videos = Some(card)
                }
            }
            Category::Playlists => {
                if out.playlists.is_none() {
                    out.playlists = Some(card)
                }
            }
            Category::Featured => {
                if out.featured_on.is_none() {
                    out.featured_on = Some(card)
                }
            }
            Category::Related => {
                if out.related.is_none() {
                    out.related = Some(card)
                }
            }
        }
    }
    out
}

fn parse_artist_page(response: &Value) -> Option<ArtistData> {
    let header = response.pointer("/header/musicImmersiveHeaderRenderer")?;
    let page = page_sections(response);
    let mut artist = ArtistData {
        name: owned_at(header, "/title/runs/0/text").unwrap_or_default(),
        ..ArtistData::default()
    };
    if let Some(shelf) = walk_key(response, "musicDescriptionShelfRenderer")
        .into_iter()
        .next()
    {
        let description = runs_text(array_at(shelf, "/description/runs"));
        if !description.is_empty() {
            artist.description = Some(description);
        }
        artist.views = owned_at(shelf, "/subheader/runs/0/text");
    }
    let subscription = header.pointer("/subscriptionButton/subscribeButtonRenderer");
    artist.channel_id = subscription.and_then(|s| owned_at(s, "/channelId"));
    artist.subscribers = subscription.and_then(|s| owned_at(s, "/subscriberCountText/runs/0/text"));
    artist.subscribed = subscription
        .and_then(|s| s.get("subscribed"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    artist.shuffle_id = owned_at(
        header,
        "/playButton/buttonRenderer/navigationEndpoint/watchEndpoint/playlistId",
    );
    artist.radio_id = owned_at(
        header,
        "/startRadioButton/buttonRenderer/navigationEndpoint/watchEndpoint/playlistId",
    );
    artist.monthly_listeners = owned_at(header, "/monthlyListenerCount/runs/0/text");
    artist.thumbnails = thumbnails_at(
        header,
        "/thumbnail/musicThumbnailRenderer/thumbnail/thumbnails",
    );

    if let Some(shelf) = page.first().and_then(|s| s.get("musicShelfRenderer")) {
        artist.songs = Some(SongSection {
            title: owned_at(shelf, "/title/runs/0/text"),
            browse_id: owned_at(
                shelf,
                "/title/runs/0/navigationEndpoint/browseEndpoint/browseId",
            ),
            results: parse_playlist_items(array_at(shelf, "/contents"), false, false),
        });
    }

    let parsed = parse_all_carousels(page);
    artist.albums = parsed.albums;
    artist.singles = parsed.singles;
    artist.videos = parsed.videos;
    artist.playlists = parsed.playlists;
    artist.featured_on = parsed.featured_on;
    artist.related = parsed.related;

    Some(artist)
}

fn parse_channel_page(response: &Value) -> Option<ArtistData> {
    let page = page_sections(response);
    let mut artist = ArtistData {
        is_channel: true,
        subscribers: Some(String::new()),
        ..ArtistData::default()
    };
    for key in ["musicVisualHeaderRenderer", "musicImmersiveHeaderRenderer"] {
        let Some(header) = response.pointer(&format!("/header/{key}")) else {
            continue;
        };
        artist.name = owned_at(header, "/title/runs/0/text").unwrap_or_default();
        artist.thumbnails = thumbnails_at(
            header,
            "/foregroundThumbnail/musicThumbnailRenderer/thumbnail/thumbnails",
        );
        artist.banner = thumbnails_at(
            header,
            "/thumbnail/musicThumbnailRenderer/thumbnail/thumbnails",
        );
        if let Some(count) = owned_at(
            header,
            "/subscriptionButton/subscribeButtonRenderer/subscriberCountText/runs/0/text",
        ) {
            artist.subscribers = Some(count);
        }
        break;
    }
    if artist.name.is_empty() {
        return None;
    }

    let parsed = parse_all_carousels(page);
    artist.videos = parsed.videos;
    artist.playlists = parsed.playlists;

    if artist.thumbnails.is_empty() {
        for section in [&artist.playlists, &artist.videos].into_iter().flatten() {
            if let Some(thumb) = section.results.first().and_then(|i| i.thumb.clone()) {
                artist.thumbnails = vec![thumb];
                break;
            }
        }
    }
    Some(artist)
}

pub async fn get_artist(api: Arc<dyn Browse>, channel_id: &str) -> Result<ArtistData, NetError> {
    let channel_id = channel_id
        .strip_prefix("MPLA")
        .unwrap_or(channel_id)
        .to_owned();
    let response = api
        .post("browse", json!({ "browseId": channel_id }))
        .await?;
    let mut artist = match parse_artist_page(&response) {
        Some(a) => a,
        None => parse_channel_page(&response)
            .ok_or_else(|| NetError::Message(format!("artist {channel_id}: no header")))?,
    };
    if artist.is_channel {
        return Ok(artist);
    }
    let songs_browse = artist.songs.as_ref().and_then(|s| s.browse_id.clone());
    let albums_ptr = artist
        .albums
        .as_ref()
        .and_then(|s| Some((s.browse_id.clone()?, s.params.clone())));
    let singles_ptr = artist
        .singles
        .as_ref()
        .and_then(|s| Some((s.browse_id.clone()?, s.params.clone())));
    let (songs, albums, singles) = tokio::join!(
        async {
            match songs_browse {
                Some(id) => tokio::time::timeout(
                    DEEP_FETCH_TIMEOUT,
                    playlists::get_playlist(&api, &id, Some(100)),
                )
                .await
                .ok()
                .and_then(Result::ok)
                .map(|p| p.tracks)
                .filter(|t| !t.is_empty()),
                None => None,
            }
        },
        async {
            match albums_ptr {
                Some((id, params)) => tokio::time::timeout(
                    DEEP_FETCH_TIMEOUT,
                    playlists::artist_albums(
                        &api,
                        &id,
                        params.as_deref(),
                        Some(ARTIST_PAGE_ALBUMS),
                    ),
                )
                .await
                .ok()
                .and_then(Result::ok)
                .filter(|a| !a.is_empty()),
                None => None,
            }
        },
        async {
            match singles_ptr {
                Some((id, params)) => tokio::time::timeout(
                    DEEP_FETCH_TIMEOUT,
                    playlists::artist_albums(
                        &api,
                        &id,
                        params.as_deref(),
                        Some(ARTIST_PAGE_ALBUMS),
                    ),
                )
                .await
                .ok()
                .and_then(Result::ok)
                .filter(|a| !a.is_empty()),
                None => None,
            }
        }
    );
    if let (Some(tracks), Some(section)) = (songs, artist.songs.as_mut()) {
        section.results = tracks;
    }
    if let (Some(items), Some(section)) = (albums, artist.albums.as_mut()) {
        section.results = items;
    }
    if let (Some(items), Some(section)) = (singles, artist.singles.as_mut()) {
        section.results = items;
    }
    Ok(artist)
}

pub async fn channel_of_video(
    api: &dyn Browse,
    video_id: &str,
) -> Result<Option<(String, String)>, NetError> {
    let response = api.post("player", json!({ "videoId": video_id })).await?;
    let channel = owned_at(&response, "/videoDetails/channelId");
    let author = owned_at(&response, "/videoDetails/author").unwrap_or_else(|| "Artist".to_owned());
    Ok(channel.map(|c| (c, author)))
}

pub async fn resolve_handle(api: &dyn Browse, handle: &str) -> Result<Option<String>, NetError> {
    let handle = handle.trim_start_matches('@');
    if handle.is_empty() {
        return Ok(None);
    }
    let body = json!({ "url": format!("https://music.youtube.com/@{handle}") });
    let response = api.post("navigation/resolve_url", body).await?;
    Ok(owned_at(&response, "/endpoint/browseEndpoint/browseId")
        .or_else(|| owned_at(&response, "/endpoint/browse/browseId")))
}

pub async fn subscribe(api: &dyn Browse, channel_id: &str) -> Result<(), NetError> {
    api.post(
        "subscription/subscribe",
        json!({ "channelIds": [channel_id] }),
    )
    .await?;
    Ok(())
}

pub async fn unsubscribe(api: &dyn Browse, channel_id: &str) -> Result<(), NetError> {
    api.post(
        "subscription/unsubscribe",
        json!({ "channelIds": [channel_id] }),
    )
    .await?;
    Ok(())
}
