use std::sync::{Arc, LazyLock};

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::context::Paths;
use crate::net::browse::Browse;
use crate::net::items::{array_at, history_feedback_token, owned_at, parse_playlist_item, MRLIR};
use crate::net::media::{HttpAuth, LikeStatus, Named, Person, Track, VideoId};
use crate::net::NetError;

const UNDATED: &str = "Recently";
const CLIENT_NAME: &str = "WEB_REMIX";
const CPN_ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_";
const HISTORY_CACHE_FILE: &str = "history_cache.json";

static VIEW_COUNT_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*\d+(?:[.,]\d+)?\s*[kKmMbB]?\s*views?\s*$").unwrap());

#[derive(Clone, Debug, Serialize)]
pub struct HistoryEntry {
    pub track: Track,
    pub played: String,
    pub feedback_token: Option<String>,
}

pub async fn get_history(api: Arc<dyn Browse>) -> Result<Vec<HistoryEntry>, NetError> {
    let response = api.post("browse", json!({ "browseId": "FEmusic_history" })).await?;
    Ok(parse_history(&response))
}

pub fn parse_history(response: &Value) -> Vec<HistoryEntry> {
    let sections = array_at(
        response,
        "/contents/singleColumnBrowseResultsRenderer/tabs/0/tabRenderer/content/sectionListRenderer/contents",
    );
    let mut entries = Vec::new();
    for section in sections {
        let Some(shelf) = section.get("musicShelfRenderer") else { continue };
        let played = owned_at(shelf, "/title/runs/0/text").unwrap_or_else(|| UNDATED.to_owned());
        for row in array_at(shelf, "/contents") {
            let Some(data) = row.get(MRLIR) else { continue };
            let Some(track) = parse_playlist_item(data, false, false) else { continue };
            if track.video_id.0.is_empty() {
                continue;
            }
            entries.push(HistoryEntry {
                track: without_view_counts(track),
                played: played.clone(),
                feedback_token: history_feedback_token(data),
            });
        }
    }
    entries
}

fn without_view_counts(mut track: Track) -> Track {
    track.artists.retain(|artist| !is_view_count(&artist.name));
    track.artist = track
        .artists
        .iter()
        .map(|a| a.name.as_str())
        .filter(|n| !n.is_empty())
        .collect::<Vec<_>>()
        .join(", ");
    track
}

fn is_view_count(text: &str) -> bool {
    VIEW_COUNT_RE.is_match(text)
}

pub async fn remove_history_items(api: &dyn Browse, tokens: Vec<String>) -> Result<(), NetError> {
    if tokens.is_empty() {
        return Ok(());
    }
    api.post("feedback", json!({ "feedbackTokens": tokens })).await?;
    Ok(())
}

pub async fn record_play(
    api: &dyn Browse,
    http: &reqwest::Client,
    auth: Option<&HttpAuth>,
    video_id: &str,
) -> Result<Track, NetError> {
    let song = api.post("player", json!({ "videoId": video_id })).await?;
    let Some(url) = owned_at(&song, "/playbackTracking/videostatsPlaybackUrl/baseUrl") else {
        return Err(NetError::Message(format!("{video_id} has no playback tracker")));
    };
    let separator = if url.contains('?') { '&' } else { '?' };
    let url = format!("{url}{separator}ver=2&c={CLIENT_NAME}&cpn={}", cpn());
    let mut request = http.get(&url);
    if let Some(auth) = auth {
        request = request
            .header("Cookie", &auth.cookie)
            .header("User-Agent", &auth.user_agent);
        if let Some(authorization) = &auth.authorization {
            request = request.header("Authorization", authorization);
        }
    }
    let status = request.send().await?.status();
    if !status.is_success() {
        return Err(NetError::Http {
            status: status.as_u16(),
            message: "playback ping refused".into(),
        });
    }
    Ok(track_from_player(&song, video_id))
}

fn cpn() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let mut seed = now ^ (std::process::id() as u64).wrapping_mul(0x9e37_79b9_7f4a_7c15);
    (0..16)
        .map(|_| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            CPN_ALPHABET[(seed % CPN_ALPHABET.len() as u64) as usize] as char
        })
        .collect()
}

