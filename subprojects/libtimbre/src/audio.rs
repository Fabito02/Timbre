pub mod opus_source;
pub mod store;

use std::fs::File;
use std::io::BufReader;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use futures_util::StreamExt;
use rodio::{Decoder, DeviceSinkBuilder, MixerDeviceSink, Player, Source};
use serde::Serialize;

use crate::context::Paths;
use crate::net::media::{StreamInfo, VideoId};
use crate::stream_reader::{StreamBuffer, StreamReader};
use opus_source::{Mp4SparseSource, OpusSource};
use store::{AudioEntry, AudioStore, AudioWriter, StoreKind};

const DEFAULT_UA: &str = "Mozilla/5.0";
const PRE_BUFFER_THRESHOLD: usize = 1024;
const PRE_BUFFER_TIMEOUT: Duration = Duration::from_secs(3);
const PRE_BUFFER_POLL: Duration = Duration::from_millis(5);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const READ_TIMEOUT: Duration = Duration::from_secs(8);
const PROBE_TIMEOUT: Duration = Duration::from_secs(10);
const PROBE_SLOW_WARN: Duration = Duration::from_millis(500);

const RESUME_BACKOFF_MS: [u64; 6] = [1_000, 2_000, 4_000, 8_000, 15_000, 30_000];

const OPUS_HEADER_WINDOW: u64 = 64 * 1024;
const OPUS_WINDOW_PRE: u64 = 256 * 1024;
const OPUS_WINDOW_POST: u64 = 8 * 1024 * 1024;

const M4A_HEADER_MAX: u64 = 4 * 1024 * 1024;
const M4A_WINDOW_PRE: u64 = 1024 * 1024;
const M4A_WINDOW_POST: u64 = 8 * 1024 * 1024;

const TAIL_CHUNK: u64 = 4 * 1024 * 1024;

const CLUSTER_ID: [u8; 4] = [0x1F, 0x43, 0xB6, 0x75];

fn bitrate_for_itag(itag: &str) -> Option<u64> {
    match itag {
        "139" => Some(48_000),
        "140" => Some(128_000),
        "141" => Some(256_000),
        "249" => Some(50_000),
        "250" => Some(70_000),
        "251" => Some(160_000),
        "774" => Some(256_000),
        _ => None,
    }
}

fn itag_compatible(saved: Option<&str>, current: Option<&str>) -> bool {
    match (saved, current) {
        (Some(a), Some(b)) => a == b,
        _ => true,
    }
}

fn is_transient_http(status: reqwest::StatusCode) -> bool {
    matches!(status.as_u16(), 408 | 409 | 425 | 429)
}

fn first_cluster_offset(data: &[u8]) -> Option<usize> {
    data.windows(4).position(|w| w == CLUSTER_ID)
}

fn mp4_header_end(data: &[u8]) -> Option<u64> {
    let mut off: u64 = 0;
    while off + 8 <= data.len() as u64 {
        let i = off as usize;
        let raw_size = u32::from_be_bytes(data[i..i + 4].try_into().ok()?) as u64;
        let kind = &data[i + 4..i + 8];
        if raw_size == 0 {
            return None;
        }
        let size = if raw_size == 1 {
            if off + 16 > data.len() as u64 {
                return None;
            }
            u64::from_be_bytes(data[i + 8..i + 16].try_into().ok()?)
        } else {
            raw_size
        };
        if size < 8 {
            return None;
        }
        if kind == b"moov" {
            return Some(off + size);
        }
        off += size;
    }
    None
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct StreamStats {
    pub uri: String,
    pub format_id: Option<String>,
    pub protocol: Option<String>,
    pub ext: Option<String>,
    pub acodec: Option<String>,
    pub bitrate_kbps: Option<u64>,
    pub sample_rate_hz: Option<u32>,
    pub channels: Option<u16>,
    pub duration_seconds: Option<f64>,
    pub content_length_bytes: Option<u64>,
    pub from_cache: bool,
    pub is_local: bool,
}

struct AudioRig {
    _sink: MixerDeviceSink,
    player: Player,
}

pub struct AudioPlayer {
    rig: Arc<Mutex<Option<AudioRig>>>,
    position: Arc<Mutex<PlaybackPosition>>,
    total_duration: Arc<Mutex<Option<Duration>>>,
    current_url: Arc<Mutex<Option<String>>>,
    current_user_agent: Arc<Mutex<Option<String>>>,
    current_is_opus: Arc<Mutex<bool>>,
    stats: Arc<Mutex<StreamStats>>,
    active_buffer: Arc<Mutex<Option<StreamBuffer>>>,
    released_position: Arc<Mutex<Option<Duration>>>,
    client: reqwest::Client,
    generation: Arc<AtomicU64>,
    last_error: Arc<Mutex<Option<String>>>,
    store: Arc<AudioStore>,
}

struct PlaybackPosition {
    start_instant: Option<Instant>,
    accumulated: Duration,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlayerState {
    Playing,
    Paused,
    Stopped,
    Buffering,
    Loading,
    Error,
}

enum ResumeError {
    Cancelled,
    Transient(String),
    Permanent(String),
}

impl std::fmt::Display for ResumeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ResumeError::Cancelled => write!(f, "cancelled"),
            ResumeError::Transient(e) => write!(f, "transient: {e}"),
            ResumeError::Permanent(e) => write!(f, "permanent: {e}"),
        }
    }
}

impl AudioPlayer {
    pub fn new(paths: &Paths) -> Result<Self> {
        let rig = Self::build_rig()?;
        let client = reqwest::Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .read_timeout(READ_TIMEOUT)
            .build()
            .map_err(|e| anyhow::anyhow!("Failed to build audio http client: {e:?}"))?;
        Ok(Self {
            rig: Arc::new(Mutex::new(Some(rig))),
            position: Arc::new(Mutex::new(PlaybackPosition::new())),
            total_duration: Arc::new(Mutex::new(None)),
            current_url: Arc::new(Mutex::new(None)),
            current_user_agent: Arc::new(Mutex::new(None)),
            current_is_opus: Arc::new(Mutex::new(false)),
            stats: Arc::new(Mutex::new(StreamStats::default())),
            active_buffer: Arc::new(Mutex::new(None)),
            released_position: Arc::new(Mutex::new(None)),
            client,
            generation: Arc::new(AtomicU64::new(0)),
            last_error: Arc::new(Mutex::new(None)),
            store: Arc::new(AudioStore::new(paths)),
        })
    }

    fn build_rig() -> Result<AudioRig> {
        let mut sink = DeviceSinkBuilder::open_default_sink()
            .map_err(|e| anyhow::anyhow!("Failed to open default audio sink: {e:?}"))?;
        sink.log_on_drop(false);
        let player = Player::connect_new(&sink.mixer());
        Ok(AudioRig {
            _sink: sink,
            player,
        })
    }

    pub fn store(&self) -> &Arc<AudioStore> {
        &self.store
    }

    fn with_player<F, R>(&self, f: F) -> Option<R>
    where
        F: FnOnce(&Player) -> R,
    {
        self.rig.lock().unwrap().as_ref().map(|r| f(&r.player))
    }

    pub fn has_sink(&self) -> bool {
        self.rig.lock().unwrap().is_some()
    }

    pub fn rebuild_sink(&self) -> Result<()> {
        let rig = Self::build_rig()?;
        *self.rig.lock().unwrap() = Some(rig);
        Ok(())
    }

    pub fn release_sink(&self) {
        *self.rig.lock().unwrap() = None;
    }

    pub fn set_active(&self, active: bool) {
        if active {
            if !self.has_sink() {
                if let Err(e) = self.rebuild_sink() {
                    tracing::warn!(%e, "set_active: rebuild failed");
                }
            }
            return;
        }

        let should_release = match self.with_player(|p| (p.empty(), p.is_paused())) {
            Some((empty, paused)) => empty || paused,
            None => false,
        };
        if !should_release {
            return;
        }

        let pos = self.position.lock().unwrap().elapsed();
        if pos > Duration::ZERO {
            *self.released_position.lock().unwrap() = Some(pos);
        }
        self.release_sink();
    }

    pub fn begin_play(&self) -> u64 {
        let my_gen = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        if let Some(old) = self.active_buffer.lock().unwrap().take() {
            old.cancel();
        }
        self.with_player(|p| p.stop());
        self.position.lock().unwrap().reset();
        my_gen
    }

