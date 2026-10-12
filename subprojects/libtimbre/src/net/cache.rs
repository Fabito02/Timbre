use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use super::media::{MediaItem, Person, Track};
use crate::context::Paths;

#[derive(Debug, Clone, Default)]
pub struct LibraryIds {
    pub playlists: HashSet<String>,
    pub albums: HashSet<String>,
}

impl LibraryIds {
    pub fn contains(&self, id: &str) -> bool {
        let pid = id.strip_prefix("VL").unwrap_or(id);
        self.playlists.contains(pid) || self.albums.contains(pid)
    }
}

pub type SortMetric = HashMap<String, i64>;

const ALBUM_TRACKS_FILE: &str = "album_track_counts.json";

pub struct Caches {
    disk: PlaylistDiskCache,
    playlist_tracks: Mutex<HashMap<String, Vec<Track>>>,
    sort_metrics: Mutex<HashMap<(String, String), SortMetric>>,
    library_ids: Mutex<Option<LibraryIds>>,
    library_playlists: Mutex<Vec<MediaItem>>,
    subscribed_artists: Mutex<HashSet<String>>,
    album_tracks: Mutex<HashMap<String, u32>>,
    album_tracks_path: PathBuf,
}

impl Caches {
    pub fn new(paths: &Paths) -> Self {
        let album_tracks_path = paths.data_dir.join(ALBUM_TRACKS_FILE);
        let counts = std::fs::read(&album_tracks_path)
            .ok()
            .and_then(|b| serde_json::from_slice::<HashMap<String, u32>>(&b).ok())
            .unwrap_or_default();
        Self {
            disk: PlaylistDiskCache::new(paths),
            playlist_tracks: Mutex::default(),
            sort_metrics: Mutex::default(),
            library_ids: Mutex::default(),
            library_playlists: Mutex::default(),
            subscribed_artists: Mutex::default(),
            album_tracks: Mutex::new(counts),
            album_tracks_path,
        }
    }

