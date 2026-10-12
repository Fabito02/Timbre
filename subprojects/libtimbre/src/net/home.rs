use std::sync::Arc;

use serde::Serialize;
use serde_json::{Value, json};

use super::browse::{Browse, Continuation};
use super::items::{array_at, last_thumbnail_url, owned_at, parse_mixed_item};
use crate::net::NetError;
use crate::net::media::MediaItem;

const TAB_CONTENT: &str = "/contents/singleColumnBrowseResultsRenderer/tabs/0/tabRenderer/content";

#[derive(Clone, Debug, Default, Serialize)]
pub struct HomeSection {
    pub title: String,
    pub items: Vec<MediaItem>,
    pub strapline_thumb: Option<String>,
    pub strapline: Option<String>,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub browse_id: Option<String>,
    #[serde(default)]
    pub params: Option<String>,
}

pub async fn get_home(api: Arc<dyn Browse>, limit: usize) -> Result<Vec<HomeSection>, NetError> {
    let response = api
        .post("browse", json!({ "browseId": "FEmusic_home" }))
        .await?;
    let mut sections = parse_home(&response);
    let token = owned_at(
        &response,
        &format!(
            "{TAB_CONTENT}/sectionListRenderer/continuations/0/nextContinuationData/continuation"
        ),
    );
    let remaining = limit.saturating_sub(sections.len());
    if token.is_some() && remaining > 0 {
        let paged = Continuation::browse(&api, token)
            .limit(remaining)
            .collect(|page| {
                page.iter()
                    .filter_map(|shelf| parse_section(shelf))
                    .collect()
            })
            .await;
        if let Some(err) = &paged.error {
            tracing::warn!(%err, "home continuation failed");
        }
        sections.extend(paged.items);
    }
    sections.truncate(limit);
    mark_hero_dial(&mut sections);
    Ok(sections)
}

pub fn parse_home(response: &Value) -> Vec<HomeSection> {
    array_at(
        response,
        &format!("{TAB_CONTENT}/sectionListRenderer/contents"),
    )
    .iter()
    .filter_map(parse_section)
    .collect()
}

fn parse_section(shelf: &Value) -> Option<HomeSection> {
    if let Some(description) = shelf.get("musicDescriptionShelfRenderer") {
        let title = owned_at(description, "/header/runs/0/text")?;
        return Some(HomeSection {
            title,
            ..HomeSection::default()
        });
    }
    let renderer = shelf
        .as_object()?
        .values()
        .find(|v| v.get("contents").is_some())?;
    let header = renderer
        .pointer("/header/musicCarouselShelfBasicHeaderRenderer")
        .or_else(|| renderer.pointer("/header/musicImmersiveCarouselShelfBasicHeaderRenderer"));
    let title = header.and_then(|h| owned_at(h, "/title/runs/0/text"))?;
    let items = array_at(renderer, "/contents")
        .iter()
        .filter_map(|entry| parse_mixed_item(entry, &title))
        .collect();
    let strapline_thumb = header.and_then(|h| {
        last_thumbnail_url(array_at(
            h,
            "/thumbnail/musicThumbnailRenderer/thumbnail/thumbnails",
        ))
    });
    let strapline = header
        .and_then(|h| owned_at(h, "/strapline/runs/0/text"))
        .filter(|s| !s.trim().is_empty());

    let more = header
        .and_then(|h| h.get("moreContentButton"))
        .and_then(|b| b.get("buttonRenderer"))
        .and_then(|b| b.pointer("/navigationEndpoint/browseEndpoint"));
    let browse_id = more
        .and_then(|b| b.get("browseId"))
        .and_then(|v| v.as_str())
        .map(str::to_owned);
    let params = more
        .and_then(|b| b.get("params"))
        .and_then(|v| v.as_str())
        .map(str::to_owned);

    Some(HomeSection {
        title,
        items,
        strapline_thumb,
        strapline,
        kind: String::new(),
        browse_id,
        params,
    })
}

fn mark_hero_dial(sections: &mut [HomeSection]) {
    let by_id = sections
        .iter()
        .position(|s| s.browse_id.as_deref() == Some("FEmusic_listen_again"));

    let by_shape = || {
        sections.iter().position(|s| {
            if s.items.len() < 6 {
                return false;
            }
            let playable = s.items.iter().filter(|i| i.kind.is_playable()).count();
            playable == s.items.len()
        })
    };

    if let Some(i) = by_id.or_else(by_shape) {
        sections[i].kind = "hero_dial".into();
    }
}

pub fn is_podcast_section(title: &str) -> bool {
    let low = title.to_lowercase();
    ["shows for you", "podcast", "episode"]
        .iter()
        .any(|k| low.contains(k))
}

pub fn section_icon(title: &str) -> Option<&'static str> {
    let low = title.to_lowercase();
    const RULES: &[(&[&str], &str)] = &[
        (
            &["from your library", "your library"],
            "media-optical-symbolic",
        ),
        (
            &["forgotten", "rediscover", "hidden gem"],
            "starred-symbolic",
        ),
        (
            &["daily discover", "discovery mix", "discover mix"],
            "compass2-symbolic",
        ),
        (&["listen again"], "media-playback-start-symbolic"),
        (&["mix"], "media-playlist-shuffle-symbolic"),
        (
            &["new release", "new album", "new single"],
            "star-new-symbolic",
        ),
        (&["music video"], "video-x-generic-symbolic"),
        (&["mood", "moment"], "emoji-objects-symbolic"),
    ];
    RULES
        .iter()
        .find(|(keys, _)| keys.iter().any(|k| low.contains(k)))
        .map(|(_, icon)| *icon)
}
