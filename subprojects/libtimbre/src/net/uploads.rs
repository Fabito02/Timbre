use std::collections::BTreeMap;
use std::path::Path;

use serde_json::json;

use super::NetError;
use super::browse::{Browse, Continuation};
use super::items::{array_at, library_sections, next_continuation, parse_uploaded_items};
use crate::net::media::Track;

pub const SUPPORTED: [&str; 5] = ["mp3", "m4a", "wma", "flac", "ogg"];

const SIZE_LIMIT: u64 = 314_572_800;

pub async fn upload_song(
    http: &reqwest::Client,
    headers: &BTreeMap<String, String>,
    file: &Path,
) -> Result<(), NetError> {
    let extension = file
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or_default()
        .to_lowercase();
    if !SUPPORTED.contains(&extension.as_str()) {
        return Err(NetError::Message(format!(
            "YouTube Music does not take {extension} files. It takes {}.",
            SUPPORTED.join(", ")
        )));
    }
    let name = file
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("upload")
        .to_owned();
    let size = tokio::fs::metadata(file).await?.len();
    if size >= SIZE_LIMIT {
        return Err(NetError::Message(format!(
            "{name} is larger than the 300MB limit."
        )));
    }

    let authuser = headers
        .get("X-Goog-AuthUser")
        .map(String::as_str)
        .unwrap_or("0");
    let session = |mut request: reqwest::RequestBuilder| {
        for (key, value) in headers.iter().filter(|(key, _)| {
            !matches!(
                key.as_str(),
                "Content-Type" | "Content-Encoding" | "Content-Length"
            )
        }) {
            request = request.header(key, value);
        }
        request.header(
            "Content-Type",
            "application/x-www-form-urlencoded;charset=utf-8",
        )
    };

    let start = session(http.post(format!(
        "https://upload.youtube.com/upload/usermusic/http?authuser={authuser}"
    )))
    .header("X-Goog-Upload-Command", "start")
    .header("X-Goog-Upload-Protocol", "resumable")
    .header("X-Goog-Upload-Header-Content-Length", size.to_string())
    .body(format!("filename={name}"))
    .send()
    .await?;
    let upload_url = start
        .headers()
        .get("X-Goog-Upload-URL")
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned)
        .ok_or_else(|| {
            NetError::Message(format!("the upload was refused: HTTP {}", start.status()))
        })?;

    let bytes = tokio::fs::read(file).await?;
    let finish = session(http.post(&upload_url))
        .header("X-Goog-Upload-Command", "upload, finalize")
        .header("X-Goog-Upload-Offset", "0")
        .body(bytes)
        .send()
        .await?;
    let status = finish.status();
    let body = finish.text().await.unwrap_or_default();
    tracing::debug!(
        %status,
        body = %body.chars().take(200).collect::<String>(),
        "upload answer"
    );
    if status.is_success() {
        Ok(())
    } else {
        Err(NetError::Message(format!(
            "the upload failed: HTTP {status}"
        )))
    }
}

pub async fn delete_entity(api: &dyn Browse, entity_id: &str) -> Result<(), NetError> {
    api.post(
        "music/delete_privately_owned_entity",
        json!({ "entityId": entity_key(entity_id) }),
    )
    .await?;
    Ok(())
}

fn entity_key(entity_id: &str) -> &str {
    entity_id.trim_start_matches("FEmusic_library_privately_owned_release_detail")
}

pub async fn artist_songs(
    api: &dyn Browse,
    browse_id: &str,
    limit: usize,
) -> Result<Vec<Track>, NetError> {
    let response = api.post("browse", json!({ "browseId": browse_id })).await?;
    let Some(shelf) = library_sections(&response)
        .iter()
        .find_map(|section| section.get("musicShelfRenderer"))
    else {
        return Ok(Vec::new());
    };
    let mut songs = parse_uploaded_items(array_at(shelf, "/contents"));
    let rest = Continuation::browse(api, next_continuation(shelf))
        .limit(limit.saturating_sub(songs.len()))
        .collect(|entries| parse_uploaded_items(entries.iter().copied()))
        .await;
    songs.extend(rest.items);
    Ok(songs)
}