    pub fn generation(&self) -> u64 {
        self.generation.load(Ordering::SeqCst)
    }

    pub fn cancel_pending(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
    }

    pub fn take_error(&self) -> Option<String> {
        self.last_error.lock().unwrap().take()
    }

    pub fn stats(&self) -> StreamStats {
        self.stats.lock().unwrap().clone()
    }

    fn record_error(&self, msg: impl Into<String>) {
        *self.last_error.lock().unwrap() = Some(msg.into());
    }

    fn clear_error(&self) {
        *self.last_error.lock().unwrap() = None;
    }

    fn set_duration(&self, candidate: Option<Duration>) {
        if candidate.is_none() {
            return;
        }
        *self.total_duration.lock().unwrap() = candidate;
    }

    fn set_stats(&self, new_stats: StreamStats) {
        *self.stats.lock().unwrap() = new_stats;
    }

    fn sync_position(&self) {
        let Some((empty, paused)) = self.with_player(|p| (p.empty(), p.is_paused())) else {
            return;
        };
        if paused {
            return;
        }
        let mut pos = self.position.lock().unwrap();
        if empty {
            pos.pause_if_running();
        } else {
            pos.resume_if_stopped();
        }
    }

    pub async fn play_url(
        &self,
        my_gen: u64,
        video_id: Option<&VideoId>,
        url: &str,
        duration: Option<Duration>,
        user_agent: Option<&str>,
        info: Option<&StreamInfo>,
    ) -> Result<()> {
        let result = self
            .play_url_inner(my_gen, video_id, url, duration, user_agent, info)
            .await;
        if let Err(e) = &result {
            self.record_error(e.to_string());
        }
        result
    }

    async fn play_url_inner(
        &self,
        my_gen: u64,
        video_id: Option<&VideoId>,
        url: &str,
        duration: Option<Duration>,
        user_agent: Option<&str>,
        info: Option<&StreamInfo>,
    ) -> Result<()> {
        if self.generation.load(Ordering::SeqCst) != my_gen {
            return Err(anyhow::anyhow!("superseded by a newer play request"));
        }

        self.clear_error();
        let request_started = Instant::now();
        let ua = user_agent.unwrap_or(DEFAULT_UA).to_owned();

        if let Some(vid) = video_id {
            if let Some((kind, entry)) = self.store.lookup(vid.as_str()).await {
                let current_itag = info.and_then(|i| i.format_id.as_deref());
                let compatible = itag_compatible(entry.itag.as_deref(), current_itag);

                if entry.is_playable() && compatible {
                    let path = self.store.bin_path(kind, vid.as_str());
                    tracing::debug!(
                        %vid,
                        ?kind,
                        bytes = entry.downloaded_bytes,
                        "playing from disk (complete)"
                    );
                    return self
                        .play_local_file(my_gen, &path, &entry, duration, info)
                        .await;
                }

                if entry.is_resumable() && compatible {
                    tracing::debug!(
                        %vid,
                        ?kind,
                        bytes = entry.downloaded_bytes,
                        "resuming from partial"
                    );
                    return self
                        .play_partial(my_gen, &entry, kind, vid, url, user_agent, info, duration)
                        .await;
                }

                if !compatible && kind == StoreKind::Cache {
                    tracing::debug!(
                        %vid,
                        saved = ?entry.itag,
                        new = current_itag,
                        playable = entry.is_playable(),
                        resumable = entry.is_resumable(),
                        "cached format differs, dropping entry"
                    );
                    self.store.remove(vid.as_str()).await;
                }
            }
        }

        let response = self
            .client
            .get(url)
            .header("User-Agent", &ua)
            .send()
            .await
            .context("Failed to request audio stream")?;

        let headers_elapsed = request_started.elapsed();
        let status = response.status();
        let content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("?")
            .to_owned();
        let content_length = response.content_length();

        tracing::debug!(
            %status,
            %content_type,
            ?content_length,
            headers_ms = headers_elapsed.as_millis() as u64,
            gen = my_gen,
            "audio response headers received"
        );

        if !status.is_success() {
            return Err(anyhow::anyhow!("HTTP {status} while fetching audio"));
        }
        if content_type.starts_with("text/html") {
            return Err(anyhow::anyhow!(
                "the CDN returned {content_type} instead of audio (URL likely bound to another client)"
            ));
        }
        if content_type.contains("mpegurl") {
            return self.play_hls(my_gen, url, info).await;
        }

        if self.generation.load(Ordering::SeqCst) != my_gen {
            return Err(anyhow::anyhow!("superseded by a newer play request"));
        }

        let is_opus = content_type.contains("webm");
        let bitrate_bps = info.and_then(|i| i.bitrate).or_else(|| {
            info.and_then(|i| i.format_id.as_deref())
                .and_then(bitrate_for_itag)
        });
        let estimated = duration.or_else(|| estimate_duration(content_length, bitrate_bps));

        *self.current_url.lock().unwrap() = Some(url.to_string());
        *self.current_user_agent.lock().unwrap() = Some(ua.clone());
        *self.current_is_opus.lock().unwrap() = is_opus;
        self.set_duration(estimated);

        self.set_stats(StreamStats {
            uri: url.to_string(),
            format_id: info.and_then(|i| i.format_id.clone()),
            protocol: info.and_then(|i| i.protocol.clone()),
            ext: info.and_then(|i| i.ext.clone()),
            acodec: info.and_then(|i| i.acodec.clone()),
            bitrate_kbps: bitrate_bps.map(|b| b / 1000),
            sample_rate_hz: info.and_then(|i| i.sample_rate),
            channels: info.and_then(|i| i.channels),
            duration_seconds: estimated.map(|d| d.as_secs_f64()),
            content_length_bytes: content_length,
            from_cache: info.is_some_and(|i| i.from_cache),
            is_local: false,
        });

        if let Some(old) = self.active_buffer.lock().unwrap().take() {
            old.cancel();
        }

        let writer = self
            .prepare_writer(video_id, url, &ua, info, content_length, &content_type)
            .await;

        let outcome = if is_opus {
            self.play_opus_streaming(url, &ua, response, writer, my_gen, estimated)
                .await
        } else {
            self.play_streaming(url, &ua, response, writer, my_gen, estimated)
                .await
        };

        tracing::debug!(
            total_ms = request_started.elapsed().as_millis() as u64,
            ok = outcome.is_ok(),
            gen = my_gen,
            "play_url finished"
        );

        outcome
    }

    async fn play_hls(&self, my_gen: u64, url: &str, info: Option<&StreamInfo>) -> Result<()> {
        use hls_client::{config::ConfigBuilder, stream::HLSStream};
        use std::num::NonZeroUsize;
        use stream_download::{
            Settings, StreamDownload,
            storage::{adaptive::AdaptiveStorageProvider, temp::TempStorageProvider},
        };

        let hls_url = url.to_string();
        let settings = Settings::default();

        let stream = StreamDownload::new::<HLSStream>(
            ConfigBuilder::new()
                .url(&hls_url)
                .map_err(|e| anyhow::anyhow!("hls config: {e}"))?
                .build()
                .map_err(|e| anyhow::anyhow!("hls build: {e}"))?,
            AdaptiveStorageProvider::new(
                TempStorageProvider::new(),
                NonZeroUsize::new((settings.get_prefetch_bytes() * 2) as usize).unwrap(),
            ),
            settings,
        )
        .await
        .map_err(|e| anyhow::anyhow!("hls stream: {e}"))?;

        let source = tokio::task::spawn_blocking(move || {
            rodio::Decoder::new(stream).map_err(|e| anyhow::anyhow!("hls decode: {e:?}"))
        })
        .await
        .map_err(|e| anyhow::anyhow!("hls task: {e}"))??;

        self.set_stats(StreamStats {
            uri: url.to_string(),
            format_id: info.and_then(|i| i.format_id.clone()),
            protocol: Some("hls".to_owned()),
            ext: Some("hls".to_owned()),
            acodec: None,
            bitrate_kbps: None,
            sample_rate_hz: None,
            channels: None,
            duration_seconds: None,
            content_length_bytes: None,
            from_cache: false,
            is_local: false,
        });

        self.append_source(source, my_gen, None, false)
    }

