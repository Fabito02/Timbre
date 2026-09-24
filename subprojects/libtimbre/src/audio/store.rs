use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use symphonia::core::io::MediaSource;
use tokio::fs;
use tokio::io::AsyncWriteExt;

use crate::context::Paths;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StoreKind {
    Cache,
    Download,
}

impl StoreKind {
    pub fn from_int(value: i32) -> Self {
        if value == 1 { StoreKind::Download } else { StoreKind::Cache }
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct AudioEntry {
    pub video_id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub artist: Option<String>,
    #[serde(default)]
    pub thumb: Option<String>,
    #[serde(default)]
    pub ext: Option<String>,
    #[serde(default)]
    pub mime: Option<String>,
    // A partial from itag 251 cannot be resumed into a stream that now
    // serves 140; the bytes would not line up, so the itag is saved.
    #[serde(default)]
    pub itag: Option<String>,
    #[serde(default)]
    pub expected_size: Option<u64>,
    #[serde(default)]
    pub downloaded_bytes: u64,
    #[serde(default)]
    pub complete: bool,
    #[serde(default)]
    pub user_agent: Option<String>,
    #[serde(default)]
    pub uri: Option<String>,
    #[serde(default)]
    pub updated_at: i64,
}

impl AudioEntry {
    pub fn is_playable(&self) -> bool {
        self.complete && self.downloaded_bytes > 0
    }

    pub fn is_resumable(&self) -> bool {
        !self.complete && self.downloaded_bytes > 0
    }
}

struct GrowthState {
    downloaded_bytes: u64,
    expected_size: Option<u64>,
    complete: bool,
    cancelled: bool,
}

#[derive(Clone)]
pub struct Growth(Arc<(Mutex<GrowthState>, Condvar)>);

impl Growth {
    fn new() -> Self {
        Self(Arc::new((
            Mutex::new(GrowthState {
                downloaded_bytes: 0,
                expected_size: None,
                complete: false,
                cancelled: false,
            }),
            Condvar::new(),
        )))
    }

    fn grow(&self, downloaded: u64, expected: Option<u64>) {
        let (lock, cv) = &*self.0;
        let mut state = lock.lock().unwrap();
        state.downloaded_bytes = downloaded;
        if expected.is_some() {
            state.expected_size = expected;
        }
        cv.notify_all();
    }

    fn finish(&self) {
        let (lock, cv) = &*self.0;
        let mut state = lock.lock().unwrap();
        state.complete = true;
        cv.notify_all();
    }

    fn cancel(&self) {
        let (lock, cv) = &*self.0;
        let mut state = lock.lock().unwrap();
        state.cancelled = true;
        state.complete = true;
        cv.notify_all();
    }
}

pub struct GrowingFileSource {
    file: std::fs::File,
    growth: Growth,
    cursor: u64,
}

impl GrowingFileSource {
    fn new(file: std::fs::File, growth: Growth) -> Self {
        Self { file, growth, cursor: 0 }
    }
}

impl Read for GrowingFileSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        loop {
            let n = self.file.read(buf)?;
            if n > 0 {
                self.cursor += n as u64;
                return Ok(n);
            }

            let (lock, cv) = &*self.growth.0;
            let mut state = lock.lock().unwrap();
            while state.downloaded_bytes <= self.cursor && !state.complete && !state.cancelled {
                state = cv.wait(state).unwrap();
            }
            if state.cancelled {
                return Ok(0);
            }
            if state.complete && state.downloaded_bytes <= self.cursor {
                return Ok(0);
            }
        }
    }
}

impl Seek for GrowingFileSource {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        let target = match pos {
            SeekFrom::Start(n) => n,
            SeekFrom::Current(delta) => {
                let target = (self.cursor as i64)
                    .checked_add(delta)
                    .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidInput, "seek overflow"))?;
                if target < 0 {
                    return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "seek before start"));
                }
                target as u64
            }
            SeekFrom::End(_) => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::Other,
                    "seek from end not available on a growing file",
                ))
            }
        };

        let (lock, cv) = &*self.growth.0;
        let mut state = lock.lock().unwrap();
        while state.downloaded_bytes < target && !state.complete && !state.cancelled {
            state = cv.wait(state).unwrap();
        }
        if state.cancelled {
            return Err(std::io::Error::new(std::io::ErrorKind::Interrupted, "cancelled"));
        }
        drop(state);

        self.file.seek(SeekFrom::Start(target))?;
        self.cursor = target;
        Ok(target)
    }
}