    pub fn release_kind(track_count: u32) -> &'static str {
        match track_count {
            1 => "Single",
            2..=6 => "EP",
            _ => "Album",
        }
    }

    // YouTube mislabels some six-track EPs as "Single" on artist pages; a
    // real count learned from opening the album overrides that.
    pub fn release_kind_for(&self, album_id: &str) -> Option<&'static str> {
        self.album_tracks
            .lock()
            .unwrap()
            .get(album_id)
            .copied()
            .map(Self::release_kind)
    }

    pub fn set_album_track_count(&self, album_id: &str, track_count: u32) {
        if track_count == 0 {
            return;
        }
        let mut map = self.album_tracks.lock().unwrap();
        if map.insert(album_id.to_owned(), track_count) == Some(track_count) {
            return;
        }
        if let Ok(json) = serde_json::to_vec(&*map) {
            if let Err(err) = std::fs::write(&self.album_tracks_path, json) {
                tracing::debug!(%err, "album track counts not saved");
            }
        }
    }

    pub fn disk(&self) -> &PlaylistDiskCache {
        &self.disk
    }

    pub fn cached_tracks(&self, playlist_id: &str) -> Option<Vec<Track>> {
        self.playlist_tracks
            .lock()
            .unwrap()
            .get(playlist_id)
            .cloned()
    }

    pub fn set_cached_tracks(&self, playlist_id: &str, tracks: Vec<Track>) {
        self.playlist_tracks
            .lock()
            .unwrap()
            .insert(playlist_id.to_owned(), tracks);
    }

    pub fn drop_cached_tracks(&self, playlist_id: &str) {
        self.playlist_tracks.lock().unwrap().remove(playlist_id);
    }

    pub fn sort_metric(&self, kind: &str, browse_id: &str) -> Option<SortMetric> {
        self.sort_metrics
            .lock()
            .unwrap()
            .get(&(kind.to_owned(), browse_id.to_owned()))
            .cloned()
    }

    pub fn set_sort_metric(&self, kind: &str, browse_id: &str, metric: SortMetric) {
        self.sort_metrics
            .lock()
            .unwrap()
            .insert((kind.to_owned(), browse_id.to_owned()), metric);
    }

    pub fn drop_sort_metrics(&self, browse_id: &str) {
        self.sort_metrics
            .lock()
            .unwrap()
            .retain(|(_, b), _| b != browse_id);
    }

    pub fn library_ids(&self) -> Option<LibraryIds> {
        self.library_ids.lock().unwrap().clone()
    }

    pub fn set_library_ids(&self, ids: LibraryIds) {
        self.library_ids.lock().unwrap().replace(ids);
    }

    pub fn clear_library_ids(&self) {
        self.library_ids.lock().unwrap().take();
    }

    pub fn library_playlists(&self) -> Vec<MediaItem> {
        self.library_playlists.lock().unwrap().clone()
    }

    pub fn set_library_playlists(&self, playlists: Vec<MediaItem>) {
        *self.library_playlists.lock().unwrap() = playlists;
    }

    pub fn is_subscribed(&self, channel_id: &str) -> bool {
        self.subscribed_artists.lock().unwrap().contains(channel_id)
    }

    pub fn set_subscribed(&self, channel_id: &str, subscribed: bool) {
        let mut set = self.subscribed_artists.lock().unwrap();
        if subscribed {
            set.insert(channel_id.to_owned());
        } else {
            set.remove(channel_id);
        }
    }

    pub fn add_subscriptions(&self, ids: impl IntoIterator<Item = String>) {
        self.subscribed_artists.lock().unwrap().extend(ids);
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CachedMeta {
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub year: Option<String>,
    #[serde(default)]
    pub privacy: Option<String>,
    #[serde(default)]
    pub author_raw: Vec<Person>,
    #[serde(default)]
    pub collaborators: Option<String>,
    #[serde(default)]
    pub thumbnails: Vec<String>,
    #[serde(default)]
    pub duration_seconds: Option<u32>,
    #[serde(default)]
    pub audio_playlist_id: Option<String>,
    #[serde(default)]
    pub album_type: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CachedPlaylist {
    pub playlist_id: String,
    pub title: String,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub track_count: Option<u32>,
    #[serde(default)]
    pub last_synced: String,
    #[serde(default)]
    pub tracks: Vec<Track>,
    #[serde(default)]
    pub meta: CachedMeta,
}

pub struct PlaylistDiskCache {
    dir: PathBuf,
}

impl PlaylistDiskCache {
    pub fn new(paths: &Paths) -> Self {
        Self {
            dir: paths.data_dir.join("playlist_cache"),
        }
    }

    fn path(&self, playlist_id: &str) -> PathBuf {
        let safe: String = playlist_id
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                    c
                } else {
                    '_'
                }
            })
            .collect();
        self.dir.join(format!("{safe}.json"))
    }

    // RDTMAK mixes change on every fetch and are never cached.
    fn rejects(playlist_id: &str) -> bool {
        playlist_id.is_empty() || playlist_id.starts_with("RDTMAK")
    }

    pub fn get(&self, playlist_id: &str) -> Option<CachedPlaylist> {
        if Self::rejects(playlist_id) {
            return None;
        }
        let text = std::fs::read_to_string(self.path(playlist_id)).ok()?;
        serde_json::from_str(&text).ok()
    }

    pub fn has_tracks(&self, playlist_id: &str) -> bool {
        self.get(playlist_id).is_some_and(|c| !c.tracks.is_empty())
    }

    // Skips a write that would replace a richer copy with a partial fetch.
    pub fn put(&self, entry: &CachedPlaylist) {
        if Self::rejects(&entry.playlist_id) {
            return;
        }
        let existing_count = self
            .get(&entry.playlist_id)
            .map(|c| c.tracks.len())
            .unwrap_or(0);
        let new_count = entry.tracks.len();
        let is_full_fetch = entry.track_count.is_some_and(|c| new_count as u32 >= c);
        if existing_count > new_count && !is_full_fetch {
            tracing::info!(
                playlist_id = %entry.playlist_id,
                new_count,
                existing_count,
                "cache_playlist: skipping regression"
            );
            return;
        }
        if let Err(err) = self.write(entry) {
            tracing::warn!(%err, playlist_id = %entry.playlist_id, "playlist cache write failed");
        }
    }

    fn write(&self, entry: &CachedPlaylist) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.dir)?;
        let path = self.path(&entry.playlist_id);
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec(entry)?)?;
        std::fs::rename(&tmp, &path)
    }

    pub fn invalidate(&self, playlist_id: &str) {
        if playlist_id.is_empty() {
            return;
        }
        let _ = std::fs::remove_file(self.path(playlist_id));
    }

    #[allow(dead_code)]
    pub fn dir(&self) -> &Path {
        &self.dir
    }
}