    pub async fn try_play_cached(
        &self,
        my_gen: u64,
        video_id: &VideoId,
        duration: Option<Duration>,
    ) -> Result<Option<()>, String> {
        let Some((kind, entry)) = self.store.lookup(video_id.as_str()).await else {
            return Ok(None);
        };

        if !entry.is_playable() {
            return Ok(None);
        }

        let path = self.store.bin_path(kind, video_id.as_str());

        tracing::debug!(
            %video_id,
            ?kind,
            bytes = entry.downloaded_bytes,
            "play_track_id: cache hit, skipping resolve"
        );

        let cached_info = StreamInfo {
            uri: format!("file://{}", path.display()),
            format_id: entry.itag.clone(),
            protocol: Some("file".to_owned()),
            ext: entry.ext.clone(),
            acodec: entry.mime.clone(),
            title: entry.title.clone(),
            uploader: entry.artist.clone(),
            thumbnail: entry.thumb.clone(),
            is_local: true,
            from_cache: true,
            user_agent: None,
            bitrate: entry
                .itag
                .as_deref()
                .and_then(crate::net::items::parse_duration)
                .map(|_| 0)
                .filter(|_| false),
            sample_rate: None,
            channels: None,
        };

        if let Some(old) = self.active_buffer.lock().unwrap().take() {
            old.cancel();
        }
        self.with_player(|p| p.stop());
        self.position.lock().unwrap().reset();

        self.play_local_file(my_gen, &path, &entry, duration, Some(&cached_info))
            .await
            .map_err(|e| e.to_string())?;

        Ok(Some(()))
    }

    async fn prepare_writer(
        &self,
        video_id: Option<&VideoId>,
        url: &str,
        user_agent: &str,
        info: Option<&StreamInfo>,
        content_length: Option<u64>,
        content_type: &str,
    ) -> Option<AudioWriter> {
        let vid = video_id?;
        let meta = AudioEntry {
            video_id: vid.0.clone(),
            title: info.and_then(|i| i.title.clone()),
            artist: info.and_then(|i| i.uploader.clone()),
            thumb: info.and_then(|i| i.thumbnail.clone()),
            ext: info.and_then(|i| i.ext.clone()).or_else(|| {
                Some(if content_type.contains("webm") {
                    "webm".into()
                } else {
                    "m4a".into()
                })
            }),
            mime: Some(content_type.to_owned()),
            itag: info.and_then(|i| i.format_id.clone()),
            expected_size: content_length,
            user_agent: Some(user_agent.to_owned()),
            uri: Some(url.to_owned()),
            ..AudioEntry::default()
        };
        match self
            .store
            .open_writer(StoreKind::Cache, vid.as_str(), meta)
            .await
        {
            Ok(writer) => Some(writer),
            Err(err) => {
                tracing::warn!(%err, %vid, "cache writer open failed, playing without cache");
                None
            }
        }
    }

    async fn play_local_file(
        &self,
        my_gen: u64,
        path: &Path,
        entry: &AudioEntry,
        duration: Option<Duration>,
        info: Option<&StreamInfo>,
    ) -> Result<()> {
        let is_opus = entry
            .ext
            .as_deref()
            .map(|e| e == "webm" || e == "ogg")
            .unwrap_or(false);

        *self.current_is_opus.lock().unwrap() = is_opus;
        *self.current_url.lock().unwrap() = Some(format!("file://{}", path.display()));
        *self.current_user_agent.lock().unwrap() = None;

        let bitrate_bps = info.and_then(|i| i.bitrate).or_else(|| {
            info.and_then(|i| i.format_id.as_deref())
                .and_then(bitrate_for_itag)
        });
        let estimated =
            duration.or_else(|| estimate_duration(Some(entry.downloaded_bytes), bitrate_bps));
        self.set_duration(estimated);

        self.set_stats(StreamStats {
            uri: format!("file://{}", path.display()),
            format_id: entry.itag.clone(),
            protocol: Some("file".to_owned()),
            ext: entry.ext.clone(),
            acodec: Some(if is_opus { "opus" } else { "mp4a" }.to_owned()),
            bitrate_kbps: bitrate_bps.map(|b| b / 1000),
            sample_rate_hz: None,
            channels: None,
            duration_seconds: estimated.map(|d| d.as_secs_f64()),
            content_length_bytes: Some(entry.downloaded_bytes),
            from_cache: true,
            is_local: true,
        });

        if is_opus {
            let source = OpusSource::from_file(path)
                .map_err(|e| anyhow::anyhow!("opus source (local): {e}"))?;
            self.append_source(source, my_gen, estimated, true)
        } else {
            let file = File::open(path).with_context(|| format!("open {}", path.display()))?;
            let source = Decoder::try_from(BufReader::new(file))
                .map_err(|e| anyhow::anyhow!("decode local cache: {e:?}"))?;
            self.append_source(source, my_gen, estimated, true)
        }
    }

    async fn play_partial(
        &self,
        my_gen: u64,
        entry: &AudioEntry,
        kind: StoreKind,
        video_id: &VideoId,
        url: &str,
        user_agent: Option<&str>,
        info: Option<&StreamInfo>,
        duration: Option<Duration>,
    ) -> Result<()> {
        let ua = user_agent.unwrap_or(DEFAULT_UA).to_owned();

        let mut meta = entry.clone();
        if let Some(i) = info {
            if i.title.is_some() {
                meta.title = i.title.clone();
            }
            if i.uploader.is_some() {
                meta.artist = i.uploader.clone();
            }
            if i.thumbnail.is_some() {
                meta.thumb = i.thumbnail.clone();
            }
            if i.ext.is_some() {
                meta.ext = i.ext.clone();
            }
            if i.format_id.is_some() {
                meta.itag = i.format_id.clone();
            }
        }
        meta.user_agent = Some(ua.clone());
        meta.uri = Some(url.to_owned());

        let expected_bytes = entry.expected_size;

        let (reader, writer, _growth) = self
            .store
            .open_resumable(kind, video_id.as_str(), meta)
            .await
            .map_err(|e| anyhow::anyhow!("open resumable: {e}"))?;

        *self.current_url.lock().unwrap() = Some(url.to_string());
        *self.current_user_agent.lock().unwrap() = Some(ua.clone());
        let is_opus = entry
            .ext
            .as_deref()
            .map(|e| e == "webm" || e == "ogg")
            .unwrap_or(false);
        *self.current_is_opus.lock().unwrap() = is_opus;

        let bitrate_bps = info.and_then(|i| i.bitrate).or_else(|| {
            info.and_then(|i| i.format_id.as_deref())
                .and_then(bitrate_for_itag)
        });
        let estimated = duration.or_else(|| {
            entry
                .expected_size
                .or(Some(writer.meta().downloaded_bytes))
                .and_then(|size| estimate_duration(Some(size), bitrate_bps))
        });
        self.set_duration(estimated);

        self.set_stats(StreamStats {
            uri: url.to_string(),
            format_id: info
                .and_then(|i| i.format_id.clone())
                .or_else(|| entry.itag.clone()),
            protocol: Some("https".to_owned()),
            ext: entry.ext.clone(),
            acodec: Some(if is_opus { "opus" } else { "mp4a" }.to_owned()),
            bitrate_kbps: bitrate_bps.map(|b| b / 1000),
            sample_rate_hz: info.and_then(|i| i.sample_rate),
            channels: info.and_then(|i| i.channels),
            duration_seconds: estimated.map(|d| d.as_secs_f64()),
            content_length_bytes: expected_bytes,
            from_cache: false,
            is_local: false,
        });

        self.spawn_resume_task(url, &ua, writer, my_gen);

        if is_opus {
            let probe =
                tokio::task::spawn_blocking(move || OpusSource::from_source(Box::new(reader)));
            let source = match tokio::time::timeout(PROBE_TIMEOUT, probe).await {
                Ok(Ok(Ok(s))) => s,
                Ok(Ok(Err(e))) => return Err(anyhow::anyhow!("opus source (partial): {e}")),
                Ok(Err(e)) => return Err(anyhow::anyhow!("opus probe task failed: {e}")),
                Err(_) => return Err(anyhow::anyhow!("opus probe timed out")),
            };
            self.append_source(source, my_gen, estimated, true)
        } else {
            let decode = tokio::task::spawn_blocking(move || {
                Decoder::try_from(BufReader::new(reader))
                    .map_err(|e| anyhow::anyhow!("decode partial: {e:?}"))
            });
            let source = decode
                .await
                .map_err(|e| anyhow::anyhow!("decode task failed: {e}"))??;
            self.append_source(source, my_gen, estimated, true)
        }
    }

