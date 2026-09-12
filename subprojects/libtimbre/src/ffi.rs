use std::ffi::CStr;
use std::os::raw::c_char;
use std::sync::Arc;
use std::time::Duration;
use tokio::runtime::Runtime;

use crate::audio::AudioPlayer;

pub struct TimbrePlayerHandle {
    player: AudioPlayer,
    runtime: Arc<Runtime>,
}

#[unsafe(no_mangle)]
pub extern "C" fn timbre_player_new() -> *mut TimbrePlayerHandle {
    let runtime = match Runtime::new() {
        Ok(rt) => Arc::new(rt),
        Err(_) => return std::ptr::null_mut(),
    };

    let player = match AudioPlayer::new() {
        Ok(p) => p,
        Err(_) => return std::ptr::null_mut(),
    };

    let handle = TimbrePlayerHandle { player, runtime };
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

    handle
        .runtime
        .block_on(async { handle.player.seek(target).await })
        .is_ok()
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
