use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use regex::Regex;
use serde_json::{Value, json};

use crate::context::Paths;
use crate::net::media::{HttpAuth, StreamInfo, VideoId};
use crate::net::stream::{BoxFuture, ResolveError, StreamCache, StreamResolver};

const PLAYER_URL: &str = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false";
const CLIENT_NAME: &str = "VISIONOS";
const CLIENT_ID: &str = "101";
const CLIENT_VERSION: &str = "0.1";
const CLIENT_USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";
const LANDING_URL: &str = "https://music.youtube.com/";
const LANDING_USER_AGENT: &str =
    "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(8);
const VISITOR_TTL: Duration = Duration::from_secs(6 * 3600);
const PROBE_OFFSET: u64 = 200_000;

#[derive(Clone, Debug, PartialEq)]
struct Format {
    itag: u32,
    url: String,
    mime: String,
    bitrate: u64,
    content_length: u64,
}

impl Format {
    fn is_opus(&self) -> bool {
        self.mime.contains("opus")
    }
}

fn audio_formats(response: &Value) -> Vec<Format> {
    let Some(list) = response
        .pointer("/streamingData/adaptiveFormats")
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    list.iter()
        .filter_map(|f| {
            let mime = f.get("mimeType")?.as_str()?;
            if !mime.starts_with("audio/") {
                return None;
            }
            if f.get("isDrc").and_then(Value::as_bool).unwrap_or(false)
                || f.pointer("/audioTrack/audioIsDefault")
                    .and_then(Value::as_bool)
                    == Some(false)
            {
                return None;
            }
            Some(Format {
                itag: f.get("itag")?.as_u64()? as u32,
                url: f.get("url")?.as_str()?.to_owned(),
                mime: mime.to_owned(),
                bitrate: f.get("bitrate").and_then(Value::as_u64).unwrap_or(0),
                content_length: f
                    .get("contentLength")
                    .and_then(Value::as_str)
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0),
            })
        })
        .collect()
}

fn quality_score(format: &Format) -> f64 {
    let bps = format.bitrate as f64;
    let factor = if format.is_opus() {
        if bps <= 64_000.0 {
            2.0
        } else if bps >= 256_000.0 {
            0.85
        } else {
            let t = (bps - 64_000.0) / (256_000.0 - 64_000.0);
            2.0 + t * (0.85 - 2.0)
        }
    } else {
        1.0
    };
    bps * factor
}

fn pick_format(formats: &[Format]) -> Option<&Format> {
    formats.iter().max_by(|a, b| {
        quality_score(a).partial_cmp(&quality_score(b)).unwrap_or(std::cmp::Ordering::Equal)
    })
}

fn refusal(response: &Value) -> Option<String> {
    let status = response
        .pointer("/playabilityStatus/status")
        .and_then(Value::as_str)
        .unwrap_or("missing");
    if status == "OK" {
        return None;
    }
    let reason = response
        .pointer("/playabilityStatus/reason")
        .and_then(Value::as_str)
        .unwrap_or_default();
    Some(format!("{status} {reason}").trim().to_owned())
}

fn player_body(video_id: &str, visitor: &str) -> Value {
    json!({
        "context": { "client": {
            "clientName": CLIENT_NAME,
            "clientVersion": CLIENT_VERSION,
            "deviceMake": "Apple",
            "deviceModel": "RealityDevice14,1",
            "osName": "visionOS",
            "osVersion": "1.3.21O771",
            "hl": "en",
            "gl": "US",
            "visitorData": visitor,
        }},
        "videoId": video_id,
        "contentCheckOk": true,
        "racyCheckOk": true,
    })
}

