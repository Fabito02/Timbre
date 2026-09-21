use std::sync::Arc;

use anyhow::{Context, Result};
use async_trait::async_trait;
use ytmusic::YtMusic;

use crate::api::MusicApi;
use crate::model::{
    Album, AlbumDetail, AlbumKind, AlbumRef, Artist, ArtistRef, HomeItem, HomeSection,
    Playlist, PlaylistDetail, StreamAudio, Thumbnail, Track, TrackKind,
};

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

    pub async fn get_home(&self) -> Result<Vec<HomeSection>> {
        use serde_json::json;
        use ytmusic::context::Client;
        use ytmusic::nav::Nav;
        use ytmusic::parse;

        let response = self
            .api
            .execute(
                "browse",
                Client::Music,
                json!({ "browseId": "FEmusic_home" }),
            )
            .await?;

        let mut sections: Vec<HomeSection> = Vec::new();

        for carousel in parse::find_renderers(&response, "musicCarouselShelfRenderer") {
            let title = carousel
                .run_text(&["header", "musicCarouselShelfBasicHeaderRenderer", "title"])
                .unwrap_or_default();

            let mut items = Vec::new();

            for item in carousel.items(&["contents"]) {
                if let Some(yt_track) = parse::list_item_track(item) {
                    if let Some(mapped) = map_track(yt_track) {
                        items.push(HomeItem::Track(mapped));
                    }
                } else if let Some(yt_album) = parse::two_row_album(item) {
                    items.push(HomeItem::Album(map_album(yt_album)));
                } else if let Some(yt_playlist) = parse::two_row_playlist(item) {
                    let mut playlist = map_playlist(yt_playlist);
                    let real_cover = item
                        .pointer("/musicTwoRowItemRenderer/thumbnailRenderer/musicThumbnailRenderer/thumbnail/thumbnails")
                        .or_else(|| item.pointer("/thumbnailRenderer/musicThumbnailRenderer/thumbnail/thumbnails"))
                        .and_then(|v| v.as_array())
                        .and_then(|arr| arr.last())
                        .and_then(|thumb| thumb.get("url"))
                        .and_then(|u| u.as_str())
                        .map(|s| s.to_string());

                    if let Some(cover) = real_cover {
                        playlist.thumbnails = vec![Thumbnail {
                            url: cover,
                            width: 500,
                            height: 500,
                        }];
                    }

                    items.push(HomeItem::Playlist(playlist));
                }
            }

            if !items.is_empty() {
                sections.push(HomeSection { title, items });
            }
        }

        Ok(sections)
    }
}

fn map_track(t: ytmusic::Track) -> Option<Track> {
    let video_id = t.video_id;

    Some(Track {
        video_id,
        title: t.title,
        artists: t
            .artists
            .into_iter()
            .map(|a| ArtistRef {
                id: a.id,
                name: a.name,
            })
            .collect(),
        album: t.album.map(|a| AlbumRef {
            id: a.id,
            name: a.name,
        }),
        duration: t.duration,
        thumbnails: t
            .thumbnails
            .into_iter()
            .map(|th| Thumbnail {
                url: th.url,
                width: th.width,
                height: th.height,
            })
            .collect(),
        explicit: false,
        available: true,
        kind: TrackKind::Song,
        set_video_id: None,
        liked: None,
        views: None,
    })
}

fn map_album(a: ytmusic::Album) -> Album {
    Album {
        browse_id: a.browse_id,
        playlist_id: None,
        title: a.title,
        artists: a
            .artists
            .into_iter()
            .map(|art| ArtistRef {
                id: art.id,
                name: art.name,
            })
            .collect(),
        kind: AlbumKind::Album,
        year: a.year,
        track_count: None,
        thumbnails: a
            .thumbnails
            .into_iter()
            .map(|th| Thumbnail {
                url: th.url,
                width: th.width,
                height: th.height,
            })
            .collect(),
    }
}

