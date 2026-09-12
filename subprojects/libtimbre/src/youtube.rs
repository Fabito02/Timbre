use std::sync::Arc;

use anyhow::{Context, Result};
use async_trait::async_trait;
use ytmusic::YtMusic;

use crate::api::MusicApi;
use crate::model::{Album, AlbumDetail, ArtistRef, Playlist, StreamAudio, Track};

pub struct YouTubeClient {
    api: Arc<YtMusic>,
}

impl YouTubeClient {
    pub fn new(api: Arc<YtMusic>) -> Self {
        Self { api }
    }

    pub fn anonymous() -> Self {
        Self {
            api: Arc::new(YtMusic::anonymous()),
        }
    }
}

fn map_track(t: ytmusic::Track) -> Option<Track> {
    let id = t.video_id?;
    let thumbnail_url = t.thumbnails.last().map(|thumb| thumb.url.clone());

    Some(Track {
        id,
        title: t.title,
        artists: t
            .artists
            .into_iter()
            .map(|a| ArtistRef {
                id: a.id,
                name: a.name,
            })
            .collect(),
        album: t.album.map(|a| a.name),
        duration_secs: t.duration.map(|d| d.as_secs()),
        thumbnail_url,
    })
}

fn map_album(a: ytmusic::Album) -> Album {
    Album {
        id: a.browse_id,
        title: a.title,
        artists: a
            .artists
            .into_iter()
            .map(|art| ArtistRef {
                id: art.id,
                name: art.name,
            })
            .collect(),
        year: a.year.map(|y| y.to_string()),
        thumbnail_url: a.thumbnails.last().map(|t| t.url.clone()),
    }
}

fn map_playlist(p: ytmusic::Playlist) -> Playlist {
    Playlist {
        id: p.id,
        title: p.title,
        author: p.author,
        track_count: None,
        thumbnail_url: p.thumbnails.last().map(|t| t.url.clone()),
    }
}

#[async_trait]
impl MusicApi for YouTubeClient {
    async fn search_tracks(&self, query: &str) -> Result<Vec<Track>> {
        let results = self.api.search_songs(query).await?;
        Ok(results.into_iter().filter_map(map_track).collect())
    }

    async fn search_albums(&self, query: &str) -> Result<Vec<Album>> {
        let results = self.api.search_albums(query).await?;
        Ok(results.into_iter().map(map_album).collect())
    }

    async fn search_playlists(&self, query: &str) -> Result<Vec<Playlist>> {
        let results = self.api.search_playlists(query).await?;
        Ok(results.into_iter().map(map_playlist).collect())
    }

    async fn get_album(&self, album_id: &str) -> Result<AlbumDetail> {
        let mut detail = self.api.album(album_id).await?;
        detail.tracks = self.api.swap_playable(detail.tracks).await;

        let album = map_album(detail.album);
        let tracks = detail.tracks.into_iter().filter_map(map_track).collect();

        Ok(AlbumDetail { album, tracks })
    }

    async fn get_playlist_tracks(&self, playlist_id: &str) -> Result<Vec<Track>> {
        let mut detail = self.api.playlist(playlist_id).await?;
        detail.tracks = self.api.swap_playable(detail.tracks).await;

        Ok(detail.tracks.into_iter().filter_map(map_track).collect())
    }

    async fn get_stream(&self, track_id: &str) -> Result<StreamAudio> {
        let audio = self
            .api
            .best_audio(track_id)
            .await
            .context("Failed to resolve audio stream")?;

        Ok(StreamAudio {
            url: audio.url,
            itag: audio.itag,
            mime: audio.mime,
            codec: audio.codec,
            bitrate: audio.bitrate,
        })
    }
}
