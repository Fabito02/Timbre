use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::Arc;
use std::time::Duration;
use tokio::runtime::Runtime;

use crate::api::MusicApi;
use crate::audio::AudioPlayer;
use crate::youtube::YouTubeClient;

pub struct TimbrePlayerHandle {
    player: Arc<AudioPlayer>,
    runtime: Arc<Runtime>,
    yt: YouTubeClient,
}

#[repr(C)]
pub struct CTrack {
    pub id: *mut c_char,
    pub title: *mut c_char,
    pub artists: *mut c_char,
    pub album: *mut c_char,
    pub thumbnail_url: *mut c_char,
    pub duration_secs: u64,
}

#[repr(C)]
pub struct CTrackList {
    pub items: *mut CTrack,
    pub len: usize,
}

fn string_to_c_ptr(s: String) -> *mut c_char {
    CString::new(s).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut())
}

unsafe fn free_c_ptr(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            drop(CString::from_raw(ptr));
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn timbre_player_new() -> *mut TimbrePlayerHandle {
    let runtime = match Runtime::new() {
        Ok(rt) => Arc::new(rt),
        Err(_) => return std::ptr::null_mut(),
    };

    let player = match AudioPlayer::new() {
        Ok(p) => Arc::new(p),
        Err(_) => return std::ptr::null_mut(),
    };

    let yt = YouTubeClient::anonymous();

    let handle = TimbrePlayerHandle {
        player,
        runtime,
        yt,
    };
    Box::into_raw(Box::new(handle))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_free(handle: *mut TimbrePlayerHandle) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_play_file(
    handle: *mut TimbrePlayerHandle,
    path: *const c_char,
) -> bool {
    if handle.is_null() || path.is_null() {
        return false;
    }

    let (handle, path_str) = unsafe {
        let h = &*handle;
        let p = match CStr::from_ptr(path).to_str() {
            Ok(s) => s,
            Err(_) => return false,
        };
        (h, p)
    };

    handle.player.play_file(path_str).is_ok()
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

    let (handle, url_str) = unsafe {
        let h = &*handle;
        let u = match CStr::from_ptr(url).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => return false,
        };
        (h, u)
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
        return false;
    }

    let (handle, id_str) = unsafe {
        let h = &*handle;
        let id = match CStr::from_ptr(track_id).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => return false,
        };
        (h, id)
    };

    let duration = if duration_secs > 0 {
        Some(Duration::from_secs(duration_secs))
    } else {
        None
    };

    handle.runtime.block_on(async {
        let stream = match handle.yt.get_stream(&id_str).await {
            Ok(s) => s,
            Err(_) => return false,
        };

        handle.player.play_url(&stream.url, duration).await.is_ok()
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_pause(handle: *mut TimbrePlayerHandle) {
    if let Some(h) = unsafe { handle.as_ref() } {
        h.player.pause();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_resume(handle: *mut TimbrePlayerHandle) {
    if let Some(h) = unsafe { handle.as_ref() } {
        h.player.resume();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_stop(handle: *mut TimbrePlayerHandle) {
    if let Some(h) = unsafe { handle.as_ref() } {
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

    let handle = unsafe { &*handle };
    let target = Duration::from_secs_f64(target_secs);
    let player = Arc::clone(&handle.player);

    handle.runtime.spawn(async move {
        let _ = player.seek(target).await;
    });

    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_get_position(handle: *mut TimbrePlayerHandle) -> f64 {
    if let Some(h) = unsafe { handle.as_ref() } {
        h.player.get_position().as_secs_f64()
    } else {
        0.0
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_is_finished(handle: *mut TimbrePlayerHandle) -> bool {
    if let Some(h) = unsafe { handle.as_ref() } {
        h.player.is_finished()
    } else {
        false
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_search_tracks(
    handle: *mut TimbrePlayerHandle,
    query: *const c_char,
) -> *mut CTrackList {
    if handle.is_null() || query.is_null() {
        return std::ptr::null_mut();
    }

    let handle = unsafe { &*handle };
    let query_str = match unsafe { CStr::from_ptr(query).to_str() } {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };

    let tracks = match handle.runtime.block_on(async { handle.yt.search_tracks(query_str).await }) {
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

            CTrack {
                id: string_to_c_ptr(t.id),
                title: string_to_c_ptr(t.title),
                artists: string_to_c_ptr(artists_joined),
                album: t.album.map(string_to_c_ptr).unwrap_or(std::ptr::null_mut()),
                thumbnail_url: t.thumbnail_url.map(string_to_c_ptr).unwrap_or(std::ptr::null_mut()),
                duration_secs: t.duration_secs.unwrap_or(0),
            }
        })
        .collect();

    let len = c_tracks.len();
    
    let items = c_tracks.as_mut_ptr();
    std::mem::forget(c_tracks);

    let list = Box::new(CTrackList { items, len });
    Box::into_raw(list)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_track_list_free(list_ptr: *mut CTrackList) {
    if list_ptr.is_null() {
        return;
    }

    let list = unsafe { Box::from_raw(list_ptr) };

    if !list.items.is_null() && list.len > 0 {
        let tracks = unsafe { Vec::from_raw_parts(list.items, list.len, list.len) };

        for track in tracks {
            unsafe {
                free_c_ptr(track.id);
                free_c_ptr(track.title);
                free_c_ptr(track.artists);
                free_c_ptr(track.album);
                free_c_ptr(track.thumbnail_url);
            }
        }
    }
}