    fn append_source<S: Source + Send + 'static>(
        &self,
        source: S,
        my_gen: u64,
        duration: Option<Duration>,
        is_local: bool,
    ) -> Result<()> {
        if self.generation.load(Ordering::SeqCst) != my_gen {
            return Err(anyhow::anyhow!("superseded by a newer play request"));
        }

        let total_dur = duration.or_else(|| source.total_duration());
        self.set_duration(total_dur);

        {
            let mut stats = self.stats.lock().unwrap();
            stats.sample_rate_hz = Some(source.sample_rate().get());
            stats.channels = Some(source.channels().get());
            if total_dur.is_some() {
                stats.duration_seconds = total_dur.map(|d| d.as_secs_f64());
            }
            stats.is_local = is_local;
        }

        if !self.has_sink() {
            if let Err(e) = self.rebuild_sink() {
                tracing::warn!(%e, "append_source: rebuild failed");
            }
        }

        if self.generation.load(Ordering::SeqCst) != my_gen {
            return Err(anyhow::anyhow!("superseded by a newer play request"));
        }

        let played = self.with_player(|p| {
            p.append(source);
            p.play();
        });
        if played.is_none() {
            return Err(anyhow::anyhow!("no audio sink available"));
        }

        let mut pos = self.position.lock().unwrap();
        pos.reset();
        pos.start();
        *self.released_position.lock().unwrap() = None;
        Ok(())
    }

    fn install_seeked_source<S: Source + Send + 'static>(
        &self,
        source: S,
        my_gen: u64,
        landed: Duration,
        was_paused: bool,
    ) -> Result<()> {
        if self.generation.load(Ordering::SeqCst) != my_gen {
            return Err(anyhow::anyhow!("superseded by a newer play request"));
        }

        {
            let mut stats = self.stats.lock().unwrap();
            stats.sample_rate_hz = Some(source.sample_rate().get());
            stats.channels = Some(source.channels().get());
        }

        let installed = self.with_player(|p| {
            p.stop();
            p.append(source);
            if was_paused {
                p.pause();
            } else {
                p.play();
            }
        });
        if installed.is_none() {
            return Err(anyhow::anyhow!("no audio sink available"));
        }

        let mut pos = self.position.lock().unwrap();
        pos.reset();
        pos.seek(landed);
        if !was_paused {
            pos.start();
        }
        tracing::debug!(?landed, was_paused, "seek: installed source");
        Ok(())
    }

    async fn wait_for_prebuffer(&self, buffer: &StreamBuffer, my_gen: u64) -> Result<usize> {
        let started = Instant::now();
        loop {
            if self.generation.load(Ordering::Acquire) != my_gen {
                buffer.cancel();
                return Err(anyhow::anyhow!("superseded by a newer play request"));
            }
            let len = buffer.current_len();
            if len >= PRE_BUFFER_THRESHOLD || buffer.is_finished() {
                tracing::debug!(
                    bytes = len,
                    waited_ms = started.elapsed().as_millis() as u64,
                    gen = my_gen,
                    "pre-buffer ready"
                );
                return Ok(len);
            }
            if started.elapsed() >= PRE_BUFFER_TIMEOUT {
                if len == 0 {
                    return Err(anyhow::anyhow!(
                        "stream stalled: zero bytes received in {:?}",
                        started.elapsed()
                    ));
                }
                tracing::warn!(
                    bytes = len,
                    waited_ms = started.elapsed().as_millis() as u64,
                    gen = my_gen,
                    "pre-buffer deadline reached, starting playback with partial buffer"
                );
                return Ok(len);
            }
            tokio::time::sleep(PRE_BUFFER_POLL).await;
        }
    }

    async fn play_opus_streaming(
        &self,
        url: &str,
        user_agent: &str,
        response: reqwest::Response,
        writer: Option<AudioWriter>,
        my_gen: u64,
        known_duration: Option<Duration>,
    ) -> Result<()> {
        let buffer = StreamBuffer::new();
        *self.active_buffer.lock().unwrap() = Some(buffer.clone());

        spawn_download_task(
            self.store.clone(),
            self.client.clone(),
            url.to_owned(),
            user_agent.to_owned(),
            buffer.clone(),
            writer,
            response,
            my_gen,
            self.generation.clone(),
        );

        let buffered = self.wait_for_prebuffer(&buffer, my_gen).await?;

        let probe_started = Instant::now();
        let probe_buffer = buffer.clone();
        let probe = tokio::task::spawn_blocking(move || OpusSource::from_stream(probe_buffer));

        let source = match tokio::time::timeout(PROBE_TIMEOUT, probe).await {
            Ok(Ok(Ok(source))) => source,
            Ok(Ok(Err(e))) => return Err(anyhow::anyhow!("opus source: {e}")),
            Ok(Err(join_err)) => return Err(anyhow::anyhow!("opus probe task failed: {join_err}")),
            Err(_) => {
                return Err(anyhow::anyhow!(
                    "opus probe timed out after {PROBE_TIMEOUT:?}"
                ));
            }
        };
        let probe_ms = probe_started.elapsed();

        if probe_ms > PROBE_SLOW_WARN {
            tracing::warn!(
                probe_ms = probe_ms.as_millis() as u64,
                buffered,
                gen = my_gen,
                "opus probe was slow"
            );
        } else {
            tracing::debug!(
                buffered_bytes = buffered,
                probe_ms = probe_ms.as_millis() as u64,
                gen = my_gen,
                "opus probe done"
            );
        }

        self.append_source(source, my_gen, known_duration, false)
    }

    async fn play_streaming(
        &self,
        url: &str,
        user_agent: &str,
        response: reqwest::Response,
        writer: Option<AudioWriter>,
        my_gen: u64,
        known_duration: Option<Duration>,
    ) -> Result<()> {
        let buffer = StreamBuffer::new();
        *self.active_buffer.lock().unwrap() = Some(buffer.clone());

        spawn_download_task(
            self.store.clone(),
            self.client.clone(),
            url.to_owned(),
            user_agent.to_owned(),
            buffer.clone(),
            writer,
            response,
            my_gen,
            self.generation.clone(),
        );

        let buffered = self.wait_for_prebuffer(&buffer, my_gen).await?;

        let decode_buffer = buffer.clone();
        let source = tokio::task::spawn_blocking(move || {
            let reader = BufReader::new(StreamReader::new(decode_buffer));
            Decoder::try_from(reader)
                .map_err(|e| anyhow::anyhow!("Failed to decode audio stream: {e:?}"))
        })
        .await
        .map_err(|e| anyhow::anyhow!("decoder task failed: {e}"))??;

        if self.generation.load(Ordering::SeqCst) != my_gen {
            return Err(anyhow::anyhow!("superseded by a newer play request"));
        }

        tracing::debug!(buffered_bytes = buffered, gen = my_gen, "decoder ready");

        self.append_source(source, my_gen, known_duration, false)
    }

    pub fn play_file<P: AsRef<Path>>(&self, path: P) -> Result<()> {
        let result = self.play_file_inner(path.as_ref());
        if let Err(e) = &result {
            self.record_error(e.to_string());
        }
        result
    }

    fn play_file_inner(&self, path: &Path) -> Result<()> {
        let file =
            File::open(path).with_context(|| format!("Failed to open file: {}", path.display()))?;
        let reader = BufReader::new(file);
        let source = Decoder::try_from(reader)
            .map_err(|e| anyhow::anyhow!("Failed to decode local file: {e:?}"))?;
        let total_dur = source.total_duration();

        self.cancel_pending();
        self.clear_error();
        if let Some(old) = self.active_buffer.lock().unwrap().take() {
            old.cancel();
        }
        *self.current_url.lock().unwrap() = Some(format!("file://{}", path.display()));
        *self.current_user_agent.lock().unwrap() = None;
        *self.current_is_opus.lock().unwrap() = false;
        self.set_duration(total_dur);

        self.set_stats(StreamStats {
            uri: format!("file://{}", path.display()),
            sample_rate_hz: Some(source.sample_rate().get()),
            channels: Some(source.channels().get()),
            duration_seconds: total_dur.map(|d| d.as_secs_f64()),
            content_length_bytes: std::fs::metadata(path).ok().map(|m| m.len()),
            is_local: true,
            ..StreamStats::default()
        });

        if let Err(e) = self.rebuild_sink() {
            tracing::warn!(%e, "play_file: rebuild failed, using existing rig");
        }

        let played = self.with_player(|p| {
            p.append(source);
            p.play();
        });
        if played.is_none() {
            return Err(anyhow::anyhow!("no audio sink available"));
        }

        let mut pos = self.position.lock().unwrap();
        pos.reset();
        pos.start();
        *self.released_position.lock().unwrap() = None;
        Ok(())
    }

    pub async fn seek(&self, target: Duration) -> Result<()> {
        let result = self.seek_inner(target).await;
        if let Err(e) = &result {
            self.record_error(e.to_string());
        }
        result
    }

    async fn seek_inner(&self, target: Duration) -> Result<()> {
        tracing::debug!(?target, "seek: starting");

        let current_url = self
            .current_url
            .lock()
            .unwrap()
            .clone()
            .context("No audio track loaded to seek")?;

        let is_opus = *self.current_is_opus.lock().unwrap();
        let was_paused = self.with_player(|p| p.is_paused()).unwrap_or(true);

        let my_gen = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        if let Some(old) = self.active_buffer.lock().unwrap().take() {
            old.cancel();
        }
        self.with_player(|p| p.stop());

        if let Some(path_str) = current_url.strip_prefix("file://") {
            return self.seek_local(Path::new(path_str), is_opus, target, my_gen, was_paused);
        }

        let ua = self
            .current_user_agent
            .lock()
            .unwrap()
            .clone()
            .unwrap_or_else(|| DEFAULT_UA.to_owned());

        let (resolver_bitrate, total, dur) = {
            let stats = self.stats.lock().unwrap();
            (
                stats.bitrate_kbps.map(|k| k * 1000),
                stats.content_length_bytes,
                stats.duration_seconds,
            )
        };
        let bitrate = match (total, dur) {
            (Some(t), Some(d)) if t > 0 && d > 1.0 => Some(((t as f64 * 8.0) / d) as u64),
            _ => resolver_bitrate,
        };

        if let (Some(bps), Some(total)) = (bitrate.filter(|b| *b > 0), total) {
            let target_bytes = (target.as_secs_f64() * bps as f64 / 8.0) as u64;
            let outcome = if is_opus {
                self.seek_window_opus(
                    &current_url,
                    &ua,
                    target,
                    target_bytes,
                    total,
                    my_gen,
                    was_paused,
                )
                .await
            } else {
                self.seek_window_m4a(
                    &current_url,
                    &ua,
                    target,
                    target_bytes,
                    total,
                    my_gen,
                    was_paused,
                )
                .await
            };
            match outcome {
                Ok(true) => return Ok(()),
                Ok(false) => tracing::debug!("seek: window path declined, using slow fallback"),
                Err(e) => tracing::debug!(%e, "seek: window path failed, using slow fallback"),
            }
        } else {
            tracing::debug!("seek: no bitrate/size known, using slow fallback");
        }

        self.seek_remote_from_zero(&current_url, &ua, target, is_opus, my_gen, was_paused)
            .await
    }

    fn seek_local(
        &self,
        path: &Path,
        is_opus: bool,
        target: Duration,
        my_gen: u64,
        was_paused: bool,
    ) -> Result<()> {
        if is_opus {
            let mut source = OpusSource::from_file(path)
                .map_err(|e| anyhow::anyhow!("opus source (seek): {e}"))?;
            let landed = demuxer_seek_or_skip(&mut source, target, "local");
            return self.install_seeked_source(source, my_gen, landed, was_paused);
        }

        let file = File::open(path)
            .with_context(|| format!("Failed to reopen file: {}", path.display()))?;
        let mut source = Decoder::try_from(BufReader::new(file))
            .map_err(|e| anyhow::anyhow!("Failed to decode local file: {e:?}"))?;
        skip_samples(&mut source, target);
        self.install_seeked_source(source, my_gen, target, was_paused)
    }

    async fn seek_window_opus(
        &self,
        url: &str,
        ua: &str,
        target: Duration,
        target_bytes: u64,
        total_bytes: u64,
        my_gen: u64,
        was_paused: bool,
    ) -> Result<bool> {
        if target_bytes < OPUS_WINDOW_PRE {
            return Ok(false);
        }

        let fetch_started = Instant::now();

        let raw_header = fetch_range(&self.client, url, ua, 0, OPUS_HEADER_WINDOW).await?;
        let header_end = first_cluster_offset(&raw_header).unwrap_or(raw_header.len());
        let header = &raw_header[..header_end];

        let mut window_start = target_bytes.saturating_sub(OPUS_WINDOW_PRE);
        let mut window_end = target_bytes
            .saturating_add(OPUS_WINDOW_POST)
            .min(total_bytes);
        if window_start >= window_end {
            window_end = total_bytes;
            window_start = window_end.saturating_sub(OPUS_WINDOW_PRE + OPUS_WINDOW_POST);
        }
        if window_start >= window_end {
            return Ok(false);
        }
        let raw_window = fetch_range(&self.client, url, ua, window_start, window_end).await?;
        let skip = first_cluster_offset(&raw_window).unwrap_or(0);
        let window = &raw_window[skip..];
        if window.is_empty() {
            return Ok(false);
        }

        if self.generation.load(Ordering::SeqCst) != my_gen {
            return Err(anyhow::anyhow!("superseded by a newer play request"));
        }

        tracing::debug!(
            header_bytes = header.len(),
            window_bytes = window.len(),
            window_start,
            window_end,
            fetch_ms = fetch_started.elapsed().as_millis() as u64,
            ?target,
            gen = my_gen,
            "seek: opus window fetched"
        );

        let mut combined = Vec::with_capacity(header.len() + window.len());
        combined.extend_from_slice(header);
        combined.extend_from_slice(window);

        let buffer = StreamBuffer::new();
        buffer.append(&combined);
        *self.active_buffer.lock().unwrap() = Some(buffer.clone());

        spawn_window_tail(
            self.client.clone(),
            url.to_owned(),
            ua.to_owned(),
            buffer.clone(),
            window_end,
            total_bytes,
            my_gen,
            self.generation.clone(),
        );

        let probe_started = Instant::now();
        let probe_buffer = buffer.clone();
        let probe = tokio::task::spawn_blocking(move || OpusSource::from_stream(probe_buffer));
        let mut source = match tokio::time::timeout(PROBE_TIMEOUT, probe).await {
            Ok(Ok(Ok(s))) => s,
            Ok(Ok(Err(e))) => return Err(anyhow::anyhow!("opus source (window): {e}")),
            Ok(Err(e)) => return Err(anyhow::anyhow!("opus probe task failed: {e}")),
            Err(_) => return Err(anyhow::anyhow!("opus probe timed out")),
        };

        let landed_raw = source.landed_time();
        let mut landed = landed_raw.unwrap_or(target);

        if landed < target {
            let to_skip = target - landed;
            skip_samples(&mut source, to_skip);
            landed = target;
        }

        tracing::debug!(
            probe_ms = probe_started.elapsed().as_millis() as u64,
            ?landed_raw,
            ?landed,
            ?target,
            gen = my_gen,
            "seek: opus window probed"
        );

        self.install_seeked_source(source, my_gen, landed, was_paused)?;
        Ok(true)
    }

    async fn seek_window_m4a(
        &self,
        url: &str,
        ua: &str,
        target: Duration,
        target_bytes: u64,
        total_bytes: u64,
        my_gen: u64,
        was_paused: bool,
    ) -> Result<bool> {
        if target_bytes < M4A_WINDOW_PRE {
            return Ok(false);
        }

        let fetch_started = Instant::now();

        let probe_end = 512 * 1024u64.min(total_bytes);
        let probe = fetch_range(&self.client, url, ua, 0, probe_end).await?;
        let header_end = mp4_header_end(&probe).unwrap_or(0);
        if header_end == 0 {
            return Ok(false);
        }
        let header = if header_end <= probe.len() as u64 {
            probe[..header_end as usize].to_vec()
        } else if header_end <= M4A_HEADER_MAX {
            fetch_range(&self.client, url, ua, 0, header_end).await?
        } else {
            return Ok(false);
        };

        let mut window_start = target_bytes.saturating_sub(M4A_WINDOW_PRE);
        let mut window_end = target_bytes
            .saturating_add(M4A_WINDOW_POST)
            .min(total_bytes);
        if window_start >= window_end {
            window_end = total_bytes;
            window_start = window_end.saturating_sub(M4A_WINDOW_PRE + M4A_WINDOW_POST);
        }
        if window_start >= window_end {
            return Ok(false);
        }
        let window = fetch_range(&self.client, url, ua, window_start, window_end).await?;
        if window.is_empty() {
            return Ok(false);
        }

        if self.generation.load(Ordering::SeqCst) != my_gen {
            return Err(anyhow::anyhow!("superseded by a newer play request"));
        }

        tracing::debug!(
            header_bytes = header.len(),
            window_bytes = window.len(),
            window_start,
            window_end,
            fetch_ms = fetch_started.elapsed().as_millis() as u64,
            ?target,
            gen = my_gen,
            "seek: m4a window fetched"
        );

        let tail = StreamBuffer::new();
        let tail_start = window_start + window.len() as u64;
        *self.active_buffer.lock().unwrap() = Some(tail.clone());
        spawn_window_tail(
            self.client.clone(),
            url.to_owned(),
            ua.to_owned(),
            tail.clone(),
            tail_start,
            total_bytes,
            my_gen,
            self.generation.clone(),
        );

        let source = Mp4SparseSource::new(header, window, window_start, tail, Some(total_bytes));
        let decode = tokio::task::spawn_blocking(move || {
            let reader = BufReader::new(source);
            Decoder::try_from(reader).map_err(|e| format!("decode m4a window: {e:?}"))
        });
        let mut decoder = match tokio::time::timeout(PROBE_TIMEOUT, decode).await {
            Ok(Ok(Ok(d))) => d,
            Ok(Ok(Err(e))) => return Err(anyhow::anyhow!("{e}")),
            Ok(Err(e)) => return Err(anyhow::anyhow!("decode task failed: {e}")),
            Err(_) => return Err(anyhow::anyhow!("m4a window decode timed out")),
        };

        if let Err(e) = decoder.try_seek(target) {
            return Err(anyhow::anyhow!("m4a window seek: {e:?}"));
        }

        self.install_seeked_source(decoder, my_gen, target, was_paused)?;
        Ok(true)
    }

    async fn seek_remote_from_zero(
        &self,
        url: &str,
        ua: &str,
        target: Duration,
        is_opus: bool,
        my_gen: u64,
        was_paused: bool,
    ) -> Result<()> {
        let response = self
            .client
            .get(url)
            .header("User-Agent", ua)
            .send()
            .await
            .context("Failed to reopen stream for seek")?;

        if self.generation.load(Ordering::SeqCst) != my_gen {
            return Err(anyhow::anyhow!("superseded by a newer play request"));
        }
        let status = response.status();
        if !status.is_success() {
            return Err(anyhow::anyhow!("HTTP {status} while seeking"));
        }
        let content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("?")
            .to_owned();
        if content_type.starts_with("text/html") {
            return Err(anyhow::anyhow!(
                "the CDN returned {content_type} instead of audio (URL likely bound to another client)"
            ));
        }

        tracing::debug!(
            ?target,
            is_opus,
            was_paused,
            "seek: reopening stream from 0, will skip by decoding"
        );

        let buffer = StreamBuffer::new();
        *self.active_buffer.lock().unwrap() = Some(buffer.clone());

        spawn_download_task(
            self.store.clone(),
            self.client.clone(),
            url.to_owned(),
            ua.to_owned(),
            buffer.clone(),
            None,
            response,
            my_gen,
            self.generation.clone(),
        );

        let _ = self.wait_for_prebuffer(&buffer, my_gen).await?;
        let skip_started = Instant::now();

        if is_opus {
            let probe_buffer = buffer.clone();
            let skip = target;
            let probe = tokio::task::spawn_blocking(move || -> Result<OpusSource, String> {
                let mut source = OpusSource::from_stream(probe_buffer)?;
                skip_samples(&mut source, skip);
                Ok(source)
            });
            let source = match tokio::time::timeout(Duration::from_secs(120), probe).await {
                Ok(Ok(Ok(s))) => s,
                Ok(Ok(Err(e))) => return Err(anyhow::anyhow!("opus source (seek): {e}")),
                Ok(Err(e)) => return Err(anyhow::anyhow!("opus probe task failed: {e}")),
                Err(_) => return Err(anyhow::anyhow!("seek timed out (target {target:?})")),
            };
            tracing::debug!(
                elapsed_ms = skip_started.elapsed().as_millis() as u64,
                ?target,
                "seek: opus skip done (remote)"
            );
            return self.install_seeked_source(source, my_gen, target, was_paused);
        }

        let decode_buffer = buffer.clone();
        let skip = target;
        let decode = tokio::task::spawn_blocking(
            move || -> Result<Decoder<BufReader<StreamReader>>, String> {
                let reader = BufReader::new(StreamReader::new(decode_buffer));
                let mut source = Decoder::try_from(reader).map_err(|e| format!("decode: {e:?}"))?;
                skip_samples(&mut source, skip);
                Ok(source)
            },
        );
        let source = match tokio::time::timeout(Duration::from_secs(120), decode).await {
            Ok(Ok(Ok(s))) => s,
            Ok(Ok(Err(e))) => return Err(anyhow::anyhow!("{e}")),
            Ok(Err(e)) => return Err(anyhow::anyhow!("decode task failed: {e}")),
            Err(_) => return Err(anyhow::anyhow!("seek timed out (target {target:?})")),
        };
        tracing::debug!(
            elapsed_ms = skip_started.elapsed().as_millis() as u64,
            ?target,
            "seek: skip done (remote m4a)"
        );
        self.install_seeked_source(source, my_gen, target, was_paused)
    }

    fn spawn_resume_task(&self, url: &str, user_agent: &str, mut writer: AudioWriter, my_gen: u64) {
        let client = self.client.clone();
        let generation = self.generation.clone();
        let url = url.to_owned();
        let user_agent = user_agent.to_owned();

        tokio::spawn(async move {
            let mut attempt = 0usize;
            loop {
                if generation.load(Ordering::SeqCst) != my_gen {
                    writer.cancel_growth();
                    let _ = writer.finish(false).await;
                    return;
                }

                match resume_once(&client, &url, &user_agent, &mut writer, &generation, my_gen)
                    .await
                {
                    Ok(true) => {
                        let _ = writer.finish(true).await;
                        return;
                    }
                    Ok(false) => {
                        let _ = writer.finish(false).await;
                        return;
                    }
                    Err(ResumeError::Cancelled) => {
                        writer.cancel_growth();
                        let _ = writer.finish(false).await;
                        return;
                    }
                    Err(ResumeError::Permanent(e)) => {
                        tracing::warn!(error = %e, gen = my_gen, "resume: giving up");
                        writer.cancel_growth();
                        let _ = writer.finish(false).await;
                        return;
                    }
                    Err(ResumeError::Transient(e)) => {
                        let delay = RESUME_BACKOFF_MS[attempt.min(RESUME_BACKOFF_MS.len() - 1)];
                        attempt += 1;
                        tracing::debug!(
                            error = %e,
                            attempt,
                            delay_ms = delay,
                            bytes = writer.downloaded_bytes(),
                            gen = my_gen,
                            "resume: retrying"
                        );
                        tokio::time::sleep(Duration::from_millis(delay)).await;
                    }
                }
            }
        });
    }

    pub fn pause(&self) {
        self.with_player(|p| p.pause());
        self.position.lock().unwrap().pause();
    }

    pub async fn resume_async(&self) {
        let empty = self.with_player(|p| p.empty()).unwrap_or(true);
        if !empty {
            self.with_player(|p| p.play());
            self.position.lock().unwrap().start();
            return;
        }

        if !self.has_sink() {
            if let Err(e) = self.rebuild_sink() {
                tracing::warn!(%e, "resume: rebuild failed");
                return;
            }
        }

        let Some(pos) = *self.released_position.lock().unwrap() else {
            return;
        };

        tracing::debug!(?pos, "resume: reopening at saved position");
        if let Err(e) = self.seek_inner(pos).await {
            tracing::warn!(%e, "resume: reopen failed");
        }
        *self.released_position.lock().unwrap() = None;
        self.with_player(|p| p.play());
        self.position.lock().unwrap().start();
    }

    pub fn stop(&self) {
        self.cancel_pending();
        if let Some(old) = self.active_buffer.lock().unwrap().take() {
            old.cancel();
        }
        self.with_player(|p| p.stop());
        self.position.lock().unwrap().reset();
        self.clear_error();
    }

    pub fn reset(&self) {
        self.cancel_pending();
        if let Some(old) = self.active_buffer.lock().unwrap().take() {
            old.cancel();
        }
        self.with_player(|p| p.stop());
        self.position.lock().unwrap().reset();

        *self.current_url.lock().unwrap() = None;
        *self.current_user_agent.lock().unwrap() = None;
        *self.current_is_opus.lock().unwrap() = false;
        *self.total_duration.lock().unwrap() = None;
        *self.released_position.lock().unwrap() = None;
        *self.stats.lock().unwrap() = StreamStats::default();
        self.clear_error();
    }

    pub fn get_position(&self) -> Duration {
        self.sync_position();
        let elapsed = self.position.lock().unwrap().elapsed();
        if let Some(total) = *self.total_duration.lock().unwrap() {
            if elapsed > total {
                return total;
            }
        }
        elapsed
    }

    pub fn get_duration(&self) -> Option<Duration> {
        *self.total_duration.lock().unwrap()
    }

    pub fn volume(&self) -> f32 {
        self.with_player(|p| p.volume()).unwrap_or(1.0)
    }

    pub fn set_volume(&self, v: f32) {
        self.with_player(|p| p.set_volume(v));
    }

    pub fn is_paused(&self) -> bool {
        if !self.has_sink() {
            return self.released_position.lock().unwrap().is_some();
        }
        self.with_player(|p| p.is_paused()).unwrap_or(false)
    }

    pub fn is_empty(&self) -> bool {
        if !self.has_sink() {
            return true;
        }
        self.with_player(|p| p.empty()).unwrap_or(true)
    }

    pub fn state(&self) -> PlayerState {
        if self.last_error.lock().unwrap().is_some() {
            return PlayerState::Error;
        }

        match self.with_player(|p| (p.empty(), p.is_paused())) {
            Some((false, true)) => return PlayerState::Paused,
            Some((false, false)) => return PlayerState::Playing,
            _ => {}
        }

        if self.released_position.lock().unwrap().is_some() {
            return PlayerState::Paused;
        }

        let has_track = self.current_url.lock().unwrap().is_some();
        if !has_track {
            return PlayerState::Stopped;
        }

        let advanced = self.position.lock().unwrap().elapsed() > Duration::ZERO;
        if !advanced {
            PlayerState::Loading
        } else {
            PlayerState::Paused
        }
    }

    pub fn is_finished(&self) -> bool {
        let (empty, pos) = match self.with_player(|p| (p.empty(), ())) {
            Some((empty, _)) => (empty, self.position.lock().unwrap().elapsed()),
            None => return false,
        };
        if !empty {
            return false;
        }
        if pos == Duration::ZERO {
            return false;
        }
        let finished = match *self.total_duration.lock().unwrap() {
            Some(total) => pos + Duration::from_secs(2) >= total,
            None => false,
        };
        if finished {
            let _ = self.active_buffer.lock().unwrap().take();
        }
        finished
    }
}

