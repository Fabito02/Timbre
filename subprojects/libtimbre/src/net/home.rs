use std::sync::Arc;

use serde::Serialize;
use serde_json::{json, Value};

use super::browse::{Browse, Continuation};
use super::items::{array_at, last_thumbnail_url, owned_at, parse_mixed_item};
use crate::net::media::MediaItem;
use crate::net::NetError;

const TAB_CONTENT: &str =
    "/contents/singleColumnBrowseResultsRenderer/tabs/0/tabRenderer/content";

#[derive(Clone, Debug, Default, Serialize)]
pub struct HomeSection {
    pub title: String,
    pub items: Vec<MediaItem>,
    pub strapline_thumb: Option<String>,
    pub strapline: Option<String>,
}

pub async fn get_home(api: Arc<dyn Browse>, limit: usize) -> Result<Vec<HomeSection>, NetError> {
    let response = api.post("browse", json!({ "browseId": "FEmusic_home" })).await?;
    let mut sections = parse_home(&response);
    let token = owned_at(
        &response,
        &format!("{TAB_CONTENT}/sectionListRenderer/continuations/0/nextContinuationData/continuation"),
    );
    let remaining = limit.saturating_sub(sections.len());
    if token.is_some() && remaining > 0 {
        let paged = Continuation::browse(&api, token)
            .limit(remaining)
            .collect(|page| page.iter().filter_map(|shelf| parse_section(shelf)).collect())
            .await;
        if let Some(err) = &paged.error {
            tracing::warn!(%err, "home continuation failed");
        }
        sections.extend(paged.items);
    }
    sections.truncate(limit);
    Ok(sections)
}

pub fn parse_home(response: &Value) -> Vec<HomeSection> {
    array_at(response, &format!("{TAB_CONTENT}/sectionListRenderer/contents"))
        .iter()
        .filter_map(parse_section)
        .collect()
}

fn parse_section(shelf: &Value) -> Option<HomeSection> {
    if let Some(description) = shelf.get("musicDescriptionShelfRenderer") {
        let title = owned_at(description, "/header/runs/0/text")?;
        return Some(HomeSection { title, ..HomeSection::default() });
    }
    // Whatever single renderer the row holds, so an unseen shelf kind
    // still yields its title and cards.
    let renderer = shelf.as_object()?.values().find(|v| v.get("contents").is_some())?;
    let header = renderer
        .pointer("/header/musicCarouselShelfBasicHeaderRenderer")
        .or_else(|| renderer.pointer("/header/musicImmersiveCarouselShelfBasicHeaderRenderer"));
    let title = header.and_then(|h| owned_at(h, "/title/runs/0/text"))?;
    let items = array_at(renderer, "/contents")
        .iter()
        .filter_map(|entry| parse_mixed_item(entry, &title))
        .collect();
    let strapline_thumb = header.and_then(|h| {
        last_thumbnail_url(array_at(h, "/thumbnail/musicThumbnailRenderer/thumbnail/thumbnails"))
    });
    let strapline = header
        .and_then(|h| owned_at(h, "/strapline/runs/0/text"))
        .filter(|s| !s.trim().is_empty());
    Some(HomeSection { title, items, strapline_thumb, strapline })
}

pub fn is_podcast_section(title: &str) -> bool {
    let low = title.to_lowercase();
    ["shows for you", "podcast", "episode"].iter().any(|k| low.contains(k))
}

pub fn is_long_listens(title: &str) -> bool {
    title.to_lowercase().contains("long listen")
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Bucket {
    Library,
    ListenAgain,
    Discover,
    Forgotten,
}

pub const BUCKETS: [Bucket; 4] = [
    Bucket::Library,
    Bucket::ListenAgain,
    Bucket::Discover,
    Bucket::Forgotten,
];

impl Bucket {
    fn keys(self) -> &'static [&'static str] {
        match self {
            Bucket::Library => &["your library", "from your library"],
            Bucket::ListenAgain => &["listen again", "your favorites", "recent activity"],
            Bucket::Discover => &[
                "daily discover",
                "discover mix",
                "discovery mix",
                "made for you",
                "recommended for today",
            ],
            Bucket::Forgotten => &["forgotten favorites", "hidden gems", "rediscover"],
        }
    }
}

pub fn classify_section(title: &str) -> Option<Bucket> {
    let low = title.to_lowercase();
    BUCKETS
        .into_iter()
        .find(|bucket| bucket.keys().iter().any(|k| low.contains(k)))
}

pub fn section_icon(title: &str) -> Option<&'static str> {
    let low = title.to_lowercase();
    const RULES: &[(&[&str], &str)] = &[
        (&["from your library", "your library"], "media-optical-symbolic"),
        (&["forgotten", "rediscover", "hidden gem"], "starred-symbolic"),
        (&["daily discover", "discovery mix", "discover mix"], "compass2-symbolic"),
        (&["listen again"], "media-playback-start-symbolic"),
        (&["mix"], "media-playlist-shuffle-symbolic"),
        (&["new release", "new album", "new single"], "star-new-symbolic"),
        (&["music video"], "video-x-generic-symbolic"),
        (&["mood", "moment"], "emoji-objects-symbolic"),
        (&["recap"], "media-playback-start-symbolic"),
        (&["quick pick"], "media-playback-start-symbolic"),
    ];
    RULES
        .iter()
        .find(|(keys, _)| keys.iter().any(|k| low.contains(k)))
        .map(|(_, icon)| *icon)
}

pub fn arrange(sections: Vec<HomeSection>) -> (Vec<MediaItem>, Vec<HomeSection>) {
    let mut sections: Vec<HomeSection> = sections
        .into_iter()
        .filter(|s| !s.items.is_empty() && !is_podcast_section(&s.title))
        .collect();

    let quick = sections
        .iter()
        .position(|s| s.title.to_lowercase().contains("quick pick"));
    let mut dial = match quick {
        Some(index) => sections.remove(index).items,
        None => Vec::new(),
    };
    if dial.is_empty() {
        let fallback = sections
            .iter()
            .position(|s| classify_section(&s.title) == Some(Bucket::ListenAgain))
            .unwrap_or(0);
        dial = sections.get(fallback).map(|s| s.items.clone()).unwrap_or_default();
    }

    let mut leading: Vec<Option<HomeSection>> = BUCKETS.iter().map(|_| None).collect();
    let mut rest = Vec::new();
    for section in sections {
        match classify_section(&section.title)
            .map(|b| BUCKETS.iter().position(|x| *x == b).unwrap_or_default())
        {
            Some(slot) if leading[slot].is_none() => leading[slot] = Some(section),
            _ => rest.push(section),
        }
    }
    let ordered: Vec<HomeSection> = leading.into_iter().flatten().chain(rest).collect();
    (dial, ordered)
}
