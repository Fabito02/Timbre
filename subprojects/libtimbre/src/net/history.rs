use std::sync::{Arc, LazyLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use regex::Regex;
use serde::Serialize;
use serde_json::{Value, json};

use crate::net::NetError;
use crate::net::browse::Browse;
use crate::net::items::{MRLIR, array_at, history_feedback_token, owned_at, parse_playlist_item};
use crate::net::media::{HttpAuth, Track};
use crate::net::potoken::PoTokens;

const UNDATED: &str = "Recently";
const CPN_ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_";

const ATR_FALLBACK_SEC: f64 = 5.0;

const PLAYER_URL: &str = "https://music.youtube.com/youtubei/v1/player?prettyPrint=false";
const CLIENT_NAME_ID: &str = "67";
const CLIENT_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";

const PLAYER_TIMEOUT: Duration = Duration::from_secs(15);

const VISITOR_TTL: Duration = Duration::from_secs(6 * 3600);
const VISITOR_LANDING: &str = "https://music.youtube.com/";
const VISITOR_UA: &str = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0";
const VISITOR_PATTERN: &str = r#""VISITOR_DATA":"([^"]+)""#;

static VIEW_COUNT_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*\d+(?:[.,]\d+)?\s*[kKmMbB]?\s*views?\s*$").unwrap());

static VISITOR_CACHE: LazyLock<std::sync::Mutex<Option<(String, Instant)>>> =
    LazyLock::new(|| std::sync::Mutex::new(None));

#[derive(Clone, Debug, Serialize)]
pub struct HistoryEntry {
    pub track: Track,
    pub played: String,
    pub feedback_token: Option<String>,
}

#[derive(Clone, Debug)]
pub struct PlaySession {
    pub video_id: String,
    pub cpn: String,
    pub playback_url: String,
    pub watchtime_url: Option<String>,
    pub atr_url: Option<String>,
    pub atr_after_sec: f64,
    pub reported_secs: f64,
    pub atr_sent: bool,
    pub visitor_data: Option<String>,
}

impl PlaySession {
    pub fn video_id(&self) -> &str {
        &self.video_id
    }
}

pub async fn get_history(api: Arc<dyn Browse>) -> Result<Vec<HistoryEntry>, NetError> {
    let response = api
        .post("browse", json!({ "browseId": "FEmusic_history" }))
        .await?;
    Ok(parse_history(&response))
}

pub fn parse_history(response: &Value) -> Vec<HistoryEntry> {
    let sections = array_at(
        response,
        "/contents/singleColumnBrowseResultsRenderer/tabs/0/tabRenderer/content/sectionListRenderer/contents",
    );
    let mut entries = Vec::new();
    for section in sections {
        let Some(shelf) = section.get("musicShelfRenderer") else {
            continue;
        };
        let played = owned_at(shelf, "/title/runs/0/text").unwrap_or_else(|| UNDATED.to_owned());
        for row in array_at(shelf, "/contents") {
            let Some(data) = row.get(MRLIR) else { continue };
            let Some(mut track) = parse_playlist_item(data, false, false) else {
                continue;
            };
            if track.video_id.0.is_empty() {
                continue;
            }
            track.artists.retain(|a| !is_view_count(&a.name));
            track.artist = track
                .artists
                .iter()
                .map(|a| a.name.as_str())
                .filter(|n| !n.is_empty())
                .collect::<Vec<_>>()
                .join(", ");
            entries.push(HistoryEntry {
                track,
                played: played.clone(),
                feedback_token: history_feedback_token(data),
            });
        }
    }
    entries
}

fn is_view_count(text: &str) -> bool {
    VIEW_COUNT_RE.is_match(text)
}

pub async fn remove_history_items(api: &dyn Browse, tokens: Vec<String>) -> Result<(), NetError> {
    if tokens.is_empty() {
        return Ok(());
    }
    api.post("feedback", json!({ "feedbackTokens": tokens }))
        .await?;
    Ok(())
}

/// Today in WEB_REMIX's `clientVersion` format (`1.YYYYMMDD.01.00`).
fn web_remix_version() -> String {
    let days = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
        / 86400;
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("1.{:04}{:02}{:02}.01.00", y, m, d)
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (hex_val(bytes[i + 1]), hex_val(bytes[i + 2])) {
                out.push((h << 4) | l);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

async fn visitor_data(http: &reqwest::Client) -> Option<String> {
    if let Some((value, at)) = VISITOR_CACHE.lock().unwrap().clone() {
        if at.elapsed() < VISITOR_TTL {
            return Some(value);
        }
    }
    let html = http
        .get(VISITOR_LANDING)
        .header("User-Agent", VISITOR_UA)
        .header("Cookie", "SOCS=CAI")
        .send()
        .await
        .ok()?
        .text()
        .await
        .ok()?;
    static RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(VISITOR_PATTERN).unwrap());
    let visitor = percent_decode(RE.captures(&html)?.get(1)?.as_str());
    *VISITOR_CACHE.lock().unwrap() = Some((visitor.clone(), Instant::now()));
    Some(visitor)
}

pub async fn begin_play(
    http: &reqwest::Client,
    auth: Option<&HttpAuth>,
    video_id: &str,
    _tokens: &PoTokens,
    signature_timestamp: Option<u64>,
) -> Result<PlaySession, NetError> {
    // NOTE: We intentionally do NOT mint a PO token here anymore.
    //
    // The /player call below is only used to obtain the tracking URLs
    // (videostatsPlaybackUrl, videostatsWatchtimeUrl, atrUrl) that the
    // history reporter pings. For a signed-in user those are returned
    // without a PO token. For an anonymous user this whole function is
    // skipped upstream by `timbre_player_record_play_start`, so we never
    // reach this code without a session.
    //
    // Minting a PO token here used to spawn the BotGuard worker
    // (~40 MB baseline RAM) on every single track played, even though
    // the VISIONOS resolver had already served the audio without any
    // token. `yt-dlp` (which genuinely needs the token) is invoked
    // only as a fallback when VISIONOS fails, and mints tokens itself
    // in that path.
    let visitor = visitor_data(http).await;
    let version = web_remix_version();

    let mut body = json!({
        "context": {
            "client": {
                "clientName": "WEB_REMIX",
                "clientVersion": version,
                "hl": "en",
                "gl": "US",
            }
        },
        "videoId": video_id,
        "contentCheckOk": true,
        "racyCheckOk": true,
    });
    if let Some(v) = &visitor {
        body["context"]["client"]["visitorData"] = json!(v);
    }
    if let Some(sts) = signature_timestamp {
        body["playbackContext"] = json!({
            "contentPlaybackContext": {
                "html5Preference": "HTML5_PREF_WANTS",
                "referer": format!("https://music.youtube.com/watch?v={video_id}"),
                "signatureTimestamp": sts,
            }
        });
    }

    let mut request = http
        .post(PLAYER_URL)
        .header("User-Agent", CLIENT_UA)
        .header("X-YouTube-Client-Name", CLIENT_NAME_ID)
        .header("X-YouTube-Client-Version", &version)
        .header("X-Origin", "https://music.youtube.com")
        .header("Origin", "https://music.youtube.com")
        .header("Referer", "https://music.youtube.com/")
        .json(&body);
    if let Some(v) = &visitor {
        request = request.header("X-Goog-Visitor-Id", v);
    }
    if let Some(auth) = auth {
        request = request.header("Cookie", &auth.cookie);
        if let Some(authz) = &auth.authorization {
            request = request.header("Authorization", authz);
        }
    }

    let (status, text) = match tokio::time::timeout(PLAYER_TIMEOUT, async {
        let resp = request.send().await?;
        let status = resp.status();
        let text = resp.text().await?;
        Ok::<_, reqwest::Error>((status, text))
    })
    .await
    {
        Ok(Ok(pair)) => pair,
        Ok(Err(e)) => return Err(NetError::Transport(e)),
        Err(_) => {
            return Err(NetError::Message(format!(
                "{video_id}: /player timed out after {:?}",
                PLAYER_TIMEOUT
            )));
        }
    };

    let value: Value = serde_json::from_str(&text).map_err(|e| {
        NetError::Message(format!(
            "{video_id}: invalid JSON in /player (HTTP {status}): {e}"
        ))
    })?;

    let playability = value
        .pointer("/playabilityStatus/status")
        .and_then(Value::as_str)
        .unwrap_or("?");
    if playability != "OK" {
        let reason = value
            .pointer("/playabilityStatus/reason")
            .and_then(Value::as_str)
            .unwrap_or("");
        return Err(NetError::Message(format!(
            "{video_id}: {playability} {reason}"
        )));
    }

    let tracking = value
        .get("playbackTracking")
        .and_then(Value::as_object)
        .ok_or_else(|| NetError::Message(format!("{video_id}: no playbackTracking")))?;

    let playback_url = tracking
        .get("videostatsPlaybackUrl")
        .and_then(|v| v.get("baseUrl"))
        .and_then(Value::as_str)
        .ok_or_else(|| NetError::Message(format!("{video_id}: no videostatsPlaybackUrl")))?
        .to_owned();
    let watchtime_url = tracking
        .get("videostatsWatchtimeUrl")
        .and_then(|v| v.get("baseUrl"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    let atr_url = tracking
        .get("atrUrl")
        .and_then(|v| v.get("baseUrl"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    let atr_after_sec = tracking
        .get("atrUrl")
        .and_then(|v| v.get("elapsedMediaTimeSeconds"))
        .and_then(Value::as_f64)
        .filter(|s| *s > 0.0)
        .unwrap_or(ATR_FALLBACK_SEC);

    let cpn = cpn();
    send_stats(
        http,
        auth,
        &playback_url,
        &cpn,
        &[],
        visitor.as_deref(),
        false,
    )
    .await?;

    Ok(PlaySession {
        video_id: video_id.to_owned(),
        cpn,
        playback_url,
        watchtime_url,
        atr_url,
        atr_after_sec,
        reported_secs: 0.0,
        atr_sent: false,
        visitor_data: visitor,
    })
}

pub async fn tick_play(
    http: &reqwest::Client,
    auth: Option<&HttpAuth>,
    session: &mut PlaySession,
    position_secs: f64,
) {
    let visitor = session.visitor_data.as_deref();

    if !session.atr_sent && position_secs >= session.atr_after_sec {
        if let Some(url) = session.atr_url.clone() {
            session.atr_sent = true;
            let _ = send_stats(http, auth, &url, &session.cpn, &[], visitor, true).await;
        }
    }

    let interval = if session.reported_secs < 30.0 {
        10.0
    } else {
        40.0
    };
    if position_secs - session.reported_secs >= interval {
        if let Some(url) = session.watchtime_url.clone() {
            let s = format!("{}", position_secs.floor() as i64);
            let extra: [(&str, &str); 4] = [
                ("st", "0"),
                ("et", s.as_str()),
                ("cmt", s.as_str()),
                ("state", "playing"),
            ];
            if send_stats(http, auth, &url, &session.cpn, &extra, visitor, false)
                .await
                .is_ok()
            {
                session.reported_secs = position_secs;
            }
        }
    }
}

pub async fn end_play(
    http: &reqwest::Client,
    auth: Option<&HttpAuth>,
    session: &PlaySession,
    final_position_secs: f64,
) {
    if let Some(url) = &session.watchtime_url {
        let end = final_position_secs.max(session.reported_secs).floor() as i64;
        let s = format!("{end}");
        let extra: [(&str, &str); 5] = [
            ("st", "0"),
            ("et", s.as_str()),
            ("cmt", s.as_str()),
            ("state", "paused"),
            ("final", "1"),
        ];
        let _ = send_stats(
            http,
            auth,
            url,
            &session.cpn,
            &extra,
            session.visitor_data.as_deref(),
            false,
        )
        .await;
    }
}

/// Stats pings return `204 No Content` on success. The `ver`/`c`/`cplayer`/
/// `hl`/`cr` params are required — the backend silently drops pings without
/// them. `Authorization` is intentionally omitted: the cookie is enough, and
/// SAPISIDHASH on a stats GET is ignored.
async fn send_stats(
    http: &reqwest::Client,
    auth: Option<&HttpAuth>,
    base_url: &str,
    cpn: &str,
    extra: &[(&str, &str)],
    visitor: Option<&str>,
    is_atr: bool,
) -> Result<(), NetError> {
    let mut url = String::with_capacity(base_url.len() + 128);
    url.push_str(base_url);

    // `atrUrl` already carries the client params in its base URL.
    if !is_atr {
        let sep = if url.contains('?') { '&' } else { '?' };
        url.push(sep);
        url.push_str("ver=2&c=WEB_REMIX&cplayer=UNIPLAYER&hl=pt_BR&cr=BR");
    }

    let sep = if url.contains('?') { '&' } else { '?' };
    url.push(sep);
    url.push_str("cpn=");
    url.push_str(cpn);
    for (k, v) in extra {
        url.push('&');
        url.push_str(k);
        url.push('=');
        url.push_str(v);
    }

    let mut request = http
        .get(&url)
        .header("User-Agent", CLIENT_UA)
        .header("Origin", "https://music.youtube.com")
        .header("X-Origin", "https://music.youtube.com")
        .header("Referer", "https://music.youtube.com/")
        .header("Accept", "*/*");
    if let Some(v) = visitor {
        request = request.header("X-Goog-Visitor-Id", v);
    }
    if let Some(auth) = auth {
        request = request.header("Cookie", &auth.cookie);
    }

    let status = request.send().await?.status();
    if !status.is_success() {
        return Err(NetError::Http {
            status: status.as_u16(),
            message: "playback ping refused".into(),
        });
    }
    Ok(())
}

fn cpn() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
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

    #[test]
    fn percent_decode_handles_padding() {
        assert_eq!(percent_decode("abc%3D"), "abc=");
        assert_eq!(percent_decode("a%2Bb"), "a+b");
        assert_eq!(percent_decode("no-escapes"), "no-escapes");
    }
}