fn demuxer_seek_or_skip(source: &mut OpusSource, target: Duration, context: &str) -> Duration {
    match source.try_seek_to(target) {
        Ok(pos) => {
            tracing::debug!(
                context,
                target_ms = target.as_millis() as u64,
                landed_ms = pos.as_millis() as u64,
                "seek: demuxer seek ok"
            );
            pos
        }
        Err(err) => {
            tracing::debug!(
                context,
                %err,
                target_ms = target.as_millis() as u64,
                "seek: demuxer seek failed, using sample skip"
            );
            skip_samples(source, target);
            target
        }
    }
}

async fn fetch_range(
    client: &reqwest::Client,
    url: &str,
    user_agent: &str,
    start: u64,
    end: u64,
) -> Result<Vec<u8>> {
    if end <= start {
        return Ok(Vec::new());
    }
    let response = client
        .get(url)
        .header("User-Agent", user_agent)
        .header("Range", format!("bytes={}-{}", start, end - 1))
        .send()
        .await
        .with_context(|| format!("range fetch {start}-{end}"))?;

    let status = response.status();
    if status != reqwest::StatusCode::PARTIAL_CONTENT {
        anyhow::bail!("range {start}-{end}: HTTP {status} (expected 206)");
    }
    let bytes = response.bytes().await?;
    Ok(bytes.to_vec())
}

