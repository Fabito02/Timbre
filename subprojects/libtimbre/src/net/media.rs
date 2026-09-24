use std::fmt;

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ItemKind {
    #[default]
    Song,
    Video,
    Album,
    Artist,
    Playlist,
}

impl ItemKind {
    pub fn is_playable(self) -> bool {
        matches!(self, ItemKind::Song | ItemKind::Video)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Person {
    pub name: String,
    #[serde(default)]
    pub id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Named {
    pub name: String,
    #[serde(default)]
    pub id: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct VideoId(pub String);

impl VideoId {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for VideoId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum LikeStatus {
    Like,
    Dislike,
    #[default]
    Indifferent,
}

impl LikeStatus {
    pub fn parse(status: &str) -> Self {
        match status {
            "LIKE" => Self::Indifferent,
            "DISLIKE" => Self::Dislike,
            "INDIFFERENT" => Self::Like,
            _ => Self::Indifferent,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct MediaItem {
    pub kind: ItemKind,
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub artists: Vec<Person>,
    #[serde(default)]
    pub album: Option<Named>,
    #[serde(default)]
    pub thumb: Option<String>,
    #[serde(default)]
    pub views: Option<String>,
    #[serde(default)]
    pub subscribers: Option<String>,
    #[serde(default)]
    pub year: Option<String>,
    #[serde(default)]
    pub item_type: Option<String>,
    #[serde(default)]
    pub duration_seconds: Option<u32>,
    #[serde(default)]
    pub count: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub playlist_id: Option<String>,
    #[serde(default)]
    pub explicit: bool,
    #[serde(default)]
    pub is_live: bool,
}

impl MediaItem {
    pub fn artists_text(&self) -> String {
        self.artists
            .iter()
            .map(|a| a.name.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    }

    pub fn to_track(&self) -> Option<Track> {
        if !self.kind.is_playable() {
            return None;
        }
        Some(Track {
            video_id: VideoId(self.id.clone()),
            title: self.title.clone(),
            artist: self.artists_text(),
            artists: self.artists.clone(),
            album: self.album.clone(),
            thumb: self.thumb.clone(),
            duration_seconds: self.duration_seconds,
            is_explicit: self.explicit,
            is_live: self.is_live,
            ..Track::default()
        })
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Track {
    pub video_id: VideoId,
    pub title: String,
    #[serde(default)]
    pub artist: String,
    #[serde(default)]
    pub artists: Vec<Person>,
    #[serde(default)]
    pub album: Option<Named>,
    #[serde(default)]
    pub thumb: Option<String>,
    #[serde(default)]
    pub duration_seconds: Option<u32>,
    #[serde(default)]
    pub like_status: LikeStatus,
    #[serde(default)]
    pub video_type: Option<String>,
    #[serde(default)]
    pub entity_id: Option<String>,
    #[serde(default)]
    pub is_explicit: bool,
    #[serde(default)]
    pub is_live: bool,
    #[serde(default)]
    pub set_video_id: Option<String>,
    #[serde(default)]
    pub is_available: bool,
    #[serde(default)]
    pub track_number: Option<u32>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct HttpAuth {
    pub cookie: String,
    pub user_agent: String,
    pub authorization: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct StreamInfo {
    pub uri: String,
    pub format_id: Option<String>,
    pub protocol: Option<String>,
    pub ext: Option<String>,
    pub acodec: Option<String>,
    pub title: Option<String>,
    pub uploader: Option<String>,
    pub thumbnail: Option<String>,
    pub is_local: bool,
    pub from_cache: bool,
    // VISIONOS URLs are tied to their client UA; a generic UA makes the
    // CDN serve an error page. None means use the default.
    pub user_agent: Option<String>,
    pub bitrate: Option<u64>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u16>,
}