fn visitor_from_landing(html: &str) -> Option<String> {
    static PATTERN: std::sync::LazyLock<Regex> = std::sync::LazyLock::new(|| {
        Regex::new(r#""VISITOR_DATA":"([^"]+)""#).expect("static regex")
    });
    PATTERN.captures(html).map(|c| c[1].to_owned())
}

pub struct PlayerEndpointResolver {
    http: reqwest::Client,
    fallback: Arc<dyn StreamResolver>,
    cache: StreamCache,
    visitor: Mutex<Option<(String, Instant)>>,
}

impl PlayerEndpointResolver {
    pub fn new(paths: &Paths, fallback: Arc<dyn StreamResolver>) -> Self {
        let http = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .gzip(true)
            .build()
            .unwrap_or_default();
        Self {
            http,
            fallback,
            cache: StreamCache::new(paths.stream_cache_dir.clone()),
            visitor: Mutex::new(None),
        }
    }

    pub async fn warm(&self) {
        if let Err(err) = self.visitor_data().await {
            tracing::debug!(%err, "visitor data not warmed");
        }
    }

    async fn visitor_data(&self) -> Result<String, String> {
        if let Some((visitor, at)) = self.visitor.lock().unwrap().clone() {
            if at.elapsed() < VISITOR_TTL {
                return Ok(visitor);
            }
        }
        let html = self
            .http
            .get(LANDING_URL)
            .header("User-Agent", LANDING_USER_AGENT)
            .header("Cookie", "SOCS=CAI")
            .send()
            .await
            .map_err(|e| e.to_string())?
            .text()
            .await
            .map_err(|e| e.to_string())?;
        let visitor = visitor_from_landing(&html).ok_or("no visitor data on the landing page")?;
        *self.visitor.lock().unwrap() = Some((visitor.clone(), Instant::now()));
        Ok(visitor)
    }

    async fn resolve_native(&self, video_id: &VideoId) -> Result<StreamInfo, String> {
        let visitor = self.visitor_data().await?;
        let response: Value = self
            .http
            .post(PLAYER_URL)
            .header("User-Agent", CLIENT_USER_AGENT)
            .header("X-YouTube-Client-Name", CLIENT_ID)
            .header("X-YouTube-Client-Version", CLIENT_VERSION)
            .header("X-Goog-Visitor-Id", &visitor)
            .json(&player_body(video_id.as_str(), &visitor))
            .send()
            .await
            .map_err(|e| e.to_string())?
            .json()
            .await
            .map_err(|e| e.to_string())?;
        if let Some(reason) = refusal(&response) {
            if reason.contains("bot") {
                *self.visitor.lock().unwrap() = None;
            }
            return Err(reason);
        }
        if response
            .pointer("/videoDetails/videoId")
            .and_then(Value::as_str)
            .is_some_and(|id| id != video_id.as_str())
        {
            return Err("answered for a different video".to_owned());
        }

        // Live content arrives as HLS, which the audio player cannot
        // decode. Returning Err here drops us into the yt-dlp fallback.
        if response
            .pointer("/videoDetails/isLive")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            return Err("live content: deferring to the yt-dlp fallback".to_owned());
        }

        let formats = audio_formats(&response);
        let format = pick_format(&formats).ok_or("no direct audio url")?;

        tracing::debug!(
            %video_id,
            itag = format.itag,
            bitrate_kbps = format.bitrate / 1000,
            mime = %format.mime,
            content_length = format.content_length,
            available = formats.len(),
            "picked audio format"
        );

        self.probe(format).await?;
        Ok(StreamInfo {
            uri: format.url.clone(),
            format_id: Some(format.itag.to_string()),
            protocol: Some("https".to_owned()),
            ext: Some(if format.is_opus() { "webm" } else { "m4a" }.to_owned()),
            acodec: Some(if format.is_opus() { "opus" } else { "mp4a" }.to_owned()),
            title: response
                .pointer("/videoDetails/title")
                .and_then(Value::as_str)
                .map(str::to_owned),
            uploader: response
                .pointer("/videoDetails/author")
                .and_then(Value::as_str)
                .map(str::to_owned),
            thumbnail: None,
            is_local: false,
            from_cache: false,
            user_agent: Some(CLIENT_USER_AGENT.to_owned()),
            bitrate: Some(format.bitrate),
            sample_rate: None,
            channels: None,
        })
    }

    async fn probe(&self, format: &Format) -> Result<(), String> {
        let offset = if format.content_length > PROBE_OFFSET + 2 {
            PROBE_OFFSET
        } else {
            0
        };
        let status = self
            .http
            .get(&format.url)
            .header("User-Agent", CLIENT_USER_AGENT)
            .header("Range", format!("bytes={offset}-{}", offset + 1))
            .send()
            .await
            .map_err(|e| e.to_string())?
            .status();
        if status.is_success() {
            Ok(())
        } else {
            Err(format!("stream probe answered {status}"))
        }
    }
}

impl StreamResolver for PlayerEndpointResolver {
    fn resolve(
        &self,
        video_id: VideoId,
        auth: Option<HttpAuth>,
    ) -> BoxFuture<'_, Result<StreamInfo, ResolveError>> {
        Box::pin(async move {
            if let Some(mut info) = self.cache.get(&video_id).await {
                if info.format_id.is_none() {
                    tracing::debug!(%video_id, "dropping legacy cache entry without format metadata");
                    self.cache.invalidate(&video_id).await;
                } else if info.uri.contains("yt_live_broadcast")
                    || crate::audio::is_live_uri(&info.uri)
                {
                    self.cache.invalidate(&video_id).await;
                } else {
                    info.from_cache = true;
                    tracing::debug!(
                        %video_id,
                        itag = ?info.format_id,
                        bitrate = ?info.bitrate,
                        "served from cache"
                    );
                    return Ok(info);
                }
            }
            let started = Instant::now();
            match self.resolve_native(&video_id).await {
                Ok(info) => {
                    tracing::debug!(
                        %video_id,
                        itag = ?info.format_id,
                        took_ms = started.elapsed().as_millis() as u64,
                        "resolved through the player endpoint"
                    );
                    if info.protocol.as_deref() != Some("m3u8") {
                        self.cache.put(&video_id, &info).await;
                    }
                    Ok(info)
                }
                Err(reason) => {
                    tracing::debug!(%video_id, %reason, "player endpoint declined, falling back to yt-dlp");
                    self.fallback.resolve(video_id, auth).await
                }
            }
        })
    }

    fn invalidate(&self, video_id: &VideoId) -> BoxFuture<'_, ()> {
        self.fallback.invalidate(video_id)
    }
}