fn spawn_window_tail(
    client: reqwest::Client,
    url: String,
    user_agent: String,
    buffer: StreamBuffer,
    start_offset: u64,
    total: u64,
    my_gen: u64,
    generation: Arc<AtomicU64>,
) {
    tokio::spawn(async move {
        let mut offset = start_offset;
        let mut attempt = 0usize;
        while offset < total {
            if generation.load(Ordering::SeqCst) != my_gen || buffer.is_cancelled() {
                return;
            }
            let end = (offset + TAIL_CHUNK).min(total);
            let requested = end - offset;
            let response = client
                .get(&url)
                .header("User-Agent", &user_agent)
                .header("Range", format!("bytes={}-{}", offset, end - 1))
                .send()
                .await;

            match response {
                Ok(r) if r.status() == reqwest::StatusCode::PARTIAL_CONTENT => {
                    match r.bytes().await {
                        Ok(bytes) if !bytes.is_empty() => {
                            let received = bytes.len() as u64;
                            buffer.append(&bytes);
                            offset += received;
                            attempt = 0;
                            if received < requested {
                                continue;
                            }
                        }
                        _ => break,
                    }
                }
                Ok(r) if r.status() == reqwest::StatusCode::RANGE_NOT_SATISFIABLE => break,
                Ok(r) if r.status().is_server_error() || is_transient_http(r.status()) => {
                    attempt += 1;
                    if attempt > 10 {
                        break;
                    }
                    let delay = RESUME_BACKOFF_MS[attempt.min(RESUME_BACKOFF_MS.len() - 1)];
                    tokio::time::sleep(Duration::from_millis(delay)).await;
                    continue;
                }
                Ok(r) => {
                    tracing::warn!(status = %r.status(), "window tail: giving up");
                    break;
                }
                Err(e) => {
                    attempt += 1;
                    if attempt > 10 {
                        break;
                    }
                    let delay = RESUME_BACKOFF_MS[attempt.min(RESUME_BACKOFF_MS.len() - 1)];
                    tracing::debug!(%e, attempt, delay_ms = delay, "window tail: retrying");
                    tokio::time::sleep(Duration::from_millis(delay)).await;
                }
            }
        }
        buffer.finish();
    });
}