fn map_playlist(p: ytmusic::Playlist) -> Playlist {
    Playlist {
        id: p.id,
        title: p.title,
        author: p.author,
        owned: false,
        public: None,
        track_count: None,
        thumbnails: p
            .thumbnails
            .into_iter()
            .map(|th| Thumbnail {
                url: th.url,
                width: th.width,
                height: th.height,
            })
            .collect(),
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

    async fn search_artists(&self, _query: &str) -> Result<Vec<Artist>> {
        Ok(Vec::new())
    }

    async fn search_suggestions(&self, query: &str) -> Result<Vec<String>> {
        let suggestions = self.api.search_suggestions(query).await?;
        Ok(suggestions)
    }

    async fn get_album(&self, album_id: &str) -> Result<AlbumDetail> {
        let mut detail = self.api.album(album_id).await?;
        detail.tracks = self.api.swap_playable(detail.tracks).await;

        let album = map_album(detail.album);
        let tracks = detail.tracks.into_iter().filter_map(map_track).collect();

        Ok(AlbumDetail {
            album,
            description: None,
            duration_text: None,
            tracks,
        })
    }

    async fn get_playlist(&self, playlist_id: &str) -> Result<PlaylistDetail> {
        use serde_json::json;
        use ytmusic::context::Client;
        use ytmusic::nav::Nav;
        use ytmusic::parse;

        let browse_id = if playlist_id.starts_with("VL") {
            playlist_id.to_string()
        } else {
            format!("VL{}", playlist_id)
        };

        let response = self
            .api
            .execute(
                "browse",
                Client::Music,
                json!({ "browseId": browse_id }),
            )
            .await?;

        let header_renderer = response
            .pointer("/header/musicDetailHeaderRenderer")
            .or_else(|| response.pointer("/header/musicResponsiveHeaderRenderer"))
            .or_else(|| {
                response.pointer(
                    "/header/musicEditablePlaylistDetailHeaderRenderer/header/musicResponsiveHeaderRenderer",
                )
            });

        let title = header_renderer
            .and_then(|h| h.run_text(&["title"]))
            .unwrap_or_else(|| "Playlist".to_string());

        let author = header_renderer.and_then(|h| {
            h.run_text(&["subtitle"])
                .or_else(|| h.run_text(&["straplineTextOne"]))
        });

        let thumbnail_url = header_renderer
            .and_then(|h| {
                h.pointer("/thumbnail/musicThumbnailRenderer/thumbnail/thumbnails")
                    .or_else(|| {
                        h.pointer("/thumbnail/croppedSquareThumbnailRenderer/thumbnail/thumbnails")
                    })
            })
            .and_then(|t| t.as_array())
            .and_then(|arr| arr.last())
            .and_then(|thumb| thumb.get("url"))
            .and_then(|u| u.as_str())
            .map(|s| s.to_string());

        let mut tracks: Vec<Track> = Vec::new();

        for item in parse::find_renderers(&response, "musicResponsiveListItemRenderer") {
            if let Some(yt_track) = parse::list_item_track(item) {
                if let Some(mapped) = map_track(yt_track) {
                    tracks.push(mapped);
                }
            }
        }

        let thumbnails = match thumbnail_url {
            Some(u) => vec![Thumbnail {
                url: u,
                width: 500,
                height: 500,
            }],
            None => Vec::new(),
        };

        let playlist = Playlist {
            id: playlist_id.to_string(),
            title,
            author,
            owned: false,
            public: Some(true),
            track_count: Some(tracks.len() as u32),
            thumbnails,
        };

        Ok(PlaylistDetail {
            playlist,
            public: true,
            tracks,
            continuation: None,
        })
    }

    async fn get_playlist_tracks(&self, playlist_id: &str) -> Result<Vec<Track>> {
        let detail = self.get_playlist(playlist_id).await?;
        Ok(detail.tracks)
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
