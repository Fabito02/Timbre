use std::collections::BTreeMap;
use std::path::Path;
use std::sync::{Arc, LazyLock};

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::browse::{Browse, Continuation};
use crate::net::NetError;
use crate::net::cache::{LibraryIds, SortMetric};
use crate::net::items::*;
use crate::net::library::{self, parse_two_row};
use crate::net::media::{HttpAuth, ItemKind, LikeStatus, MediaItem, Named, Person, Track};
use crate::net::search::{SearchFilter, search};

const HEADER_SECTION: &str = "/contents/twoColumnBrowseResultsRenderer/tabs/0/tabRenderer/content/sectionListRenderer/contents/0";
const SECONDARY_SECTIONS: &str =
    "/contents/twoColumnBrowseResultsRenderer/secondaryContents/sectionListRenderer/contents";
const SINGLE_SECTIONS: &str = "/contents/singleColumnBrowseResultsRenderer/tabs/0/tabRenderer/content/sectionListRenderer/contents";
const MAX_METRIC_PAGES: usize = 60;
const MAX_CONTINUATION_PAGES: usize = 100;
const YT_WEB_BROWSE_URL: &str = "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false";

static VIEWS_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^([\d.,]+)\s*([KMB])?\s+views?$").unwrap());
static MPRE_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#""(MPRE[A-Za-z0-9_\-]+)""#).unwrap());

fn message(text: impl Into<String>) -> NetError {
    NetError::Message(text.into())
}