async fn resume_once(
    client: &reqwest::Client,
    url: &str,
    ua: &str,
    writer: &mut AudioWriter,
    generation: &Arc<AtomicU64>,
    my_gen: u64,
) -> Result<bool, ResumeError> {
    let saved_offset = writer.downloaded_bytes();

    let response = client
        .get(url)
        .header("User-Agent", ua)
        .header("Range", format!("bytes={saved_offset}-"))
        .send()
        .await
        .map_err(|e| ResumeError::Transient(e.to_string()))?;

    let status = response.status();
    if status == reqwest::StatusCode::RANGE_NOT_SATISFIABLE {
        return Ok(writer
            .meta()
            .expected_size
            .is_some_and(|s| saved_offset >= s));
    }
    if status.is_server_error() || is_transient_http(status) {
        return Err(ResumeError::Transient(format!("HTTP {status}")));
    }
    if !status.is_success() {
        return Err(ResumeError::Permanent(format!("HTTP {status}")));
    }

    let wire_start = if status == reqwest::StatusCode::PARTIAL_CONTENT {
        saved_offset
    } else {
        0
    };
    if let Some(len) = response.content_length() {
        writer.set_expected_size(Some(len + wire_start));
    }

    let mut stream = response.bytes_stream();
    let mut pos = wire_start;
    while let Some(chunk) = stream.next().await {
        if generation.load(Ordering::SeqCst) != my_gen {
            return Err(ResumeError::Cancelled);
        }
        match chunk {
            Ok(bytes) => {
                let end = pos + bytes.len() as u64;
                if end > saved_offset {
                    let skip = saved_offset.saturating_sub(pos) as usize;
                    writer
                        .write(&bytes[skip..])
                        .await
                        .map_err(|e| ResumeError::Permanent(format!("write: {e}")))?;
                }
                pos = end;
            }
            Err(e) => return Err(ResumeError::Transient(e.to_string())),
        }
    }

    Ok(writer
        .meta()
        .expected_size
        .is_some_and(|expected| writer.downloaded_bytes() >= expected))
}