fn track_from_player(song: &Value, video_id: &str) -> Track {
    let details = song.pointer("/videoDetails").unwrap_or(&Value::Null);
    let author = owned_at(details, "/author").unwrap_or_default();
    let artists = if author.is_empty() {
        Vec::new()
    } else {
        vec![Person { name: author.clone(), id: owned_at(details, "/channelId") }]
    };
    Track {
        video_id: VideoId(video_id.to_owned()),
        title: owned_at(details, "/title").unwrap_or_default(),
        artist: author,
        artists,
        thumb: array_at(details, "/thumbnail/thumbnails")
            .last()
            .and_then(|t| owned_at(t, "/url")),
        duration_seconds: owned_at(details, "/lengthSeconds").and_then(|s| s.parse().ok()),
        ..Track::default()
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct CachedPlay {
    #[serde(rename = "videoId")]
    video_id: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    artists: Vec<Person>,
    #[serde(default)]
    album: Option<Named>,
    #[serde(default)]
    thumbnails: Vec<CachedThumbnail>,
    #[serde(default)]
    duration: Option<String>,
    #[serde(default)]
    duration_seconds: Option<u32>,
    #[serde(default, rename = "likeStatus")]
    like_status: Option<LikeStatus>,
    #[serde(default, rename = "isExplicit")]
    is_explicit: bool,
    #[serde(default)]
    played: Option<String>,
    #[serde(default, rename = "feedbackToken")]
    feedback_token: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct CachedThumbnail {
    url: String,
}

impl From<&HistoryEntry> for CachedPlay {
    fn from(entry: &HistoryEntry) -> Self {
        let track = &entry.track;
        Self {
            video_id: track.video_id.0.clone(),
            title: track.title.clone(),
            artists: track.artists.clone(),
            album: track.album.clone(),
            thumbnails: track
                .thumb
                .iter()
                .map(|url| CachedThumbnail { url: url.clone() })
                .collect(),
            duration: track
                .duration_seconds
                .map(|d| format!("{}:{:02}", d / 60, d % 60)),
            duration_seconds: track.duration_seconds,
            like_status: Some(track.like_status),
            is_explicit: track.is_explicit,
            played: Some(entry.played.clone()),
            feedback_token: entry.feedback_token.clone(),
        }
    }
}

impl From<CachedPlay> for HistoryEntry {
    fn from(play: CachedPlay) -> Self {
        let artist = play
            .artists
            .iter()
            .map(|a| a.name.as_str())
            .filter(|n| !n.is_empty())
            .collect::<Vec<_>>()
            .join(", ");
        HistoryEntry {
            track: Track {
                video_id: VideoId(play.video_id),
                title: play.title,
                artist,
                artists: play.artists,
                album: play.album,
                thumb: play.thumbnails.last().map(|t| t.url.clone()),
                duration_seconds: play
                    .duration_seconds
                    .or_else(|| play.duration.as_deref().and_then(parse_clock)),
                like_status: play.like_status.unwrap_or_default(),
                is_explicit: play.is_explicit,
                ..Track::default()
            },
            played: play.played.unwrap_or_else(|| UNDATED.to_owned()),
            feedback_token: play.feedback_token,
        }
    }
}

fn parse_clock(text: &str) -> Option<u32> {
    let mut total = 0u32;
    for part in text.split(':') {
        total = total.checked_mul(60)?.checked_add(part.parse().ok()?)?;
    }
    Some(total)
}

fn cache_path(paths: &Paths) -> std::path::PathBuf {
    paths.data_dir.join(HISTORY_CACHE_FILE)
}

pub fn cached_history(paths: &Paths) -> Vec<HistoryEntry> {
    let Ok(text) = std::fs::read_to_string(cache_path(paths)) else {
        return Vec::new();
    };
    match serde_json::from_str::<Vec<CachedPlay>>(&text) {
        Ok(plays) => plays.into_iter().map(HistoryEntry::from).collect(),
        Err(err) => {
            tracing::warn!(%err, "history cache unreadable");
            Vec::new()
        }
    }
}

pub fn cache_history(paths: &Paths, entries: &[HistoryEntry]) {
    let plays: Vec<CachedPlay> = entries.iter().map(CachedPlay::from).collect();
    let Ok(json) = serde_json::to_string(&plays) else {
        tracing::warn!("history cache not written");
        return;
    };
    if let Err(err) = std::fs::write(cache_path(paths), json) {
        tracing::warn!(%err, "history cache not written");
    }
}

pub fn forget_cached(paths: &Paths, video_id: &str) {
    let mut entries = cached_history(paths);
    let before = entries.len();
    entries.retain(|entry| entry.track.video_id.0 != video_id);
    if entries.len() != before {
        cache_history(paths, &entries);
    }
}

pub fn prepend_cached(paths: &Paths, track: &Track) {
    let mut entries = cached_history(paths);
    entries.retain(|entry| entry.track.video_id != track.video_id);
    entries.insert(
        0,
        HistoryEntry {
            track: track.clone(),
            played: "Today".to_owned(),
            feedback_token: None,
        },
    );
    cache_history(paths, &entries);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cpn_is_unique_and_sixteen_chars() {
        let a = cpn();
        let b = cpn();
        assert_eq!(a.len(), 16);
        assert_ne!(a, b);
        assert!(a.chars().all(|c| CPN_ALPHABET.contains(&(c as u8))));
    }

    #[test]
    fn a_view_count_is_not_an_artist() {
        assert!(is_view_count("7.2M views"));
        assert!(is_view_count("15 views"));
        assert!(!is_view_count("Jamie Paige"));
        assert!(!is_view_count("Views"));
    }
}
