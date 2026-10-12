use std::sync::Arc;

use serde_json::{Value, json};

use super::browse::{Browse, Continuation};
use crate::net::NetError;
use crate::net::items::library_sections;
use crate::net::media::{ItemKind, MediaItem, Person};

const MAX_PAGES: usize = 40;

#[derive(Clone, Copy)]
enum Container {
    Grid,
    Shelf,
}

pub async fn library_playlists(api: Arc<dyn Browse>) -> Result<Vec<MediaItem>, NetError> {
    let entries = browse_all(&api, "FEmusic_liked_playlists", Container::Grid).await?;
    let mut items: Vec<MediaItem> = entries
        .iter()
        .filter_map(|r| parse_two_row(r, ItemKind::Playlist))
        .collect();
    items.sort_by_key(|p| if p.id.len() == 2 { 0 } else { 1 });
    Ok(items)
}

pub async fn library_albums(api: Arc<dyn Browse>) -> Result<Vec<MediaItem>, NetError> {
    let entries = browse_all(&api, "FEmusic_liked_albums", Container::Grid).await?;
    Ok(entries
        .iter()
        .filter_map(|r| parse_two_row(r, ItemKind::Album))
        .collect())
}

pub async fn library_subscriptions(api: Arc<dyn Browse>) -> Result<Vec<MediaItem>, NetError> {
    let entries = browse_all(&api, "FEmusic_library_corpus_artists", Container::Shelf).await?;
    Ok(entries.iter().filter_map(parse_artist_row).collect())
}

pub async fn upload_albums(api: Arc<dyn Browse>) -> Result<Vec<MediaItem>, NetError> {
    let entries = browse_all(
        &api,
        "FEmusic_library_privately_owned_releases",
        Container::Grid,
    )
    .await?;
    Ok(entries
        .iter()
        .filter_map(|r| parse_two_row(r, ItemKind::Album))
        .collect())
}

pub async fn upload_artists(api: Arc<dyn Browse>) -> Result<Vec<MediaItem>, NetError> {
    let entries = browse_all(
        &api,
        "FEmusic_library_privately_owned_artists",
        Container::Shelf,
    )
    .await?;
    Ok(entries.iter().filter_map(parse_artist_row).collect())
}

async fn browse_all(
    api: &dyn Browse,
    browse_id: &str,
    container: Container,
) -> Result<Vec<Value>, NetError> {
    let response = api.post("browse", json!({ "browseId": browse_id })).await?;
    let (container_key, items_key) = match container {
        Container::Grid => ("gridRenderer", "items"),
        Container::Shelf => ("musicShelfRenderer", "contents"),
    };
    let mut entries = Vec::new();
    let mut token = None;
    for section in library_sections(&response) {
        let node = section.get(container_key).or_else(|| {
            section.pointer(&format!("/itemSectionRenderer/contents/0/{container_key}"))
        });
        if let Some(node) = node {
            entries.extend(
                node.get(items_key)
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default(),
            );
            token = token.or_else(|| continuation_token(node));
        }
    }
    let rest = Continuation::browse(api, token)
        .pages(MAX_PAGES)
        .collect(|page| page.iter().map(|e| (*e).clone()).collect())
        .await;
    entries.extend(rest.strict()?);
    Ok(entries)
}