fn spawn_download_task(
    store: Arc<AudioStore>,
    client: reqwest::Client,
    url: String,
    user_agent: String,
    buffer: StreamBuffer,
    writer: Option<AudioWriter>,
    initial_response: reqwest::Response,
    my_gen: u64,
    generation: Arc<AtomicU64>,
) {
    tokio::spawn(async move {
        let mut writer = writer;
        let mut attempt = 0usize;
        let mut next_response = Some(initial_response);

        loop {
            if generation.load(Ordering::SeqCst) != my_gen {
                buffer.cancel();
                if let Some(w) = writer.as_ref() {
                    w.cancel_growth();
                }
                if let Some(mut w) = writer.take() {
                    let _ = w.finish(false).await;
                }
                return;
            }

            let response = if let Some(r) = next_response.take() {
                r
            } else {
                let already = buffer.current_len() as u64;
                let req = client
                    .get(&url)
                    .header("User-Agent", &user_agent)
                    .header("Range", format!("bytes={already}-"));
                match req.send().await {
                    Ok(r) => {
                        let status = r.status();
                        if status == reqwest::StatusCode::RANGE_NOT_SATISFIABLE {
                            buffer.finish();
                            if let Some(mut w) = writer.take() {
                                let _ = w.finish(true).await;
                            }
                            store.evict_cache_to_limit().await;
                            return;
                        }
                        if status.is_server_error() || is_transient_http(status) {
                            attempt += 1;
                            let delay = RESUME_BACKOFF_MS[attempt.min(RESUME_BACKOFF_MS.len() - 1)];
                            tokio::time::sleep(Duration::from_millis(delay)).await;
                            continue;
                        }
                        if !status.is_success() {
                            buffer.set_error(format!("HTTP {status}"));
                            if let Some(mut w) = writer.take() {
                                let _ = w.finish(false).await;
                            }
                            return;
                        }
                        r
                    }
                    Err(e) => {
                        attempt += 1;
                        let delay = RESUME_BACKOFF_MS[attempt.min(RESUME_BACKOFF_MS.len() - 1)];
                        tracing::debug!(%e, attempt, delay_ms = delay, "download: fetch failed");
                        tokio::time::sleep(Duration::from_millis(delay)).await;
                        continue;
                    }
                }
            };

            let status = response.status();
            let expected_len = response.content_length();
            let wire_start = buffer.current_len() as u64;
            if let Some(w) = writer.as_mut() {
                if let Some(len) = expected_len {
                    let total = if status == reqwest::StatusCode::PARTIAL_CONTENT {
                        wire_start + len
                    } else {
                        len
                    };
                    w.set_expected_size(Some(total));
                }
            }

            let mut stream = response.bytes_stream();
            let mut pos = wire_start;
            let mut iter_bytes: u64 = 0;
            let mut err: Option<String> = None;
            while let Some(chunk) = stream.next().await {
                if generation.load(Ordering::SeqCst) != my_gen || buffer.is_cancelled() {
                    buffer.cancel();
                    if let Some(w) = writer.as_ref() {
                        w.cancel_growth();
                    }
                    if let Some(mut w) = writer.take() {
                        let _ = w.finish(false).await;
                    }
                    return;
                }
                match chunk {
                    Ok(bytes) => {
                        let already = buffer.current_len() as u64;
                        let skip = if pos < already {
                            (already - pos).min(bytes.len() as u64) as usize
                        } else {
                            0
                        };
                        buffer.append(&bytes[skip..]);
                        iter_bytes += bytes.len() as u64;
                        if let Some(w) = writer.as_mut() {
                            let end = pos + bytes.len() as u64;
                            let wpos = w.downloaded_bytes();
                            if end > wpos {
                                let wskip = wpos.saturating_sub(pos) as usize;
                                if let Err(e) = w.write(&bytes[wskip..]).await {
                                    tracing::warn!(%e, "download: write failed, dropping writer");
                                    writer = None;
                                }
                            }
                        }
                        pos += bytes.len() as u64;
                    }
                    Err(e) => {
                        err = Some(e.to_string());
                        break;
                    }
                }
            }

            if err.is_none() {
                if let Some(expected) = expected_len {
                    if iter_bytes < expected {
                        err = Some(format!(
                            "stream truncated: {} of {} bytes",
                            iter_bytes, expected
                        ));
                    }
                }
            }

            if let Some(e) = err {
                attempt += 1;
                let delay = RESUME_BACKOFF_MS[attempt.min(RESUME_BACKOFF_MS.len() - 1)];
                tracing::debug!(
                    error = %e,
                    attempt,
                    delay_ms = delay,
                    bytes = pos,
                    "download: mid-stream error, retrying"
                );
                tokio::time::sleep(Duration::from_millis(delay)).await;
                continue;
            }

            let expected = writer.as_ref().and_then(|w| w.meta().expected_size);
            let downloaded = writer.as_ref().map(|w| w.downloaded_bytes()).unwrap_or(0);
            let is_complete = expected.is_some_and(|e| downloaded >= e)
                || expected_len.map(|e| iter_bytes >= e).unwrap_or(false);
            buffer.finish();
            if let Some(mut w) = writer.take() {
                let _ = w.finish(is_complete).await;
            }
            store.evict_cache_to_limit().await;
            return;
        }
    });
}

pub fn is_live_uri(uri: &str) -> bool {
    uri.contains(".m3u8") || uri.contains("/hls_playlist/")
}

fn estimate_duration(content_length: Option<u64>, bitrate_bps: Option<u64>) -> Option<Duration> {
    let bytes = content_length?;
    let bps = bitrate_bps?;
    if bps == 0 || bytes == 0 {
        return None;
    }
    let seconds = (bytes as f64 * 8.0) / bps as f64;
    (seconds > 5.0).then(|| Duration::from_secs_f64(seconds))
}

fn skip_samples<S: Source>(source: &mut S, target: Duration) {
    let channels = source.channels().get() as u64;
    let sample_rate = source.sample_rate().get() as u64;
    let to_skip = (target.as_secs_f64() * (sample_rate * channels) as f64) as u64;
    for _ in 0..to_skip {
        if source.next().is_none() {
            break;
        }
    }
}

impl PlaybackPosition {
    fn new() -> Self {
        Self {
            start_instant: None,
            accumulated: Duration::ZERO,
        }
    }

    fn reset(&mut self) {
        self.start_instant = None;
        self.accumulated = Duration::ZERO;
    }

    fn start(&mut self) {
        self.start_instant = Some(Instant::now());
    }

    fn pause(&mut self) {
        if let Some(start) = self.start_instant.take() {
            self.accumulated += start.elapsed();
        }
    }

    fn pause_if_running(&mut self) {
        if self.start_instant.is_some() {
            self.pause();
        }
    }

    fn resume_if_stopped(&mut self) {
        if self.start_instant.is_none() {
            self.start();
        }
    }

    fn elapsed(&self) -> Duration {
        match self.start_instant {
            Some(start) => self.accumulated + start.elapsed(),
            None => self.accumulated,
        }
    }

    fn seek(&mut self, target: Duration) {
        self.accumulated = target;
        if self.start_instant.is_some() {
            self.start_instant = Some(Instant::now());
        }
    }
}