impl MediaSource for GrowingFileSource {
    fn is_seekable(&self) -> bool {
        // A seekable signal makes the MKV reader search for the Cues index
        // at the end of the file, and the end has not been written yet.
        false
    }
    fn byte_len(&self) -> Option<u64> {
        None
    }
}

pub struct AudioStore {
    cache_dir: PathBuf,
    download_dir: PathBuf,
    cache_limit_bytes: AtomicU64,
}

impl AudioStore {
    pub const DEFAULT_CACHE_LIMIT: u64 = 1_000_000_000;

    pub fn new(paths: &Paths) -> Self {
        let cache_dir = paths.cache_dir.join("audio_cache");
        let download_dir = paths.data_dir.join("downloads");
        std::fs::create_dir_all(&cache_dir).ok();
        std::fs::create_dir_all(&download_dir).ok();
        Self {
            cache_dir,
            download_dir,
            cache_limit_bytes: AtomicU64::new(Self::DEFAULT_CACHE_LIMIT),
        }
    }

    pub fn cache_limit(&self) -> u64 {
        self.cache_limit_bytes.load(Ordering::Relaxed)
    }

    pub fn set_cache_limit(&self, bytes: u64) {
        self.cache_limit_bytes.store(bytes, Ordering::Relaxed);
    }

    pub fn root(&self, kind: StoreKind) -> &Path {
        match kind {
            StoreKind::Cache => &self.cache_dir,
            StoreKind::Download => &self.download_dir,
        }
    }

    pub fn bin_path(&self, kind: StoreKind, video_id: &str) -> PathBuf {
        self.root(kind).join(format!("{video_id}.bin"))
    }

    fn meta_path(&self, kind: StoreKind, video_id: &str) -> PathBuf {
        self.root(kind).join(format!("{video_id}.json"))
    }

    pub async fn lookup(&self, video_id: &str) -> Option<(StoreKind, AudioEntry)> {
        for kind in [StoreKind::Download, StoreKind::Cache] {
            if let Some(entry) = self.lookup_in(kind, video_id).await {
                return Some((kind, entry));
            }
        }
        None
    }

    pub async fn lookup_in(&self, kind: StoreKind, video_id: &str) -> Option<AudioEntry> {
        let bytes = fs::read(self.meta_path(kind, video_id)).await.ok()?;
        let entry: AudioEntry = serde_json::from_slice(&bytes).ok()?;
        if !self.bin_path(kind, video_id).exists() {
            return None;
        }
        Some(entry)
    }

    pub async fn open_writer(
        &self,
        kind: StoreKind,
        video_id: &str,
        meta: AudioEntry,
    ) -> std::io::Result<AudioWriter> {
        self.open_writer_with_growth(kind, video_id, meta, None).await
    }

    async fn open_writer_with_growth(
        &self,
        kind: StoreKind,
        video_id: &str,
        mut meta: AudioEntry,
        growth: Option<Growth>,
    ) -> std::io::Result<AudioWriter> {
        let root = self.root(kind).to_path_buf();
        fs::create_dir_all(&root).await?;
        let bin = self.bin_path(kind, video_id);
        let existing = fs::metadata(&bin).await.map(|m| m.len()).unwrap_or(0);
        meta.video_id = video_id.to_owned();
        meta.downloaded_bytes = existing;
        meta.updated_at = now_secs();
        let file = fs::OpenOptions::new().create(true).append(true).open(&bin).await?;
        if let Some(g) = &growth {
            g.grow(existing, meta.expected_size);
        }
        Ok(AudioWriter {
            file,
            meta_path: self.meta_path(kind, video_id),
            meta,
            bytes_since_persist: 0,
            growth,
        })
    }

    pub async fn open_resumable(
        &self,
        kind: StoreKind,
        video_id: &str,
        meta: AudioEntry,
    ) -> std::io::Result<(GrowingFileSource, AudioWriter, Growth)> {
        let growth = Growth::new();
        let writer = self
            .open_writer_with_growth(kind, video_id, meta, Some(growth.clone()))
            .await?;

        let file = std::fs::File::open(self.bin_path(kind, video_id))?;
        let reader = GrowingFileSource::new(file, growth.clone());
        Ok((reader, writer, growth))
    }

