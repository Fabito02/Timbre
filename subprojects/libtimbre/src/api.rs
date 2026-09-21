use anyhow::Result;
use async_trait::async_trait;

use crate::model::{Album, AlbumDetail, Artist, Playlist, PlaylistDetail, StreamAudio, Track};

#[async_trait]
pub trait MusicApi: Send + Sync {
    async fn search_tracks(&self, query: &str) -> Result<Vec<Track>>;

    async fn search_albums(&self, query: &str) -> Result<Vec<Album>>;

    async fn search_playlists(&self, query: &str) -> Result<Vec<Playlist>>;

    async fn search_artists(&self, query: &str) -> Result<Vec<Artist>>;

    async fn search_suggestions(&self, query: &str) -> Result<Vec<String>>;

    async fn get_album(&self, album_id: &str) -> Result<AlbumDetail>;

    async fn get_playlist_tracks(&self, playlist_id: &str) -> Result<Vec<Track>>;

    async fn get_playlist(&self, playlist_id: &str) -> Result<PlaylistDetail>;

    async fn get_stream(&self, track_id: &str) -> Result<StreamAudio>;
}