fn continuation_token(node: &Value) -> Option<String> {
    node.pointer("/continuations/0/nextContinuationData/continuation")
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn last_thumbnail(node: &Value, path: &str) -> Option<String> {
    node.pointer(path)
        .and_then(Value::as_array)
        .and_then(|t| t.last())
        .and_then(|t| t.get("url"))
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn subtitle_runs(renderer: &Value) -> Vec<(String, Option<String>)> {
    renderer
        .pointer("/subtitle/runs")
        .and_then(Value::as_array)
        .map(|runs| {
            runs.iter()
                .filter_map(|run| {
                    let text = run.get("text").and_then(Value::as_str)?.to_owned();
                    if text.trim() == "•" {
                        return None;
                    }
                    let id = run
                        .pointer("/navigationEndpoint/browseEndpoint/browseId")
                        .and_then(Value::as_str)
                        .map(str::to_owned);
                    Some((text, id))
                })
                .collect()
        })
        .unwrap_or_default()
}

// "41 tracks" gives "41"; "Your queued episodes" is a description, not a count.
fn count_from_text(text: &str) -> Option<String> {
    let low = text.to_lowercase();
    if !(low.contains("song") || low.contains("track") || low.contains("episode")) {
        return None;
    }
    let first = text.split_whitespace().next()?;
    first
        .chars()
        .next()
        .filter(|c| c.is_ascii_digit())
        .map(|_| first.to_owned())
}

pub(crate) fn parse_two_row(entry: &Value, kind: ItemKind) -> Option<MediaItem> {
    let renderer = entry.get("musicTwoRowItemRenderer")?;
    let title = renderer
        .pointer("/title/runs/0/text")
        .and_then(Value::as_str)?
        .to_owned();
    let browse_id = renderer
        .pointer("/navigationEndpoint/browseEndpoint/browseId")
        .and_then(Value::as_str)?;
    let id = if kind == ItemKind::Playlist {
        browse_id.trim_start_matches("VL").to_owned()
    } else {
        browse_id.to_owned()
    };
    let runs = subtitle_runs(renderer);
    let mut item = MediaItem {
        kind,
        id,
        title,
        thumb: last_thumbnail(
            renderer,
            "/thumbnailRenderer/musicThumbnailRenderer/thumbnail/thumbnails",
        ),
        ..MediaItem::default()
    };
    item.playlist_id = renderer
        .pointer("/menu/menuRenderer/items/0/menuNavigationItemRenderer/navigationEndpoint/watchPlaylistEndpoint/playlistId")
        .and_then(Value::as_str)
        .map(str::to_owned);
    match kind {
        ItemKind::Album => {
            for (i, (text, id)) in runs.into_iter().enumerate() {
                let trimmed = text.trim();
                if i == 0 && ["Album", "Single", "EP"].contains(&trimmed) {
                    item.item_type = Some(trimmed.to_owned());
                } else if trimmed.len() == 4 && trimmed.chars().all(|c| c.is_ascii_digit()) {
                    item.year = Some(trimmed.to_owned());
                } else {
                    item.artists.push(Person { name: text, id });
                }
            }
            if item.item_type.is_none() {
                item.item_type = Some("Album".to_owned());
            }
        }
        _ => {
            let full = runs
                .iter()
                .map(|(t, _)| t.trim())
                .collect::<Vec<_>>()
                .join(" • ");
            for (text, id) in runs {
                if let Some(count) = count_from_text(&text) {
                    item.count = Some(count);
                } else if text.trim() != "Playlist" {
                    item.artists.push(Person { name: text, id });
                }
            }
            item.description = Some(full);
        }
    }
    Some(item)
}

fn parse_artist_row(entry: &Value) -> Option<MediaItem> {
    let renderer = entry.get("musicResponsiveListItemRenderer")?;
    let name = renderer
        .pointer("/flexColumns/0/musicResponsiveListItemFlexColumnRenderer/text/runs/0/text")
        .and_then(Value::as_str)?
        .to_owned();
    let id = renderer
        .pointer("/navigationEndpoint/browseEndpoint/browseId")
        .and_then(Value::as_str)?
        .to_owned();
    let subscribers = renderer
        .pointer("/flexColumns/1/musicResponsiveListItemFlexColumnRenderer/text/runs/0/text")
        .and_then(Value::as_str)
        .map(str::to_owned);
    Some(MediaItem {
        kind: ItemKind::Artist,
        id,
        title: name,
        subscribers,
        thumb: last_thumbnail(
            renderer,
            "/thumbnail/musicThumbnailRenderer/thumbnail/thumbnails",
        ),
        ..MediaItem::default()
    })
}