fn to_int(text: &str) -> Option<u32> {
    let digits: String = text.chars().filter(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

fn is_auto_playlist(playlist_id: &str) -> bool {
    playlist_id.starts_with("RD")
        || playlist_id.starts_with("VLLM")
        || playlist_id == "SE"
}

fn is_radio_playlist(playlist_id: &str) -> bool {
    playlist_id.starts_with("RD")
}

fn is_likes_playlist(playlist_id: &str) -> bool {
    playlist_id == "LM" || playlist_id.starts_with("VLLM")
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct PlaylistDetails {
    pub id: String,
    pub title: String,
    pub description: String,
    pub privacy: Option<String>,
    pub thumbnails: Vec<String>,
    pub author: Vec<Person>,
    pub collaborators: Option<String>,
    pub year: Option<String>,
    pub duration: Option<String>,
    pub duration_seconds: Option<u32>,
    pub track_count: Option<u32>,
    pub tracks: Vec<Track>,
    pub audio_playlist_id: Option<String>,
    pub album_type: Option<String>,
    pub like_status: LikeStatus,
}

impl PlaylistDetails {
    fn sum_duration(&mut self) {
        self.duration_seconds = Some(self.tracks.iter().filter_map(|t| t.duration_seconds).sum());
    }
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct WatchPlaylist {
    pub tracks: Vec<WatchTrack>,
    pub playlist_id: Option<String>,
}

pub async fn get_playlist(
    api: &dyn Browse,
    playlist_id: &str,
    limit: Option<usize>,
) -> Result<PlaylistDetails, NetError> {
    if is_auto_playlist(playlist_id) {
        return get_auto_playlist(api, playlist_id, limit).await;
    }
    
    let browse_id = if playlist_id.starts_with("VL") {
        playlist_id.to_owned()
    } else {
        format!("VL{playlist_id}")
    };
    let response = api.post("browse", json!({ "browseId": browse_id })).await?;
    let mut details = parse_playlist_header(&response)
        .ok_or_else(|| message(format!("playlist {playlist_id}: header missing")))?;
    if details.id.is_empty() {
        details.id = playlist_id.trim_start_matches("VL").to_owned();
    }
    let collaborative = details.collaborators.is_some();
    let shelf = response.pointer(&format!(
        "{SECONDARY_SECTIONS}/0/musicPlaylistShelfRenderer"
    ));
    let limit = limit.unwrap_or(usize::MAX);
    let mut tracks = shelf
        .map(|s| parse_playlist_items(array_at(s, "/contents"), false, collaborative))
        .unwrap_or_default();
    let token = shelf.and_then(|s| {
        array_at(s, "/contents")
            .last()
            .and_then(item_continuation_token)
            .or_else(|| next_continuation(s))
    });
    let rest = Continuation::browse(api, token)
        .limit(limit)
        .pages(MAX_CONTINUATION_PAGES)
        .collect(|entries| parse_playlist_items(entries.iter().copied(), false, collaborative))
        .await;
    tracks.extend(rest.strict()?);
    details.tracks = tracks;
    details.sum_duration();
    tracing::info!(
        playlist_id,
        tracks = details.tracks.len(),
        declared = ?details.track_count,
        "playlist fetched"
    );
    Ok(details)
}

async fn get_auto_playlist(
    api: &dyn Browse,
    playlist_id: &str,
    limit: Option<usize>,
) -> Result<PlaylistDetails, NetError> {
    let radio = is_radio_playlist(playlist_id);
    let is_likes = is_likes_playlist(playlist_id);
    let want = match (limit, is_likes) {
        (Some(n), _) => n,
        (None, true) => usize::MAX,
        (None, false) => 100,
    };

    let browse_id = if playlist_id.starts_with("VL") {
        playlist_id.to_owned()
    } else {
        format!("VL{playlist_id}")
    };

    let (title, description, thumbnails) = match api
        .post("browse", json!({ "browseId": browse_id }))
        .await
    {
        Ok(resp) => {
            let header = resp
                .pointer("/header/musicImmersiveHeaderRenderer")
                .or_else(|| resp.pointer("/header/musicVisualHeaderRenderer"))
                .or_else(|| {
                    resp.pointer(
                        "/contents/singleColumnBrowseResultsRenderer/tabs/0/tabRenderer/content/sectionListRenderer/contents/0/musicResponsiveHeaderRenderer",
                    )
                });
            let t = header
                .and_then(|h| owned_at(h, "/title/runs/0/text"))
                .unwrap_or_default();
            let d = header
                .and_then(|h| owned_at(h, "/description/runs/0/text"))
                .unwrap_or_default();
            let thumbs = header
                .map(|h| thumbnails_at(h, "/thumbnail/musicThumbnailRenderer/thumbnail/thumbnails"))
                .unwrap_or_default();
            (t, d, thumbs)
        }
        Err(_) => (String::new(), String::new(), Vec::new()),
    };

    let watch = get_watch_playlist(api, None, Some(playlist_id), want, radio).await?;

    let tracks: Vec<Track> = watch.tracks.into_iter().map(|w| w.track).collect();

    let mut details = PlaylistDetails {
        id: playlist_id.to_owned(),
        title: if title.is_empty() {
            playlist_id.to_owned()
        } else {
            title
        },
        description,
        thumbnails,
        tracks,
        ..PlaylistDetails::default()
    };

    details.sum_duration();
    tracing::info!(
        playlist_id,
        radio,
        tracks = details.tracks.len(),
        "auto playlist fetched"
    );
    Ok(details)
}

fn parse_playlist_header(response: &Value) -> Option<PlaylistDetails> {
    let header_data = response.pointer(HEADER_SECTION)?;
    let owned = header_data
        .get("musicEditablePlaylistDetailHeaderRenderer")
        .is_some();
    let (header, privacy, id) = if owned {
        let editable = &header_data["musicEditablePlaylistDetailHeaderRenderer"];
        (
            editable.pointer("/header/musicResponsiveHeaderRenderer")?,
            owned_at(
                editable,
                "/editHeader/musicPlaylistEditHeaderRenderer/privacy",
            ),
            owned_at(editable, "/playlistId"),
        )
    } else {
        let header = header_data.get("musicResponsiveHeaderRenderer")?;
        (
            header,
            Some("PUBLIC".to_owned()),
            owned_at(
                header,
                "/buttons/1/musicPlayButtonRenderer/playNavigationEndpoint/watchEndpoint/playlistId",
            ),
        )
    };
    let mut details = PlaylistDetails {
        id: id.unwrap_or_default(),
        privacy,
        ..PlaylistDetails::default()
    };
    details.description = runs_text(array_at(
        header,
        "/description/musicDescriptionShelfRenderer/description/runs",
    ));
    details.title = runs_text(array_at(header, "/title/runs"));
    details.thumbnails = thumbnails_at(
        header,
        "/thumbnail/musicThumbnailRenderer/thumbnail/thumbnails",
    );
    if let Some(face) = header.pointer("/facepile/avatarStackViewModel") {
        let command = face.pointer("/rendererContext/commandContext/onTap/innertubeCommand");
        let is_collab = command
            .and_then(|c| str_at(c, "/showEngagementPanelEndpoint/identifier/tag"))
            == Some("PAplaylist_collaborate");
        if is_collab {
            details.collaborators = owned_at(face, "/rendererContext/accessibilityContext/label");
        } else {
            details.author = vec![Person {
                name: owned_at(face, "/text/content").unwrap_or_default(),
                id: command.and_then(|c| owned_at(c, "/browseEndpoint/browseId")),
            }];
        }
    }
    let second = array_at(header, "/secondSubtitle/runs");
    if !second.is_empty() {
        let has_views = if second.len() > 3 { 2 } else { 0 };
        let has_duration = if second.len() > 1 { 2 } else { 0 };
        if has_duration > 0 {
            details.duration = second
                .get(has_views + has_duration)
                .and_then(|r| owned_at(r, "/text"));
        }
        details.track_count = second
            .get(has_views)
            .and_then(|r| str_at(r, "/text"))
            .and_then(to_int);
    }
    let subtitle = array_at(header, "/subtitle/runs");
    let skip = 2 + if owned { 2 } else { 0 };
    details.year = parse_song_runs(subtitle.get(skip..).unwrap_or(&[])).year;
    Some(details)
}

pub async fn get_album(api: &dyn Browse, browse_id: &str) -> Result<PlaylistDetails, NetError> {
    if !browse_id.starts_with("MPRE") {
        return Err(message(
            "Invalid album browseId provided, must start with MPRE.",
        ));
    }
    let response = api.post("browse", json!({ "browseId": browse_id })).await?;
    let header = response
        .pointer(&format!("{HEADER_SECTION}/musicResponsiveHeaderRenderer"))
        .ok_or_else(|| message(format!("album {browse_id}: header missing")))?;
    let mut details = PlaylistDetails {
        id: browse_id.to_owned(),
        ..PlaylistDetails::default()
    };
    details.title = owned_at(header, "/title/runs/0/text").unwrap_or_default();
    details.album_type = owned_at(header, "/subtitle/runs/0/text");
    details.thumbnails = thumbnails_at(
        header,
        "/thumbnail/musicThumbnailRenderer/thumbnail/thumbnails",
    );
    details.description = runs_text(array_at(
        header,
        "/description/musicDescriptionShelfRenderer/description/runs",
    ));
    let subtitle = array_at(header, "/subtitle/runs");
    details.year = parse_song_runs(subtitle.get(2..).unwrap_or(&[])).year;
    details.author = parse_artists_runs(array_at(header, "/straplineTextOne/runs"));
    let second = array_at(header, "/secondSubtitle/runs");
    if second.len() > 1 {
        details.track_count = second
            .first()
            .and_then(|r| str_at(r, "/text"))
            .and_then(to_int);
        details.duration = second.get(2).and_then(|r| owned_at(r, "/text"));
    } else {
        details.duration = second.first().and_then(|r| owned_at(r, "/text"));
    }
    let buttons = array_at(header, "/buttons");
    let play = buttons
        .iter()
        .find(|b| b.get("musicPlayButtonRenderer").is_some());
    details.audio_playlist_id = play.and_then(|b| {
        owned_at(
            b,
            "/musicPlayButtonRenderer/playNavigationEndpoint/watchPlaylistEndpoint/playlistId",
        )
        .or_else(|| {
            owned_at(
                b,
                "/musicPlayButtonRenderer/playNavigationEndpoint/watchEndpoint/playlistId",
            )
        })
    });
    if let Some(service) = buttons
        .iter()
        .find_map(|b| b.pointer("/toggleButtonRenderer/defaultServiceEndpoint"))
    {
        details.like_status = parse_like_status(service);
    }
    let shelf = response.pointer(&format!("{SECONDARY_SECTIONS}/0/musicShelfRenderer"));
    let mut tracks = shelf
        .map(|s| parse_playlist_items(array_at(s, "/contents"), true, false))
        .unwrap_or_default();
    for track in &mut tracks {
        track.album = Some(Named {
            name: details.title.clone(),
            id: Some(browse_id.to_owned()),
        });
        if track.artists.is_empty() {
            track.artists = details.author.clone();
            track.artist = details
                .author
                .iter()
                .map(|a| a.name.as_str())
                .collect::<Vec<_>>()
                .join(", ");
        }
    }
    details.tracks = tracks;
    details.sum_duration();
    Ok(details)
}

pub async fn get_upload_album(
    api: &dyn Browse,
    browse_id: &str,
) -> Result<PlaylistDetails, NetError> {
    let response = api.post("browse", json!({ "browseId": browse_id })).await?;
    let header = response
        .pointer("/header/musicDetailHeaderRenderer")
        .ok_or_else(|| message(format!("upload album {browse_id}: header missing")))?;
    let mut details = PlaylistDetails {
        id: browse_id.to_owned(),
        ..PlaylistDetails::default()
    };
    details.title = owned_at(header, "/title/runs/0/text").unwrap_or_default();
    details.album_type = owned_at(header, "/subtitle/runs/0/text");
    details.thumbnails = thumbnails_at(
        header,
        "/thumbnail/croppedSquareThumbnailRenderer/thumbnail/thumbnails",
    );
    details.description = owned_at(header, "/description/runs/0/text").unwrap_or_default();
    let subtitle = array_at(header, "/subtitle/runs");
    let parsed = parse_song_runs(subtitle.get(2..).unwrap_or(&[]));
    details.author = parsed.artists;
    details.year = parsed.year;
    let second = array_at(header, "/secondSubtitle/runs");
    if second.len() > 1 {
        details.track_count = second
            .first()
            .and_then(|r| str_at(r, "/text"))
            .and_then(to_int);
        details.duration = second.get(2).and_then(|r| owned_at(r, "/text"));
    } else {
        details.duration = second.first().and_then(|r| owned_at(r, "/text"));
    }
    let shelf = library_sections(&response)
        .iter()
        .find_map(|s| s.get("musicShelfRenderer"));
    details.tracks = shelf
        .map(|s| parse_uploaded_items(array_at(s, "/contents")))
        .unwrap_or_default();
    details.sum_duration();
    Ok(details)
}

pub async fn get_upload_songs(api: &dyn Browse) -> Result<Vec<Track>, NetError> {
    let response = api
        .post(
            "browse",
            json!({ "browseId": "FEmusic_library_privately_owned_tracks" }),
        )
        .await?;
    let sections = library_sections(&response);
    let shelf = sections.iter().find_map(|s| {
        s.get("musicShelfRenderer")
            .or_else(|| s.pointer("/itemSectionRenderer/contents/0/musicShelfRenderer"))
    });
    let Some(shelf) = shelf else {
        return Ok(Vec::new());
    };
    let mut songs = parse_uploaded_items(array_at(shelf, "/contents"));
    let rest = Continuation::browse(api, next_continuation(shelf))
        .pages(MAX_CONTINUATION_PAGES)
        .collect(|entries| parse_uploaded_items(entries.iter().copied()))
        .await;
    songs.extend(rest.strict()?);
    Ok(songs)
}

pub async fn get_watch_playlist(
    api: &dyn Browse,
    video_id: Option<&str>,
    playlist_id: Option<&str>,
    limit: usize,
    radio: bool,
) -> Result<WatchPlaylist, NetError> {
    let mut body = json!({
        "enablePersistentPlaylistPanel": true,
        "isAudioOnly": true,
        "tunerSettingValue": "AUTOMIX_SETTING_NORMAL"
    });
    if video_id.is_none() && playlist_id.is_none() {
        return Err(message(
            "You must provide either a video id, a playlist id, or both",
        ));
    }
    let mut playlist_id = playlist_id.map(str::to_owned);
    if let Some(v) = video_id {
        body["videoId"] = json!(v);
        if playlist_id.is_none() {
            playlist_id = Some(format!("RDAMVM{v}"));
        }
        if !radio {
            body["watchEndpointMusicSupportedConfigs"] = json!({
                "watchEndpointMusicConfig": {
                    "hasPersistentPlaylistPanel": true,
                    "musicVideoType": "MUSIC_VIDEO_TYPE_ATV"
                }
            });
        }
    }
    let mut is_playlist = false;
    if let Some(p) = &playlist_id {
        let pid = p.trim_start_matches("VL");
        is_playlist = pid.starts_with("PL")
            || pid.starts_with("OLA")
            || pid.starts_with("VLLM")
            || pid == "SE";
        body["playlistId"] = json!(pid);
    }
    if radio {
        body["params"] = json!("wAEB");
    }
    let response = api.post("next", body.clone()).await?;
    let watch_next = response
        .pointer("/contents/singleColumnMusicWatchNextResultsRenderer/tabbedRenderer/watchNextTabbedResultsRenderer")
        .ok_or_else(|| message("No content returned by the server."))?;
    let results = watch_next
        .pointer("/tabs/0/tabRenderer/content/musicQueueRenderer/content/playlistPanelRenderer")
        .ok_or_else(|| {
            let mut msg = "No content returned by the server.".to_owned();
            if let Some(p) = &playlist_id {
                msg.push_str(&format!(
                    "\nEnsure you have access to {p} - a private playlist may cause this."
                ));
            }
            message(msg)
        })?;
    let panel_playlist = array_at(results, "/contents").iter().find_map(|x| {
        owned_at(
            x,
            "/playlistPanelVideoRenderer/navigationEndpoint/watchEndpoint/playlistId",
        )
    });
    let mut tracks = parse_watch_playlist(array_at(results, "/contents"));
    let key = if is_playlist {
        "/continuations/0/nextContinuationData/continuation"
    } else {
        "/continuations/0/nextRadioContinuationData/continuation"
    };
    let token = owned_at(results, key);
    let rest = Continuation::query(api, "next", body, token)
        .limit(limit.saturating_sub(tracks.len()))
        .pages(MAX_CONTINUATION_PAGES)
        .collect(|entries| parse_watch_playlist(entries.iter().copied()))
        .await;
    tracks.extend(rest.strict()?);
    Ok(WatchPlaylist {
        tracks,
        playlist_id: panel_playlist,
    })
}

pub async fn radio_tracks(
    api: &dyn Browse,
    video_id: Option<&str>,
    playlist_id: Option<&str>,
) -> Result<WatchPlaylist, NetError> {
    get_watch_playlist(api, video_id, playlist_id, 50, true).await
}

pub async fn find_audio_version(
    api: &dyn Browse,
    video_id: &str,
) -> Result<Option<Track>, NetError> {
    let watch = get_watch_playlist(api, Some(video_id), None, 1, false)
        .await
        .unwrap_or_default();
    let Some(current) = watch.tracks.first() else {
        return Ok(None);
    };
    let cur_type = current
        .track
        .video_type
        .clone()
        .unwrap_or_default()
        .to_uppercase();
    if cur_type == "MUSIC_VIDEO_TYPE_ATV" {
        return Ok(None);
    }
    if let Some(cp) = &current.counterpart {
        let is_song = cp.video_type.as_deref().map(str::to_uppercase).as_deref()
            == Some("MUSIC_VIDEO_TYPE_ATV");
        if cp.video_id.as_str() != video_id && is_song {
            return Ok(Some(cp.clone()));
        }
    }
    let title = current.track.title.clone();
    let artists: Vec<String> = current
        .track
        .artists
        .iter()
        .map(|a| a.name.to_lowercase())
        .collect();
    if title.is_empty() {
        return Ok(None);
    }
    let query = match artists.first() {
        Some(a) => format!("{title} {a}"),
        None => title.clone(),
    };
    let results = search(api, &query, Some(SearchFilter::Songs)).await?;
    let wanted = normalize_title(&title);
    for item in results.items.iter().filter(|i| i.kind == ItemKind::Song) {
        if normalize_title(&item.title) != wanted {
            continue;
        }
        let names: Vec<String> = item.artists.iter().map(|a| a.name.to_lowercase()).collect();
        if artists.is_empty() || artists.iter().any(|a| names.contains(a)) {
            return Ok(item.to_track());
        }
    }
    Ok(None)
}

fn normalize_title(title: &str) -> String {
    title
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

pub async fn get_album_browse_id(
    http: &reqwest::Client,
    auth: Option<&HttpAuth>,
    audio_playlist_id: &str,
) -> Result<Option<String>, NetError> {
    let mut request = http.get(format!(
        "https://music.youtube.com/playlist?list={audio_playlist_id}"
    ));
    if let Some(auth) = auth {
        request = request
            .header("Cookie", &auth.cookie)
            .header("User-Agent", &auth.user_agent);
    }
    let text = request.send().await?.text().await?;
    let decoded = text.replace("\\u003d", "=").replace("\\\"", "\"");
    Ok(MPRE_RE.captures(&decoded).map(|c| c[1].to_owned()))
}

pub async fn rate_playlist(
    api: &dyn Browse,
    playlist_id: &str,
    rating: LikeStatus,
) -> Result<(), NetError> {
    let mut pid = playlist_id.trim_start_matches("VL").to_owned();
    if pid.starts_with("MPRE") {
        if let Ok(album) = get_album(api, &pid).await {
            if let Some(audio) = album.audio_playlist_id {
                pid = audio;
            }
        }
    }
    let endpoint = match rating {
        LikeStatus::Like => "like/like",
        LikeStatus::Dislike => "like/dislike",
        LikeStatus::Indifferent => "like/removelike",
    };
    api.post(endpoint, json!({ "target": { "playlistId": pid } }))
        .await?;
    Ok(())
}

pub async fn edit_playlist(
    api: &dyn Browse,
    playlist_id: &str,
    title: Option<&str>,
    description: Option<&str>,
    privacy: Option<&str>,
) -> Result<(), NetError> {
    let mut actions = Vec::new();
    if let Some(t) = title.filter(|t| !t.is_empty()) {
        actions.push(json!({ "action": "ACTION_SET_PLAYLIST_NAME", "playlistName": t }));
    }
    if let Some(d) = description.filter(|d| !d.is_empty()) {
        actions
            .push(json!({ "action": "ACTION_SET_PLAYLIST_DESCRIPTION", "playlistDescription": d }));
    }
    if let Some(p) = privacy.filter(|p| !p.is_empty()) {
        actions.push(json!({ "action": "ACTION_SET_PLAYLIST_PRIVACY", "playlistPrivacy": p }));
    }
    if actions.is_empty() {
        return Ok(());
    }
    api.post(
        "browse/edit_playlist",
        json!({ "playlistId": playlist_id.trim_start_matches("VL"), "actions": actions }),
    )
    .await?;
    Ok(())
}

pub async fn remove_playlist_items(
    api: &dyn Browse,
    playlist_id: &str,
    items: &[(String, String)],
) -> Result<(), NetError> {
    let actions: Vec<Value> = items
        .iter()
        .map(|(video, set)| {
            json!({
                "setVideoId": set,
                "removedVideoId": video,
                "action": "ACTION_REMOVE_VIDEO"
            })
        })
        .collect();
    if actions.is_empty() {
        return Err(message(
            "Cannot remove songs, because setVideoId is missing",
        ));
    }
    api.post(
        "browse/edit_playlist",
        json!({ "playlistId": playlist_id.trim_start_matches("VL"), "actions": actions }),
    )
    .await?;
    Ok(())
}

pub async fn add_playlist_items(
    api: &dyn Browse,
    playlist_id: &str,
    video_ids: Vec<String>,
    swap_to_audio: Option<bool>,
) -> Result<(), NetError> {
    let swap = swap_to_audio.unwrap_or(video_ids.len() == 1);
    let mut ids = Vec::with_capacity(video_ids.len());
    for vid in video_ids {
        if swap {
            match find_audio_version(api, &vid).await {
                Ok(Some(alt)) => {
                    ids.push(alt.video_id.0);
                    continue;
                }
                Ok(None) => {}
                Err(err) => tracing::warn!(%err, vid, "audio-version swap failed"),
            }
        }
        ids.push(vid);
    }
    if ids.is_empty() {
        return Ok(());
    }
    let actions: Vec<Value> = ids
        .iter()
        .map(|vid| {
            json!({
                "action": "ACTION_ADD_VIDEO",
                "addedVideoId": vid,
                "dedupeOption": "DEDUPE_OPTION_SKIP"
            })
        })
        .collect();
    api.post(
        "browse/edit_playlist",
        json!({ "playlistId": playlist_id.trim_start_matches("VL"), "actions": actions }),
    )
    .await?;
    Ok(())
}

pub async fn create_playlist(
    api: &dyn Browse,
    title: &str,
    description: &str,
    privacy: &str,
) -> Result<String, NetError> {
    if title.trim().is_empty() {
        return Err(message("A playlist needs a title."));
    }
    let mut body = json!({ "title": title, "privacyStatus": privacy });
    if !description.trim().is_empty() {
        body["description"] = json!(description);
    }
    let response = api.post("playlist/create", body).await?;
    owned_at(&response, "/playlistId")
        .or_else(|| {
            owned_at(
                &response,
                "/playlistEditResults/0/playlistEditVideoAddedResultData/playlistId",
            )
        })
        .ok_or_else(|| message("The server did not return a playlist id."))
}

pub async fn await_playlist(api: &dyn Browse, playlist_id: &str) -> bool {
    for attempt in 0..5 {
        if get_playlist(api, playlist_id, Some(1)).await.is_ok() {
            return true;
        }
        tracing::debug!(playlist_id, attempt, "the new playlist is not readable yet");
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    false
}

pub async fn set_playlist_thumbnail(
    api: &dyn Browse,
    http: &reqwest::Client,
    headers: &BTreeMap<String, String>,
    playlist_id: &str,
    image: &Path,
) -> Result<(), NetError> {
    let bytes = tokio::fs::read(image).await?;
    let referer = format!("https://music.youtube.com/playlist?list={playlist_id}");
    let session = |mut request: reqwest::RequestBuilder| {
        for (name, value) in headers.iter().filter(|(name, _)| {
            !matches!(
                name.as_str(),
                "Content-Type" | "Accept-Encoding" | "Content-Encoding" | "Content-Length"
            )
        }) {
            request = request.header(name, value);
        }
        request
            .header("Origin", "https://music.youtube.com")
            .header("Referer", &referer)
    };

    let start = session(
        http.post("https://music.youtube.com/playlist_image_upload/playlist_custom_thumbnail"),
    )
    .header(
        "Content-Type",
        "application/x-www-form-urlencoded;charset=utf-8",
    )
    .header("X-Goog-Upload-Command", "start")
    .header("X-Goog-Upload-Protocol", "resumable")
    .header(
        "X-Goog-Upload-Header-Content-Length",
        bytes.len().to_string(),
    )
    .body(Vec::new())
    .send()
    .await?;
    let upload_url = start
        .headers()
        .get("X-Goog-Upload-URL")
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned)
        .ok_or_else(|| message(format!("cover upload refused: HTTP {}", start.status())))?;

    let upload = session(http.post(&upload_url))
        .header(
            "Content-Type",
            "application/x-www-form-urlencoded;charset=utf-8",
        )
        .header("X-Goog-Upload-Command", "upload, finalize")
        .header("X-Goog-Upload-Offset", "0")
        .body(bytes)
        .send()
        .await?
        .error_for_status()?;
    let blob: Value = upload.json().await?;
    let blob_id = owned_at(&blob, "/encryptedBlobId")
        .ok_or_else(|| message("the upload returned no blob id"))?;

    let actions = json!([{
        "action": "ACTION_SET_CUSTOM_THUMBNAIL",
        "addedCustomThumbnail": {
            "imageKey": {
                "type": "PLAYLIST_IMAGE_TYPE_CUSTOM_THUMBNAIL",
                "name": "studio_square_thumbnail"
            },
            "playlistScottyEncryptedBlobId": blob_id,
        },
    }]);
    let response = api
        .post(
            "browse/edit_playlist",
            json!({ "playlistId": playlist_id.trim_start_matches("VL"), "actions": actions }),
        )
        .await?;
    match str_at(&response, "/status") {
        Some("STATUS_SUCCEEDED") => Ok(()),
        other => Err(message(format!(
            "the cover was not accepted: {}",
            other.unwrap_or("no status")
        ))),
    }
}

pub async fn delete_playlist(api: &dyn Browse, playlist_id: &str) -> Result<(), NetError> {
    api.post(
        "playlist/delete",
        json!({ "playlistId": playlist_id.trim_start_matches("VL") }),
    )
    .await?;
    Ok(())
}

pub async fn fetch_library_ids(
    api: Arc<dyn Browse>,
) -> Result<(LibraryIds, Vec<MediaItem>), NetError> {
    let playlists = library::library_playlists(api.clone())
        .await
        .unwrap_or_default();
    let albums = library::library_albums(api).await.unwrap_or_default();
    let mut ids = LibraryIds::default();
    ids.playlists.extend(playlists.iter().map(|p| p.id.clone()));
    for album in &albums {
        ids.albums.insert(album.id.clone());
        if let Some(pid) = &album.playlist_id {
            ids.albums.insert(pid.clone());
        }
    }
    Ok((ids, playlists))
}

pub fn editable_playlists(playlists: &[MediaItem], account_name: Option<&str>) -> Vec<MediaItem> {
    let user = account_name.map(|n| n.to_lowercase()).unwrap_or_default();
    playlists
        .iter()
        .filter(|p| {
            let pid = p.id.as_str();
            if !(pid.starts_with("PL") || pid.starts_with("VL"))
                || ["LM", "SE", "VLLM"].contains(&pid)
            {
                return false;
            }
            let author = p
                .artists
                .first()
                .map(|a| a.name.to_lowercase())
                .unwrap_or_default();
            author.is_empty() || author == "you" || (!user.is_empty() && author == user)
        })
        .cloned()
        .collect()
}

pub fn is_own_playlist(
    details: &PlaylistDetails,
    playlist_id: &str,
    account_name: Option<&str>,
) -> bool {
    let pid = if playlist_id.is_empty() {
        details.id.as_str()
    } else {
        playlist_id
    };
    owns_playlist(
        pid,
        details.author.first().map(|a| a.name.as_str()),
        details.collaborators.as_deref(),
        account_name,
    )
}

pub fn owns_playlist(
    playlist_id: &str,
    author: Option<&str>,
    collaborators: Option<&str>,
    account_name: Option<&str>,
) -> bool {
    let Some(user_name) = account_name.filter(|n| !n.is_empty()) else {
        return false;
    };
    if ["LM", "SE", "VLLM"].contains(&playlist_id)
        || !(playlist_id.starts_with("PL") || playlist_id.starts_with("VL"))
    {
        return false;
    }
    let author = match (collaborators, author) {
        (None, None) => return true,
        (Some(text), _) => text,
        (None, Some(name)) => name,
    };
    if collaborators.is_some() && author.contains(user_name) {
        return true;
    }
    author == user_name
}

fn normalize_browse_playlist_id(playlist_id: &str) -> Option<String> {
    let pid = playlist_id.trim();
    if pid.is_empty() {
        return None;
    }
    Some(if pid.starts_with("VL") {
        pid.to_owned()
    } else {
        format!("VL{pid}")
    })
}

pub async fn playlist_added_dates(
    api: &dyn Browse,
    playlist_id: &str,
) -> Result<SortMetric, NetError> {
    let Some(browse_id) = normalize_browse_playlist_id(playlist_id) else {
        return Ok(SortMetric::new());
    };
    let mut dates = SortMetric::new();
    let mut response = api.post("browse", json!({ "browseId": browse_id })).await?;
    for _ in 0..MAX_METRIC_PAGES {
        for item in walk_key(&response, "playlistItemData") {
            if let (Some(vid), Some(added)) = (
                str_at(item, "/videoId"),
                item.get("voteSortValue").and_then(Value::as_i64),
            ) {
                dates.entry(vid.to_owned()).or_insert(added);
            }
        }
        let Some(token) = continuation_token_for_rows(&response, &[MRLIR]) else {
            break;
        };
        response = match api.post("browse", json!({ "continuation": token })).await {
            Ok(r) => r,
            Err(err) => {
                tracing::warn!(%err, browse_id, "added-date fetch failed");
                break;
            }
        };
    }
    tracing::info!(count = dates.len(), browse_id, "added dates");
    Ok(dates)
}

fn parse_view_count(text: &str) -> Option<i64> {
    let text = text.trim();
    if text.to_lowercase().starts_with("no view") {
        return Some(0);
    }
    let caps = VIEWS_RE.captures(text)?;
    let number: f64 = caps[1].replace(',', "").parse().ok()?;
    let multiplier = match caps.get(2).map(|m| m.as_str().to_uppercase()).as_deref() {
        Some("K") => 1_000.0,
        Some("M") => 1_000_000.0,
        Some("B") => 1_000_000_000.0,
        _ => 1.0,
    };
    Some((number * multiplier) as i64)
}

fn harvest_view_counts(response: &Value, out: &mut SortMetric) {
    for lockup in walk_key(response, "lockupViewModel") {
        if str_at(lockup, "/contentType") != Some("LOCKUP_CONTENT_TYPE_VIDEO") {
            continue;
        }
        let Some(vid) = str_at(lockup, "/contentId") else {
            continue;
        };
        if out.contains_key(vid) {
            continue;
        }
        'rows: for row in array_at(
            lockup,
            "/metadata/lockupMetadataViewModel/metadata/contentMetadataViewModel/metadataRows",
        ) {
            for part in array_at(row, "/metadataParts") {
                if let Some(count) = str_at(part, "/text/content").and_then(parse_view_count) {
                    out.insert(vid.to_owned(), count);
                    break 'rows;
                }
            }
        }
    }
    for item in walk_key(response, "playlistVideoRenderer") {
        let Some(vid) = str_at(item, "/videoId") else {
            continue;
        };
        if out.contains_key(vid) {
            continue;
        }
        for run in array_at(item, "/videoInfo/runs") {
            if let Some(count) = str_at(run, "/text").and_then(parse_view_count) {
                out.insert(vid.to_owned(), count);
                break;
            }
        }
    }
}

fn sapisid_hash(cookie: &str, origin: &str) -> Option<String> {
    use sha1::{Digest, Sha1};
    let sapisid = cookie.split(';').map(str::trim).find_map(|p| {
        p.strip_prefix("__Secure-3PAPISID=")
            .or_else(|| p.strip_prefix("SAPISID="))
    })?;
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs();
    let digest = Sha1::digest(format!("{ts} {sapisid} {origin}").as_bytes());
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    Some(format!("SAPISIDHASH {ts}_{hex}"))
}

pub async fn playlist_view_counts(
    http: &reqwest::Client,
    auth: Option<&HttpAuth>,
    playlist_id: &str,
) -> Result<SortMetric, NetError> {
    let Some(browse_id) = normalize_browse_playlist_id(playlist_id) else {
        return Ok(SortMetric::new());
    };
    let mut body = json!({
        "context": {
            "client": {
                "clientName": "WEB",
                "clientVersion": "2.20240101.00.00",
                "hl": "en",
                "gl": "US"
            }
        },
        "browseId": browse_id
    });
    let mut views = SortMetric::new();
    let send = |body: Value| {
        let mut request = http
            .post(YT_WEB_BROWSE_URL)
            .header("Content-Type", "application/json")
            .header("Accept-Language", "en-US,en;q=0.9")
            .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
            .header("Origin", "https://www.youtube.com")
            .header("Referer", "https://www.youtube.com/");
        if let Some(auth) = auth {
            if let Some(hash) = sapisid_hash(&auth.cookie, "https://www.youtube.com") {
                request = request
                    .header("Cookie", &auth.cookie)
                    .header("Authorization", hash)
                    .header("X-Origin", "https://www.youtube.com");
            }
        }
        request.json(&body).send()
    };
    let mut response: Value = match send(body.clone()).await {
        Ok(r) => r.json().await?,
        Err(err) => {
            tracing::warn!(%err, browse_id, "view-count fetch failed");
            return Ok(views);
        }
    };
    for _ in 0..MAX_METRIC_PAGES {
        harvest_view_counts(&response, &mut views);
        let Some(token) =
            continuation_token_for_rows(&response, &["lockupViewModel", "playlistVideoRenderer"])
        else {
            break;
        };
        if let Some(map) = body.as_object_mut() {
            map.remove("browseId");
            map.insert("continuation".into(), json!(token));
        }
        response = match send(body.clone()).await {
            Ok(r) => match r.json().await {
                Ok(v) => v,
                Err(_) => break,
            },
            Err(err) => {
                tracing::warn!(%err, browse_id, "view-count page failed");
                break;
            }
        };
    }
    tracing::info!(count = views.len(), browse_id, "view counts");
    Ok(views)
}

async fn fetch_continuation(api: &dyn Browse, token: Option<String>) -> Vec<MediaItem> {
    Continuation::browse(api, token)
        .pages(MAX_CONTINUATION_PAGES)
        .collect(|entries| {
            entries
                .iter()
                .filter_map(|e| parse_channel_item(e))
                .collect()
        })
        .await
        .items
}

pub async fn raw_parse_channel_content(
    api: &dyn Browse,
    browse_id: &str,
    params: Option<&str>,
) -> Result<Vec<MediaItem>, NetError> {
    let mut body = json!({ "browseId": browse_id });
    if let Some(p) = params {
        body["params"] = json!(p);
    }
    let response = api.post("browse", body).await?;
    let mut items = Vec::new();
    for section in array_at(&response, SINGLE_SECTIONS) {
        for key in [
            "gridRenderer",
            "musicShelfRenderer",
            "musicPlaylistShelfRenderer",
            "musicCarouselShelfRenderer",
        ] {
            let Some(renderer) = section.get(key) else {
                continue;
            };
            let entries = if renderer.get("items").is_some() {
                array_at(renderer, "/items")
            } else {
                array_at(renderer, "/contents")
            };
            for raw in entries {
                items.extend(parse_channel_item(raw));
                if let Some(token) = item_continuation_token(raw) {
                    items.extend(fetch_continuation(api, Some(token)).await);
                }
            }
        }
    }
    Ok(items)
}

pub async fn raw_parse_playlist(
    api: &dyn Browse,
    browse_id: &str,
) -> Result<(Option<String>, Vec<MediaItem>), NetError> {
    let response = api.post("browse", json!({ "browseId": browse_id })).await?;
    let mut items = Vec::new();
    for section in array_at(&response, SECONDARY_SECTIONS) {
        for key in ["musicPlaylistShelfRenderer", "musicShelfRenderer"] {
            let Some(renderer) = section.get(key) else {
                continue;
            };
            for raw in array_at(renderer, "/contents") {
                match item_continuation_token(raw) {
                    Some(token) => items.extend(fetch_continuation(api, Some(token)).await),
                    None => items.extend(parse_channel_item(raw)),
                }
            }
        }
    }
    if items.is_empty() {
        items = raw_parse_channel_content(api, browse_id, None).await?;
    }
    let title = response
        .get("header")
        .and_then(Value::as_object)
        .and_then(|h| h.values().find_map(|v| owned_at(v, "/title/runs/0/text")));
    Ok((title, items))
}

pub async fn artist_albums(
    api: &dyn Browse,
    channel_id: &str,
    params: Option<&str>,
    limit: Option<usize>,
) -> Result<Vec<MediaItem>, NetError> {
    let mut body = json!({ "browseId": channel_id });
    if let Some(p) = params {
        body["params"] = json!(p);
    }
    if let Ok(response) = api.post("browse", body).await {
        let results = response.pointer(&format!("{SINGLE_SECTIONS}/0"));
        if let Some(results) = results {
            let grid = results.get("gridRenderer");
            let contents = grid
                .map(|g| array_at(g, "/items"))
                .filter(|c| !c.is_empty())
                .unwrap_or_else(|| array_at(results, "/musicCarouselShelfRenderer/contents"));
            let mut albums: Vec<MediaItem> = contents
                .iter()
                .filter_map(|c| parse_two_row(c, ItemKind::Album))
                .collect();
            let wanted = limit.unwrap_or(usize::MAX);
            if albums.len() < wanted {
                let rest = Continuation::browse(api, grid.and_then(next_continuation))
                    .pages(MAX_CONTINUATION_PAGES)
                    .limit(wanted - albums.len())
                    .collect(|entries| {
                        entries
                            .iter()
                            .filter_map(|c| parse_two_row(c, ItemKind::Album))
                            .collect()
                    })
                    .await;
                albums.extend(rest.items);
            }
            albums.truncate(wanted);
            if !albums.is_empty() {
                return Ok(albums);
            }
            let playlists: Vec<MediaItem> = contents
                .iter()
                .filter_map(|c| parse_two_row(c, ItemKind::Playlist))
                .collect();
            if !playlists.is_empty() {
                return Ok(playlists);
            }
        }
    }
    raw_parse_channel_content(api, channel_id, params).await
}

pub fn track_search_text(track: &Track) -> (String, String, String) {
    (
        track.title.to_lowercase(),
        track.artist.to_lowercase(),
        track
            .album
            .as_ref()
            .map(|a| a.name.to_lowercase())
            .unwrap_or_default(),
    )
}

#[derive(Default, Serialize)]
pub struct SectionPage {
    pub items: Vec<MediaItem>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub continuation: Option<String>,
}

#[derive(Deserialize)]
pub struct SectionArgs {
    #[serde(default)]
    pub browse_id: Option<String>,
    #[serde(default)]
    pub params: Option<String>,
    #[serde(default)]
    pub continuation: Option<String>,
}

pub async fn browse_section_page(
    api: &dyn Browse,
    args: &SectionArgs,
) -> Result<SectionPage, NetError> {
    let mut body = json!({});
    if let Some(c) = args.continuation.as_deref().filter(|s| !s.is_empty()) {
        body["continuation"] = json!(c);
    } else {
        let b = args
            .browse_id
            .as_deref()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| NetError::Message("browse_id required for the first page".into()))?;
        body["browseId"] = json!(b);
        if let Some(p) = args.params.as_deref().filter(|s| !s.is_empty()) {
            body["params"] = json!(p);
        }
    }
    let response = api.post("browse", body).await?;
    Ok(extract_section_page(&response))
}

fn extract_section_page(response: &Value) -> SectionPage {
    let mut items: Vec<MediaItem> = Vec::new();
    let mut token: Option<String> = find_continuation_token(response);

    for section in array_at(response, SINGLE_SECTIONS)
        .iter()
        .chain(array_at(response, SECONDARY_SECTIONS).iter())
    {
        harvest_section(section, &mut items, &mut token);
    }

    if items.is_empty() {
        for section in walk_sections(response) {
            harvest_section(section, &mut items, &mut token);
        }
    }

    if token.is_none() {
        for action in array_at(response, "/onResponseReceivedActions") {
            for raw in array_at(action, "/appendContinuationItemsAction/continuationItems") {
                if let Some(t) = item_continuation_token(raw) {
                    token = Some(t);
                    continue;
                }
                if let Some(item) = parse_channel_item(raw) {
                    items.push(item);
                }
            }
        }
    }

    SectionPage {
        items,
        continuation: token,
    }
}

fn find_continuation_token(root: &Value) -> Option<String> {
    for node in walk_key(root, "continuationItemRenderer") {
        if let Some(t) = owned_at(node, "/continuationEndpoint/continuationCommand/token") {
            return Some(t);
        }
    }
    for node in walk_key(root, "nextContinuationData") {
        if let Some(t) = owned_at(node, "/continuation") {
            return Some(t);
        }
    }
    for node in walk_key(root, "nextRadioContinuationData") {
        if let Some(t) = owned_at(node, "/continuation") {
            return Some(t);
        }
    }
    None
}

fn harvest_section(section: &Value, items: &mut Vec<MediaItem>, token: &mut Option<String>) {
    const KEYS: [&str; 4] = [
        "gridRenderer",
        "musicShelfRenderer",
        "musicPlaylistShelfRenderer",
        "musicCarouselShelfRenderer",
    ];
    for key in KEYS {
        let Some(renderer) = section.get(key) else {
            continue;
        };
        let entries = if renderer.get("items").is_some() {
            array_at(renderer, "/items")
        } else {
            array_at(renderer, "/contents")
        };
        for raw in entries {
            if let Some(t) = item_continuation_token(raw) {
                *token = Some(t);
                continue;
            }
            if let Some(item) = parse_channel_item(raw) {
                items.push(item);
            }
        }
        if token.is_none() {
            if let Some(t) = next_continuation(renderer) {
                *token = Some(t);
            }
        }
    }
}

fn walk_sections(root: &Value) -> Vec<&Value> {
    const KEYS: [&str; 4] = [
        "gridRenderer",
        "musicShelfRenderer",
        "musicPlaylistShelfRenderer",
        "musicCarouselShelfRenderer",
    ];
    let mut out: Vec<&Value> = Vec::new();
    let mut stack: Vec<&Value> = vec![root];
    while let Some(node) = stack.pop() {
        match node {
            Value::Object(map) => {
                if KEYS.iter().any(|k| map.contains_key(*k)) {
                    out.push(node);
                }
                stack.extend(map.values());
            }
            Value::Array(items) => stack.extend(items.iter()),
            _ => {}
        }
    }
    out
}