    pub async fn list(&self, kind: StoreKind) -> Vec<AudioEntry> {
        let mut out = Vec::new();
        let Ok(mut dir) = fs::read_dir(self.root(kind)).await else {
            return out;
        };
        while let Ok(Some(entry)) = dir.next_entry().await {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            if let Ok(bytes) = fs::read(&path).await {
                if let Ok(e) = serde_json::from_slice::<AudioEntry>(&bytes) {
                    out.push(e);
                }
            }
        }
        out.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        out
    }

    pub async fn size(&self, kind: StoreKind) -> (u64, usize) {
        let entries = self.list(kind).await;
        let total: u64 = entries.iter().map(|e| e.downloaded_bytes).sum();
        (total, entries.len())
    }

    pub async fn remove(&self, video_id: &str) {
        for kind in [StoreKind::Cache, StoreKind::Download] {
            let _ = fs::remove_file(self.bin_path(kind, video_id)).await;
            let _ = fs::remove_file(self.meta_path(kind, video_id)).await;
        }
    }

    pub async fn clear(&self, kind: StoreKind) {
        let Ok(mut dir) = fs::read_dir(self.root(kind)).await else {
            return;
        };
        while let Ok(Some(entry)) = dir.next_entry().await {
            let _ = fs::remove_file(entry.path()).await;
        }
    }

    pub async fn evict_cache_to_limit(&self) -> usize {
        let limit = self.cache_limit();
        let entries = self.list(StoreKind::Cache).await;
        let mut total: u64 = entries.iter().map(|e| e.downloaded_bytes).sum();
        if total <= limit {
            return 0;
        }
        let mut removed = 0;
        for entry in entries.iter().rev() {
            if total <= limit {
                break;
            }
            let _ = fs::remove_file(self.bin_path(StoreKind::Cache, &entry.video_id)).await;
            let _ = fs::remove_file(self.meta_path(StoreKind::Cache, &entry.video_id)).await;
            total = total.saturating_sub(entry.downloaded_bytes);
            removed += 1;
        }
        removed
    }
}

pub struct AudioWriter {
    file: fs::File,
    meta_path: PathBuf,
    meta: AudioEntry,
    bytes_since_persist: u64,
    growth: Option<Growth>,
}

impl AudioWriter {
    const PERSIST_EVERY: u64 = 256 * 1024;

    pub async fn write(&mut self, data: &[u8]) -> std::io::Result<()> {
        if data.is_empty() {
            return Ok(());
        }
        self.file.write_all(data).await?;
        self.meta.downloaded_bytes += data.len() as u64;
        self.bytes_since_persist += data.len() as u64;
        if let Some(g) = &self.growth {
            g.grow(self.meta.downloaded_bytes, self.meta.expected_size);
        }
        if self.bytes_since_persist >= Self::PERSIST_EVERY {
            self.persist_meta().await.ok();
            self.bytes_since_persist = 0;
        }
        Ok(())
    }

    pub fn downloaded_bytes(&self) -> u64 {
        self.meta.downloaded_bytes
    }

    pub fn set_expected_size(&mut self, size: Option<u64>) {
        self.meta.expected_size = size;
        if let Some(g) = &self.growth {
            g.grow(self.meta.downloaded_bytes, size);
        }
    }

    pub fn meta(&self) -> &AudioEntry {
        &self.meta
    }

    pub async fn finish(&mut self, complete: bool) -> std::io::Result<AudioEntry> {
        self.file.flush().await?;
        self.file.sync_all().await.ok();
        self.meta.complete = complete
            || self
                .meta
                .expected_size
                .is_some_and(|s| self.meta.downloaded_bytes >= s);
        self.meta.updated_at = now_secs();
        self.persist_meta().await?;
        if let Some(g) = &self.growth {
            g.finish();
        }
        Ok(self.meta.clone())
    }

    pub fn cancel_growth(&self) {
        if let Some(g) = &self.growth {
            g.cancel();
        }
    }

    async fn persist_meta(&self) -> std::io::Result<()> {
        let bytes = serde_json::to_vec(&self.meta).map_err(std::io::Error::other)?;
        let tmp = self.meta_path.with_extension("json.tmp");
        fs::write(&tmp, bytes).await?;
        fs::rename(&tmp, &self.meta_path).await
    }
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
