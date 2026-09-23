#![allow(unsafe_op_in_unsafe_fn)]

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::sync::Arc;
use std::time::Duration;
use tokio::runtime::Runtime;
use std::path::PathBuf;

use crate::api::MusicApi;
use crate::audio::AudioPlayer;
use crate::model::best_thumbnail;
use crate::youtube::YouTubeClient;

pub struct TimbrePlayerHandle {
    player: Arc<AudioPlayer>,
    runtime: Arc<Runtime>,
    yt: YouTubeClient,
}

// --- INTERNAL HELPERS ---

fn string_to_c_ptr(s: String) -> *mut c_char {
    let clean = s.replace('\0', "");
    match CString::new(clean) {
        Ok(c_str) => c_str.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn c_char_to_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr).to_str().ok().map(|s| s.to_string()) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

// --- STRUCTS C-COMPATIBLE ---

#[repr(C)]
pub struct CTrack {
    pub id: *mut c_char,
    pub title: *mut c_char,
    pub artists: *mut c_char,
    pub album: *mut c_char,
    pub thumbnail_url: *mut c_char,
    pub duration_secs: u64,
    pub is_explicit: bool,
    pub available: bool,
    pub kind: c_int,
    pub set_video_id: bool,
    pub liked: bool,
    pub views: u64,
}

impl CTrack {
    pub unsafe fn free_fields(&mut self) {
        timbre_string_free(self.id);
        timbre_string_free(self.title);
        timbre_string_free(self.artists);
        timbre_string_free(self.album);
        timbre_string_free(self.thumbnail_url);
    }
}

#[repr(C)]
pub struct CTrackList {
    pub items: *mut CTrack,
    pub len: usize,
}

#[repr(C)]
pub struct CAlbum {
    pub id: *mut c_char,
    pub title: *mut c_char,
    pub artists: *mut c_char,
    pub thumbnail_url: *mut c_char,
}

#[repr(C)]
pub struct CAlbumList {
    pub items: *mut CAlbum,
    pub len: usize,
}

#[repr(C)]
pub struct CPlaylist {
    pub id: *mut c_char,
    pub title: *mut c_char,
    pub author: *mut c_char,
    pub thumbnail_url: *mut c_char,
}

#[repr(C)]
pub struct CPlaylistList {
    pub items: *mut CPlaylist,
    pub len: usize,
}

#[repr(C)]
pub struct CArtist {
    pub id: *mut c_char,
    pub name: *mut c_char,
    pub thumbnail_url: *mut c_char,
}

#[repr(C)]
pub struct CArtistList {
    pub items: *mut CArtist,
    pub len: usize,
}

#[repr(C)]
pub struct CSuggestionList {
    pub items: *mut *mut c_char,
    pub len: usize,
}

// --- PLAYER LIFECYCLE ---

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_new() -> *mut TimbrePlayerHandle {
    let runtime = match Runtime::new() {
        Ok(rt) => Arc::new(rt),
        Err(_) => return std::ptr::null_mut(),
    };

    let player = match AudioPlayer::new() {
        Ok(p) => Arc::new(p),
        Err(_) => return std::ptr::null_mut(),
    };

    let yt = YouTubeClient::anonymous();

    let handle = Box::new(TimbrePlayerHandle {
        player,
        runtime,
        yt,
    });

    Box::into_raw(handle)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_free(handle: *mut TimbrePlayerHandle) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

// --- PLAYBACK CONTROL ---

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_play_file(
    handle: *mut TimbrePlayerHandle,
    path: *const c_char,
) -> bool {
    if handle.is_null() || path.is_null() {
        return false;
    }

    let handle = &*handle;
    let path_str = match c_char_to_string(path) {
        Some(s) => s,
        None => return false,
    };

    handle.player.play_file(&path_str).is_ok()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_play_url(
    handle: *mut TimbrePlayerHandle,
    url: *const c_char,
    duration_secs: u64,
) -> bool {
    if handle.is_null() || url.is_null() {
        return false;
    }

    let handle = &*handle;
    let url_str = match c_char_to_string(url) {
        Some(s) => s,
        None => return false,
    };

    let duration = if duration_secs > 0 {
        Some(Duration::from_secs(duration_secs))
    } else {
        None
    };

    handle
        .runtime
        .block_on(async { handle.player.play_url(&url_str, duration).await })
        .is_ok()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_play_track_id(
    handle: *mut TimbrePlayerHandle,
    track_id: *const c_char,
    duration_secs: u64,
) -> bool {
    if handle.is_null() || track_id.is_null() {
        eprintln!("[libtimbre] Error: null handle or track_id in FFI.");
        return false;
    }

    let handle = &*handle;
    let id_str = match c_char_to_string(track_id) {
        Some(s) => s,
        None => return false,
    };

    if id_str.is_empty() {
        return false;
    }

    let duration = if duration_secs > 0 {
        Some(Duration::from_secs(duration_secs))
    } else {
        None
    };

    handle.runtime.block_on(async {
        let stream = match handle.yt.get_stream(&id_str).await {
            Ok(s) => s,
            Err(e) => {
                eprintln!("[libtimbre] Failed to extract YouTube URL for '{}': {:?}", id_str, e);
                return false;
            }
        };

        match handle.player.play_url(&stream.url, duration).await {
            Ok(_) => true,
            Err(e) => {
                eprintln!("[libtimbre] Audio decoder failure: {:?}", e);
                false
            }
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_pause(handle: *mut TimbrePlayerHandle) {
    if let Some(h) = handle.as_ref() {
        h.player.pause();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_resume(handle: *mut TimbrePlayerHandle) {
    if let Some(h) = handle.as_ref() {
        h.player.resume();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_stop(handle: *mut TimbrePlayerHandle) {
    if let Some(h) = handle.as_ref() {
        h.player.stop();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_seek(
    handle: *mut TimbrePlayerHandle,
    target_secs: f64,
) -> bool {
    if handle.is_null() || target_secs < 0.0 {
        return false;
    }

    let handle = &*handle;
    let target = Duration::from_secs_f64(target_secs);
    let player = Arc::clone(&handle.player);

    handle.runtime.spawn(async move {
        let _ = player.seek(target).await;
    });

    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_get_position(handle: *mut TimbrePlayerHandle) -> f64 {
    if let Some(h) = handle.as_ref() {
        h.player.get_position().as_secs_f64()
    } else {
        0.0
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn timbre_player_get_duration(handle: *mut TimbrePlayerHandle) -> f64 {
    if handle.is_null() {
        return 0.0;
    }
    let wrapper = unsafe { &*handle };
    wrapper.player.get_duration().map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_is_finished(handle: *mut TimbrePlayerHandle) -> bool {
    if let Some(h) = handle.as_ref() {
        h.player.is_finished()
    } else {
        false
    }
}

// --- QUERIES AND SEARCH ---

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_search_tracks(
    handle: *mut TimbrePlayerHandle,
    query: *const c_char,
) -> *mut CTrackList {
    if handle.is_null() || query.is_null() {
        return std::ptr::null_mut();
    }

    let handle = &*handle;
    let query_str = match c_char_to_string(query) {
        Some(s) => s,
        None => return std::ptr::null_mut(),
    };

    let tracks = match handle.runtime.block_on(async { handle.yt.search_tracks(&query_str).await }) {
        Ok(t) => t,
        Err(_) => return std::ptr::null_mut(),
    };

    let mut c_tracks: Vec<CTrack> = tracks
        .into_iter()
        .map(|t| {
            let artists_joined = t
                .artists
                .iter()
                .map(|a| a.name.as_str())
                .collect::<Vec<_>>()
                .join(", ");

            let thumb = best_thumbnail(&t.thumbnails).map(|th| th.url.clone());
            let album_name = t.album.map(|a| a.name);

            CTrack {
                id: string_to_c_ptr(t.video_id.unwrap_or_default()),
                title: string_to_c_ptr(t.title),
                artists: string_to_c_ptr(artists_joined),
                album: album_name.map(string_to_c_ptr).unwrap_or(std::ptr::null_mut()),
                thumbnail_url: thumb.map(string_to_c_ptr).unwrap_or(std::ptr::null_mut()),
                duration_secs: t.duration.map(|d| d.as_secs()).unwrap_or(0),
                is_explicit: t.explicit,
                available: t.available,
                kind: t.kind as c_int,
                set_video_id: t.set_video_id.is_some(),
                liked: t.liked.unwrap_or(false),
                views: t.views.and_then(|v| v.parse::<u64>().ok()).unwrap_or(0),
            }
        })
        .collect();

    let len = c_tracks.len();
    let items = c_tracks.as_mut_ptr();
    std::mem::forget(c_tracks);

    Box::into_raw(Box::new(CTrackList { items, len }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_search_albums(
    handle: *mut TimbrePlayerHandle,
    query: *const c_char,
) -> *mut CAlbumList {
    if handle.is_null() || query.is_null() {
        return std::ptr::null_mut();
    }

    let handle = &*handle;
    let query_str = match c_char_to_string(query) {
        Some(s) => s,
        None => return std::ptr::null_mut(),
    };

    let albums = match handle.runtime.block_on(async { handle.yt.search_albums(&query_str).await }) {
        Ok(t) => t,
        Err(_) => return std::ptr::null_mut(),
    };

    let mut c_albums: Vec<CAlbum> = albums
        .into_iter()
        .map(|a| {
            let artists_joined = a
                .artists
                .iter()
                .map(|art| art.name.as_str())
                .collect::<Vec<_>>()
                .join(", ");

            let thumb = best_thumbnail(&a.thumbnails).map(|th| th.url.clone());

            CAlbum {
                id: string_to_c_ptr(a.browse_id),
                title: string_to_c_ptr(a.title),
                artists: string_to_c_ptr(artists_joined),
                thumbnail_url: thumb.map(string_to_c_ptr).unwrap_or(std::ptr::null_mut()),
            }
        })
        .collect();

    let len = c_albums.len();
    let items = c_albums.as_mut_ptr();
    std::mem::forget(c_albums);

    Box::into_raw(Box::new(CAlbumList { items, len }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_search_playlists(
    handle: *mut TimbrePlayerHandle,
    query: *const c_char,
) -> *mut CPlaylistList {
    if handle.is_null() || query.is_null() {
        return std::ptr::null_mut();
    }

    let handle = &*handle;
    let query_str = match c_char_to_string(query) {
        Some(s) => s,
        None => return std::ptr::null_mut(),
    };

    let playlists = match handle.runtime.block_on(async { handle.yt.search_playlists(&query_str).await }) {
        Ok(p) => p,
        Err(_) => return std::ptr::null_mut(),
    };

    let mut c_playlists: Vec<CPlaylist> = playlists
        .into_iter()
        .map(|p| {
            let thumb = best_thumbnail(&p.thumbnails).map(|th| th.url.clone());

            CPlaylist {
                id: string_to_c_ptr(p.id),
                title: string_to_c_ptr(p.title),
                author: p.author.map(string_to_c_ptr).unwrap_or(std::ptr::null_mut()),
                thumbnail_url: thumb.map(string_to_c_ptr).unwrap_or(std::ptr::null_mut()),
            }
        })
        .collect();

    let len = c_playlists.len();
    let items = c_playlists.as_mut_ptr();
    std::mem::forget(c_playlists);

    Box::into_raw(Box::new(CPlaylistList { items, len }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_search_artists(
    handle: *mut TimbrePlayerHandle,
    query: *const c_char,
) -> *mut CArtistList {
    if handle.is_null() || query.is_null() {
        return std::ptr::null_mut();
    }

    let handle = &*handle;
    let query_str = match c_char_to_string(query) {
        Some(s) => s,
        None => return std::ptr::null_mut(),
    };

    let artists = match handle.runtime.block_on(async { handle.yt.search_artists(&query_str).await }) {
        Ok(a) => a,
        Err(_) => return std::ptr::null_mut(),
    };

    let mut c_artists: Vec<CArtist> = artists
        .into_iter()
        .map(|a| {
            let thumb = best_thumbnail(&a.thumbnails).map(|th| th.url.clone());
            CArtist {
                id: string_to_c_ptr(a.browse_id),
                name: string_to_c_ptr(a.name),
                thumbnail_url: thumb.map(string_to_c_ptr).unwrap_or(std::ptr::null_mut()),
            }
        })
        .collect();

    let len = c_artists.len();
    let items = c_artists.as_mut_ptr();
    std::mem::forget(c_artists);

    Box::into_raw(Box::new(CArtistList { items, len }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_search_suggestions(
    handle: *mut TimbrePlayerHandle,
    query: *const c_char,
) -> *mut CSuggestionList {
    if handle.is_null() || query.is_null() {
        return std::ptr::null_mut();
    }

    let handle = &*handle;
    let query_str = match c_char_to_string(query) {
        Some(s) => s,
        None => return std::ptr::null_mut(),
    };

    let suggestions = match handle.runtime.block_on(async { handle.yt.search_suggestions(&query_str).await }) {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };

    let mut c_suggestions: Vec<*mut c_char> = suggestions
        .into_iter()
        .map(string_to_c_ptr)
        .collect();

    let len = c_suggestions.len();
    let items = c_suggestions.as_mut_ptr();
    std::mem::forget(c_suggestions);

    Box::into_raw(Box::new(CSuggestionList { items, len }))
}

// --- DEALLOCATION OF LISTS ---

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_track_list_free(ptr: *mut CTrackList) {
    if ptr.is_null() {
        return;
    }
    let list = Box::from_raw(ptr);
    if !list.items.is_null() && list.len > 0 {
        let mut tracks = Vec::from_raw_parts(list.items, list.len, list.len);
        for track in tracks.iter_mut() {
            track.free_fields();
        }
        drop(tracks);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_album_list_free(ptr: *mut CAlbumList) {
    if ptr.is_null() {
        return;
    }
    let list = Box::from_raw(ptr);
    if !list.items.is_null() && list.len > 0 {
        let mut albums = Vec::from_raw_parts(list.items, list.len, list.len);
        for album in albums.iter_mut() {
            timbre_string_free(album.id);
            timbre_string_free(album.title);
            timbre_string_free(album.artists);
            timbre_string_free(album.thumbnail_url);
        }
        drop(albums);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_playlist_list_free(ptr: *mut CPlaylistList) {
    if ptr.is_null() {
        return;
    }
    let list = Box::from_raw(ptr);
    if !list.items.is_null() && list.len > 0 {
        let mut playlists = Vec::from_raw_parts(list.items, list.len, list.len);
        for pl in playlists.iter_mut() {
            timbre_string_free(pl.id);
            timbre_string_free(pl.title);
            timbre_string_free(pl.author);
            timbre_string_free(pl.thumbnail_url);
        }
        drop(playlists);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_suggestion_list_free(ptr: *mut CSuggestionList) {
    if ptr.is_null() {
        return;
    }
    let list = Box::from_raw(ptr);
    if !list.items.is_null() && list.len > 0 {
        let items = Vec::from_raw_parts(list.items, list.len, list.len);
        for item in items {
            timbre_string_free(item);
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_artist_list_free(ptr: *mut CArtistList) {
    if ptr.is_null() {
        return;
    }
    let list = Box::from_raw(ptr);
    if !list.items.is_null() && list.len > 0 {
        let mut artists = Vec::from_raw_parts(list.items, list.len, list.len);
        for artist in artists.iter_mut() {
            timbre_string_free(artist.id);
            timbre_string_free(artist.name);
            timbre_string_free(artist.thumbnail_url);
        }
        drop(artists);
    }
}

// --- JSON RETRIEVAL ---

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_get_home_json(handle: *mut TimbrePlayerHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let handle = &*handle;

    match handle.runtime.block_on(async { handle.yt.get_home().await }) {
        Ok(sections) => {
            let json = serde_json::to_string(&sections).unwrap_or_else(|_| "[]".to_string());
            string_to_c_ptr(json)
        }
        Err(e) => {
            eprintln!("[libtimbre] Failed to fetch Home: {:?}", e);
            string_to_c_ptr("[]".to_string())
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_get_album_json(
    handle: *mut TimbrePlayerHandle,
    album_id: *const c_char,
) -> *mut c_char {
    if handle.is_null() || album_id.is_null() {
        return std::ptr::null_mut();
    }
    let handle = &*handle;
    let id = match c_char_to_string(album_id) {
        Some(s) => s,
        None => return std::ptr::null_mut(),
    };

    match handle.runtime.block_on(async { handle.yt.get_album(&id).await }) {
        Ok(detail) => {
            let json = serde_json::to_string(&detail).unwrap_or_else(|_| "{}".to_string());
            string_to_c_ptr(json)
        }
        Err(e) => {
            eprintln!("[libtimbre] Failed to fetch album {}: {:?}", id, e);
            string_to_c_ptr("{}".to_string())
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_get_playlist_json(
    handle: *mut TimbrePlayerHandle,
    playlist_id: *const c_char,
) -> *mut c_char {
    if handle.is_null() || playlist_id.is_null() {
        return std::ptr::null_mut();
    }
    let handle = &*handle;
    let id = match c_char_to_string(playlist_id) {
        Some(s) => s,
        None => return std::ptr::null_mut(),
    };

    match handle.runtime.block_on(async { handle.yt.get_playlist(&id).await }) {
        Ok(detail) => {
            let json = serde_json::to_string(&detail).unwrap_or_else(|_| "{}".to_string());
            string_to_c_ptr(json)
        }
        Err(e) => {
            eprintln!("[libtimbre] Failed to fetch playlist {}: {:?}", id, e);
            string_to_c_ptr("{}".to_string())
        }
    }
}

// --- LOGIN ---

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_login(
    handle: *mut TimbrePlayerHandle,
    cookies_ptr: *const c_char,
    path_ptr: *const c_char,
) -> bool {
    if handle.is_null() || cookies_ptr.is_null() || path_ptr.is_null() {
        return false;
    }

    let h = &mut *handle;
    
    let cookies_str = match c_char_to_string(cookies_ptr) {
        Some(s) => s,
        None => return false,
    };
    
    let path_str = match c_char_to_string(path_ptr) {
        Some(s) => s,
        None => return false,
    };

    let path_buf = PathBuf::from(path_str);

    let yt_instance = ytmusic::YtMusic::with_cookies(cookies_str)
        .persist_cookies(path_buf);

    let logged_client = YouTubeClient::new(Arc::new(yt_instance));

    h.yt = logged_client;

    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_load_cookies(
    handle: *mut TimbrePlayerHandle,
    path_ptr: *const c_char,
) -> bool {
    if handle.is_null() || path_ptr.is_null() {
        return false;
    }

    let h = &mut *handle;

    let path_str = match c_char_to_string(path_ptr) {
        Some(s) => s,
        None => return false,
    };

    let path_buf = PathBuf::from(path_str);
    if !path_buf.exists() {
        return false;
    }

    let yt_instance = ytmusic::YtMusic::anonymous()
        .persist_cookies(path_buf);

    h.yt = YouTubeClient::new(Arc::new(yt_instance));

    true
}
