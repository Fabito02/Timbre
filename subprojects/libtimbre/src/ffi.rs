#![allow(unsafe_op_in_unsafe_fn)]

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use serde::Serialize;
use tokio::runtime::Runtime;

use crate::audio::store::{AudioEntry, StoreKind};
use crate::audio::{AudioPlayer, PlayerState};
use crate::context::TimbreContext;
use crate::net::media::{HttpAuth, LikeStatus, StreamInfo, VideoId};
use crate::net::stream::StreamResolver;
use crate::net::{artist, explore, history, home, library, playlists, search};

static TRACING_READY: AtomicBool = AtomicBool::new(false);

fn install_tracing(level: u8) {
    if TRACING_READY.swap(true, Ordering::SeqCst) {
        return;
    }

    let default = match level {
        0 => "off",
        1 => "timbre=info",
        2 => "timbre=debug",
        _ => "timbre=trace",
    };
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(default));
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_target(true)
        .try_init();
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_set_log_level(level: c_int) {
    install_tracing(level.clamp(0, 3) as u8);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_set_locale(hl: *const c_char, gl: *const c_char) {
    let hl = from_c(hl).unwrap_or_else(|| "en".into());
    let gl = from_c(gl).unwrap_or_else(|| "US".into());
    crate::context::set_locale(hl, gl);
}

pub type TimbreCallback =
    unsafe extern "C" fn(json: *mut c_char, error: *mut c_char, ud: *mut c_void);
pub type TimbreDoneCallback =
    unsafe extern "C" fn(success: bool, error: *mut c_char, ud: *mut c_void);

pub struct TimbrePlayerHandle {
    player: Arc<AudioPlayer>,
    runtime: Arc<Runtime>,
    ctx: Arc<TimbreContext>,
    playback_session: Arc<std::sync::Mutex<Option<history::PlaySession>>>,
    playback_gen: Arc<AtomicU64>,
}

#[derive(Clone, Copy)]
struct SendPtr(usize);

impl SendPtr {
    fn new(p: *mut c_void) -> Self {
        Self(p as usize)
    }
    fn raw(self) -> usize {
        self.0
    }
}

fn to_c(s: String) -> *mut c_char {
    let clean = s.replace('\0', "");
    match CString::new(clean) {
        Ok(c) => c.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn from_c(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr).to_str().ok().map(str::to_owned) }
}

fn none_if_empty(s: &str) -> Option<&str> {
    if s.is_empty() { None } else { Some(s) }
}

fn dispatch_json<T: Serialize>(cb: Option<TimbreCallback>, ud: usize, result: Result<T, String>) {
    let Some(cb) = cb else { return };
    let ud = ud as *mut c_void;
    match result {
        Ok(value) => match serde_json::to_string(&value) {
            Ok(s) => {
                let json = to_c(s);
                unsafe { cb(json, std::ptr::null_mut(), ud) };
            }
            Err(e) => {
                let err = to_c(format!("serialization: {e}"));
                unsafe { cb(std::ptr::null_mut(), err, ud) };
            }
        },
        Err(msg) => {
            let err = to_c(msg);
            unsafe { cb(std::ptr::null_mut(), err, ud) };
        }
    }
}

fn dispatch_done(cb: Option<TimbreDoneCallback>, ud: usize, result: Result<(), String>) {
    let Some(cb) = cb else { return };
    let ud = ud as *mut c_void;
    match result {
        Ok(()) => unsafe { cb(true, std::ptr::null_mut(), ud) },
        Err(msg) => {
            let err = to_c(msg);
            unsafe { cb(false, err, ud) };
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_new() -> *mut TimbrePlayerHandle {
    install_tracing(1);

    let runtime = match Runtime::new() {
        Ok(rt) => Arc::new(rt),
        Err(e) => {
            eprintln!("[libtimbre] runtime: {e:?}");
            return std::ptr::null_mut();
        }
    };
    let ctx = match TimbreContext::new(&runtime) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[libtimbre] context: {e:?}");
            return std::ptr::null_mut();
        }
    };
    let player = match AudioPlayer::new(&ctx.paths) {
        Ok(p) => Arc::new(p),
        Err(e) => {
            eprintln!("[libtimbre] audio: {e:?}");
            return std::ptr::null_mut();
        }
    };
    Box::into_raw(Box::new(TimbrePlayerHandle {
        player,
        runtime,
        ctx,
        playback_session: Arc::new(std::sync::Mutex::new(None)),
        playback_gen: Arc::new(AtomicU64::new(0)),
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_free(handle: *mut TimbrePlayerHandle) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_play_file(
    handle: *mut TimbrePlayerHandle,
    path: *const c_char,
) -> bool {
    let Some(h) = handle.as_ref() else {
        return false;
    };
    let Some(path) = from_c(path) else {
        return false;
    };
    h.player.play_file(&path).is_ok()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_play_url(
    handle: *mut TimbrePlayerHandle,
    url: *const c_char,
    duration_secs: u64,
    cb: Option<TimbreDoneCallback>,
    ud: *mut c_void,
) -> bool {
    let Some(h) = handle.as_ref() else {
        return false;
    };
    let Some(url) = from_c(url) else { return false };

    let player = h.player.clone();
    let duration = (duration_secs > 0).then(|| Duration::from_secs(duration_secs));
    let user = SendPtr::new(ud);

    h.runtime.spawn(async move {
        let my_gen = player.begin_play();
        let result = player
            .play_url(my_gen, None, &url, duration, None, None)
            .await
            .map_err(|e| e.to_string());
        dispatch_done(cb, user.raw(), result);
    });
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_play_track_id(
    handle: *mut TimbrePlayerHandle,
    track_id: *const c_char,
    duration_secs: u64,
    cb: Option<TimbreDoneCallback>,
    ud: *mut c_void,
) -> bool {
    let Some(h) = handle.as_ref() else {
        return false;
    };
    let Some(id) = from_c(track_id) else {
        return false;
    };
    if id.is_empty() {
        return false;
    }

    let player = h.player.clone();
    let resolver = h.ctx.resolver.clone();
    let auth = h.ctx.session.media_auth();
    let duration = (duration_secs > 0).then(|| Duration::from_secs(duration_secs));
    let user = SendPtr::new(ud);

    h.runtime.spawn(async move {
        let my_gen = player.begin_play();
        let video = VideoId(id.clone());

        tracing::debug!(%video, gen = my_gen, ?duration, "play_track_id: started");

        match player.try_play_cached(my_gen, &video, duration).await {
            Ok(Some(())) => {
                tracing::debug!(%video, gen = my_gen, "play_track_id: finished (cache)");
                dispatch_done(cb, user.raw(), Ok(()));
                return;
            }
            Ok(None) => {
            }
            Err(e) => {
                tracing::warn!(%video, %e, "cache fast path failed, falling back to resolve");
            }
        }

        let outcome = play_once(&player, &resolver, auth.clone(), &video, duration, my_gen).await;
        let outcome = match outcome {
            Ok(()) => Ok(()),
            Err(e) if e.contains("superseded") => Err(e),
            Err(e) => {
                if player.generation() != my_gen {
                    tracing::debug!(%video, gen = my_gen, "play_track_id: bailing before retry");
                    dispatch_done(cb, user.raw(), Err("superseded by a newer play request".into()));
                    return;
                }
                tracing::warn!(error = %e, gen = my_gen, "play failed, retrying with a fresh resolve");
                resolver.invalidate(&video).await;
                play_once(&player, &resolver, auth, &video, duration, my_gen).await
            }
        };

        tracing::debug!(
            %video,
            gen = my_gen,
            ok = outcome.is_ok(),
            "play_track_id: finished"
        );

        dispatch_done(cb, user.raw(), outcome);
    });
    true
}

async fn play_once(
    player: &Arc<AudioPlayer>,
    resolver: &Arc<dyn StreamResolver>,
    auth: Option<HttpAuth>,
    video: &VideoId,
    duration: Option<Duration>,
    my_gen: u64,
) -> Result<(), String> {
    let work = async {
        let info = resolver
            .resolve(video.clone(), auth)
            .await
            .map_err(|e| e.to_string())?;

        tracing::debug!(
            %video,
            gen = my_gen,
            uri_prefix = &info.uri[..info.uri.len().min(60)],
            itag = ?info.format_id,
            bitrate = ?info.bitrate,
            ua = ?info.user_agent.as_deref().map(|s| &s[..s.len().min(30)]),
            "play_once: resolve returned"
        );

        if player.generation() != my_gen {
            return Err("superseded by a newer play request".to_string());
        }

        player
            .play_url(
                my_gen,
                Some(video),
                &info.uri,
                duration,
                info.user_agent.as_deref(),
                Some(&info),
            )
            .await
            .map_err(|e| e.to_string())
    };
    tokio::time::timeout(std::time::Duration::from_secs(25), work)
        .await
        .map_err(|_| "play timed out after 25s".to_string())?
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
        let player = h.player.clone();
        h.runtime.spawn(async move {
            player.resume_async().await;
        });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_stop(handle: *mut TimbrePlayerHandle) {
    if let Some(h) = handle.as_ref() {
        h.player.stop();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_reset(handle: *mut TimbrePlayerHandle) {
    if let Some(h) = handle.as_ref() {
        h.player.reset();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_seek(
    handle: *mut TimbrePlayerHandle,
    target_secs: f64,
) -> bool {
    if target_secs < 0.0 {
        return false;
    }
    let Some(h) = handle.as_ref() else {
        return false;
    };
    let player = h.player.clone();
    h.runtime.spawn(async move {
        if let Err(e) = player.seek(Duration::from_secs_f64(target_secs)).await {
            tracing::warn!(error = %e, target_secs, "seek failed");
        }
    });
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_get_position(handle: *mut TimbrePlayerHandle) -> f64 {
    handle
        .as_ref()
        .map(|h| h.player.get_position().as_secs_f64())
        .unwrap_or(0.0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_get_duration(handle: *mut TimbrePlayerHandle) -> f64 {
    handle
        .as_ref()
        .and_then(|h| h.player.get_duration())
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_is_finished(handle: *mut TimbrePlayerHandle) -> bool {
    handle
        .as_ref()
        .map(|h| h.player.is_finished())
        .unwrap_or(false)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_is_paused(handle: *mut TimbrePlayerHandle) -> bool {
    handle
        .as_ref()
        .map(|h| h.player.is_paused())
        .unwrap_or(false)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_set_volume(handle: *mut TimbrePlayerHandle, v: f32) {
    if let Some(h) = handle.as_ref() {
        h.player.set_volume(v);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_get_volume(handle: *mut TimbrePlayerHandle) -> f32 {
    handle.as_ref().map(|h| h.player.volume()).unwrap_or(1.0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_get_state(handle: *mut TimbrePlayerHandle) -> c_int {
    let Some(h) = handle.as_ref() else { return 0 };
    match h.player.state() {
        PlayerState::Stopped => 0,
        PlayerState::Playing => 1,
        PlayerState::Paused => 2,
        PlayerState::Buffering => 3,
        PlayerState::Loading => 4,
        PlayerState::Error => 5,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_take_last_error(
    handle: *mut TimbrePlayerHandle,
) -> *mut c_char {
    let Some(h) = handle.as_ref() else {
        return std::ptr::null_mut();
    };
    match h.player.take_error() {
        Some(msg) => to_c(msg),
        None => std::ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_get_stats(handle: *mut TimbrePlayerHandle) -> *mut c_char {
    let Some(h) = handle.as_ref() else {
        return std::ptr::null_mut();
    };
    to_c(serde_json::to_string(&h.player.stats()).unwrap_or_else(|_| "{}".into()))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_audio_stats(handle: *mut TimbrePlayerHandle) -> *mut c_char {
    let Some(h) = handle.as_ref() else {
        return std::ptr::null_mut();
    };
    let store = h.player.store().clone();
    let result = h.runtime.block_on(async move {
        let (cache_bytes, cache_count) = store.size(StoreKind::Cache).await;
        let (dl_bytes, dl_count) = store.size(StoreKind::Download).await;
        serde_json::json!({
            "cache_bytes": cache_bytes,
            "cache_count": cache_count,
            "cache_limit_bytes": store.cache_limit(),
            "downloads_bytes": dl_bytes,
            "downloads_count": dl_count,
        })
    });
    to_c(result.to_string())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_audio_list(
    handle: *mut TimbrePlayerHandle,
    kind: c_int,
) -> *mut c_char {
    let Some(h) = handle.as_ref() else {
        return std::ptr::null_mut();
    };
    let store = h.player.store().clone();
    let kind = StoreKind::from_int(kind);
    let entries = h.runtime.block_on(store.list(kind));
    to_c(serde_json::to_string(&entries).unwrap_or_else(|_| "[]".into()))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_audio_remove(
    handle: *mut TimbrePlayerHandle,
    video_id: *const c_char,
    cb: Option<TimbreDoneCallback>,
    ud: *mut c_void,
) -> bool {
    let Some(h) = handle.as_ref() else {
        return false;
    };
    let Some(video_id) = from_c(video_id) else {
        return false;
    };
    let store = h.player.store().clone();
    let user = SendPtr::new(ud);
    h.runtime.spawn(async move {
        store.remove(&video_id).await;
        dispatch_done(cb, user.raw(), Ok(()));
    });
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_audio_clear(
    handle: *mut TimbrePlayerHandle,
    kind: c_int,
    cb: Option<TimbreDoneCallback>,
    ud: *mut c_void,
) -> bool {
    let Some(h) = handle.as_ref() else {
        return false;
    };
    let store = h.player.store().clone();
    let kind = StoreKind::from_int(kind);
    let user = SendPtr::new(ud);
    h.runtime.spawn(async move {
        store.clear(kind).await;
        dispatch_done(cb, user.raw(), Ok(()));
    });
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_audio_set_cache_limit(handle: *mut TimbrePlayerHandle, bytes: u64) {
    let Some(h) = handle.as_ref() else { return };
    h.player.store().set_cache_limit(bytes);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_audio_download(
    handle: *mut TimbrePlayerHandle,
    track_id: *const c_char,
    cb: Option<TimbreDoneCallback>,
    ud: *mut c_void,
) -> bool {
    let Some(h) = handle.as_ref() else {
        return false;
    };
    let Some(id) = from_c(track_id) else {
        return false;
    };
    if id.is_empty() {
        return false;
    }

    let player = h.player.clone();
    let resolver = h.ctx.resolver.clone();
    let auth = h.ctx.session.media_auth();
    let user = SendPtr::new(ud);

    h.runtime.spawn(async move {
        let video = VideoId(id.clone());
        let info = match resolver.resolve(video.clone(), auth).await {
            Ok(i) => i,
            Err(e) => {
                dispatch_done(cb, user.raw(), Err(e.to_string()));
                return;
            }
        };

        let result = download_to_store(&player, &info, &video).await;
        dispatch_done(cb, user.raw(), result.map(|_| ()));
    });
    true
}

async fn download_to_store(
    player: &Arc<AudioPlayer>,
    info: &StreamInfo,
    video: &VideoId,
) -> Result<AudioEntry, String> {
    use futures_util::StreamExt;

    let store = player.store().clone();
    if let Some(entry) = store.lookup_in(StoreKind::Download, video.as_str()).await {
        if entry.complete {
            return Ok(entry);
        }
    }

    let meta = AudioEntry {
        video_id: video.0.clone(),
        title: info.title.clone(),
        artist: info.uploader.clone(),
        thumb: info.thumbnail.clone(),
        ext: info.ext.clone(),
        mime: info.acodec.clone(),
        expected_size: None,
        user_agent: info.user_agent.clone(),
        uri: Some(info.uri.clone()),
        ..Default::default()
    };
    let mut writer = store
        .open_writer(StoreKind::Download, video.as_str(), meta)
        .await
        .map_err(|e| e.to_string())?;

    let ua = info.user_agent.as_deref().unwrap_or("Mozilla/5.0");
    let client = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(10))
        .read_timeout(std::time::Duration::from_secs(15))
        .build()
        .map_err(|e| e.to_string())?;
    let response = client
        .get(&info.uri)
        .header("User-Agent", ua)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("HTTP {}", response.status()));
    }
    writer.set_expected_size(response.content_length());

    let saved_offset = writer.downloaded_bytes();
    let mut stream = response.bytes_stream();
    let mut stream_pos = 0u64;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| e.to_string())?;
        let chunk_start = stream_pos;
        let chunk_end = stream_pos + chunk.len() as u64;
        if chunk_end > saved_offset {
            let skip = saved_offset.saturating_sub(chunk_start) as usize;
            writer
                .write(&chunk[skip..])
                .await
                .map_err(|e| e.to_string())?;
        }
        stream_pos = chunk_end;
    }

    writer.finish(true).await.map_err(|e| e.to_string())
}

macro_rules! endpoint_json {
    ($name:ident, |$ctx:ident| $body:block) => {
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn $name(
            handle: *mut TimbrePlayerHandle,
            cb: Option<TimbreCallback>,
            ud: *mut c_void,
        ) -> bool {
            let Some(h) = handle.as_ref() else { return false };
            let $ctx = h.ctx.clone();
            let user = SendPtr::new(ud);
            h.runtime.spawn(async move {
                let result = async $body.await;
                dispatch_json(cb, user.raw(), result.map_err(|e| e.to_string()));
            });
            true
        }
    };
}

macro_rules! endpoint_json_str {
    ($name:ident, |$ctx:ident, $arg:ident| $body:block) => {
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn $name(
            handle: *mut TimbrePlayerHandle,
            $arg: *const c_char,
            cb: Option<TimbreCallback>,
            ud: *mut c_void,
        ) -> bool {
            let Some(h) = handle.as_ref() else { return false };
            let Some($arg) = from_c($arg) else { return false };
            let $ctx = h.ctx.clone();
            let user = SendPtr::new(ud);
            h.runtime.spawn(async move {
                let result = async $body.await;
                dispatch_json(cb, user.raw(), result.map_err(|e| e.to_string()));
            });
            true
        }
    };
}

macro_rules! endpoint_json_str2 {
    ($name:ident, |$ctx:ident, $a:ident, $b:ident| $body:block) => {
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn $name(
            handle: *mut TimbrePlayerHandle,
            $a: *const c_char,
            $b: *const c_char,
            cb: Option<TimbreCallback>,
            ud: *mut c_void,
        ) -> bool {
            let Some(h) = handle.as_ref() else { return false };
            let (Some($a), Some($b)) = (from_c($a), from_c($b)) else { return false };
            let $ctx = h.ctx.clone();
            let user = SendPtr::new(ud);
            h.runtime.spawn(async move {
                let result = async $body.await;
                dispatch_json(cb, user.raw(), result.map_err(|e| e.to_string()));
            });
            true
        }
    };
}

macro_rules! endpoint_done_str {
    ($name:ident, |$ctx:ident, $arg:ident| $body:block) => {
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn $name(
            handle: *mut TimbrePlayerHandle,
            $arg: *const c_char,
            cb: Option<TimbreDoneCallback>,
            ud: *mut c_void,
        ) -> bool {
            let Some(h) = handle.as_ref() else { return false };
            let Some($arg) = from_c($arg) else { return false };
            let $ctx = h.ctx.clone();
            let user = SendPtr::new(ud);
            h.runtime.spawn(async move {
                let result = async $body.await;
                dispatch_done(cb, user.raw(), result.map_err(|e| e.to_string()));
            });
            true
        }
    };
}

endpoint_json!(timbre_player_get_home, |ctx| {
    let api = ctx.session.api();
    home::get_home(api, 25).await
});

endpoint_json!(timbre_player_get_explore, |ctx| {
    let api = ctx.session.api();
    explore::load_explore(api, "ZZ".into()).await
});

endpoint_json_str!(timbre_player_get_charts, |ctx, country| {
    let api = ctx.session.api();
    explore::get_charts(&*api, &country).await
});

endpoint_json!(timbre_player_get_mood_categories, |ctx| {
    let api = ctx.session.api();
    explore::get_mood_categories(&*api).await
});

endpoint_json_str!(timbre_player_get_category_page, |ctx, params| {
    let api = ctx.session.api();
    explore::get_category_page(&*api, &params).await
});

endpoint_json_str!(timbre_player_get_album, |ctx, album_id| {
    let api = ctx.session.api();
    playlists::get_album(&*api, &album_id).await
});

endpoint_json_str!(timbre_player_get_playlist, |ctx, playlist_id| {
    let api = ctx.session.api();
    playlists::get_playlist(&*api, &playlist_id, None).await
});

endpoint_json_str!(timbre_player_get_artist, |ctx, channel_id| {
    let api = ctx.session.api();
    artist::get_artist(api, &channel_id).await
});

endpoint_json_str!(timbre_player_browse_section, |ctx, args_json| {
    let args: crate::net::playlists::SectionArgs = serde_json::from_str(&args_json)
        .map_err(|e| crate::net::NetError::Message(format!("invalid args: {e}")))?;
    let api = ctx.session.api();
    crate::net::playlists::browse_section_page(&*api, &args).await
});

endpoint_json_str!(timbre_player_get_radio, |ctx, id| {
    let api = ctx.session.api();
    if id.starts_with("RDAMPL") {
        playlists::radio_tracks(&*api, None, Some(&id)).await
    } else {
        playlists::radio_tracks(&*api, Some(&id), None).await
    }
});

endpoint_json_str2!(
    timbre_player_get_watch_playlist,
    |ctx, video_id, playlist_id| {
        let api = ctx.session.api();
        let vid = if video_id.is_empty() {
            None
        } else {
            Some(video_id.as_str())
        };
        let pid = if playlist_id.is_empty() {
            None
        } else {
            Some(playlist_id.as_str())
        };
        playlists::get_watch_playlist(&*api, vid, pid, 50, false).await
    }
);

endpoint_json!(timbre_player_get_library_playlists, |ctx| {
    let api = ctx.session.api();
    library::library_playlists(api).await
});

endpoint_json!(timbre_player_get_library_albums, |ctx| {
    let api = ctx.session.api();
    library::library_albums(api).await
});

endpoint_json!(timbre_player_get_library_subscriptions, |ctx| {
    let api = ctx.session.api();
    library::library_subscriptions(api).await
});

endpoint_json!(timbre_player_get_history, |ctx| {
    let api = ctx.session.api();
    history::get_history(api).await
});

endpoint_json_str!(timbre_player_search, |ctx, query| {
    let api = ctx.session.api();
    search::search_all(api, query).await
});

endpoint_json_str!(timbre_player_search_suggestions, |ctx, query| {
    let api = ctx.session.api();
    let results = search::search(&*api, &query, None).await?;
    let mut seen = std::collections::HashSet::new();
    let mut out: Vec<String> = Vec::new();
    if let Some(top) = results.top_result {
        if seen.insert(top.title.clone()) {
            out.push(top.title);
        }
    }
    for item in results.items {
        if out.len() >= 10 {
            break;
        }
        if seen.insert(item.title.clone()) {
            out.push(item.title);
        }
    }
    Ok::<_, crate::net::NetError>(out)
});

endpoint_json!(timbre_player_get_account, |ctx| {
    ctx.session.account_info().await
});

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_is_authenticated(handle: *mut TimbrePlayerHandle) -> bool {
    handle
        .as_ref()
        .map(|h| h.ctx.session.is_authenticated())
        .unwrap_or(false)
}

endpoint_done_str!(timbre_player_login, |ctx, input| {
    ctx.session.login(&input).await.map(|_| ())
});

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_logout(
    handle: *mut TimbrePlayerHandle,
    cb: Option<TimbreDoneCallback>,
    ud: *mut c_void,
) -> bool {
    let Some(h) = handle.as_ref() else {
        return false;
    };
    let ctx = h.ctx.clone();
    let user = SendPtr::new(ud);
    h.runtime.spawn(async move {
        ctx.session.logout().await;
        dispatch_done(cb, user.raw(), Ok(()));
    });
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_rate_track(
    handle: *mut TimbrePlayerHandle,
    track_id: *const c_char,
    rating: c_int, // -1 = dislike, 0 = indifferent, 1 = like
    cb: Option<TimbreDoneCallback>,
    ud: *mut c_void,
) -> bool {
    let Some(h) = handle.as_ref() else {
        return false;
    };
    let Some(track_id) = from_c(track_id) else {
        return false;
    };
    let ctx = h.ctx.clone();
    let user = SendPtr::new(ud);

    h.runtime.spawn(async move {
        let status = match rating {
            1 => LikeStatus::Like,
            -1 => LikeStatus::Dislike,
            _ => LikeStatus::Indifferent,
        };
        let result = ctx
            .session
            .rate_song(&track_id, status)
            .await
            .map_err(|e| e.to_string());
        dispatch_done(cb, user.raw(), result);
    });
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_subscribe_artist(
    handle: *mut TimbrePlayerHandle,
    channel_id: *const c_char,
    subscribe: bool,
    cb: Option<TimbreDoneCallback>,
    ud: *mut c_void,
) -> bool {
    let Some(h) = handle.as_ref() else {
        return false;
    };
    let Some(channel_id) = from_c(channel_id) else {
        return false;
    };
    let ctx = h.ctx.clone();
    let user = SendPtr::new(ud);

    h.runtime.spawn(async move {
        let api = ctx.session.api();
        let result = if subscribe {
            artist::subscribe(&*api, &channel_id).await
        } else {
            artist::unsubscribe(&*api, &channel_id).await
        }
        .map_err(|e| e.to_string());
        dispatch_done(cb, user.raw(), result);
    });
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_remove_history(
    handle: *mut TimbrePlayerHandle,
    tokens_json: *const c_char,
    cb: Option<TimbreDoneCallback>,
    ud: *mut c_void,
) -> bool {
    let Some(h) = handle.as_ref() else {
        return false;
    };
    let Some(tokens_json) = from_c(tokens_json) else {
        return false;
    };
    let ctx = h.ctx.clone();
    let user = SendPtr::new(ud);

    h.runtime.spawn(async move {
        let tokens: Vec<String> = match serde_json::from_str(&tokens_json) {
            Ok(t) => t,
            Err(e) => {
                dispatch_done(cb, user.raw(), Err(format!("invalid tokens: {e}")));
                return;
            }
        };
        let api = ctx.session.api();
        let result = history::remove_history_items(&*api, tokens)
            .await
            .map_err(|e| e.to_string());
        dispatch_done(cb, user.raw(), result);
    });
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_add_to_playlist(
    handle: *mut TimbrePlayerHandle,
    playlist_id: *const c_char,
    track_ids_json: *const c_char,
    cb: Option<TimbreDoneCallback>,
    ud: *mut c_void,
) -> bool {
    let Some(h) = handle.as_ref() else {
        return false;
    };
    let Some(playlist_id) = from_c(playlist_id) else {
        return false;
    };
    let Some(track_ids_json) = from_c(track_ids_json) else {
        return false;
    };
    let ctx = h.ctx.clone();
    let user = SendPtr::new(ud);

    h.runtime.spawn(async move {
        let ids: Vec<String> = match serde_json::from_str(&track_ids_json) {
            Ok(v) => v,
            Err(e) => {
                dispatch_done(cb, user.raw(), Err(format!("invalid ids: {e}")));
                return;
            }
        };
        let api = ctx.session.api();
        let result = playlists::add_playlist_items(&*api, &playlist_id, ids, None)
            .await
            .map_err(|e| e.to_string());
        dispatch_done(cb, user.raw(), result);
    });
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_create_playlist(
    handle: *mut TimbrePlayerHandle,
    title: *const c_char,
    description: *const c_char,
    privacy: *const c_char,
    cb: Option<TimbreCallback>,
    ud: *mut c_void,
) -> bool {
    let Some(h) = handle.as_ref() else {
        return false;
    };
    let (Some(title), Some(desc), Some(privacy)) =
        (from_c(title), from_c(description), from_c(privacy))
    else {
        return false;
    };
    let ctx = h.ctx.clone();
    let user = SendPtr::new(ud);

    h.runtime.spawn(async move {
        let api = ctx.session.api();
        let result = playlists::create_playlist(&*api, &title, &desc, &privacy)
            .await
            .map(|id| serde_json::json!({ "id": id }))
            .map_err(|e| e.to_string());
        dispatch_json(cb, user.raw(), result);
    });
    true
}

endpoint_done_str!(timbre_player_delete_playlist, |ctx, playlist_id| {
    let api = ctx.session.api();
    playlists::delete_playlist(&*api, &playlist_id).await
});

/// Empty strings in title/description/privacy mean "leave the field alone".
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_edit_playlist(
    handle: *mut TimbrePlayerHandle,
    playlist_id: *const c_char,
    title: *const c_char,
    description: *const c_char,
    privacy: *const c_char,
    cb: Option<TimbreDoneCallback>,
    ud: *mut c_void,
) -> bool {
    let Some(h) = handle.as_ref() else {
        return false;
    };
    let Some(playlist_id) = from_c(playlist_id) else {
        return false;
    };
    let title = from_c(title).unwrap_or_default();
    let description = from_c(description).unwrap_or_default();
    let privacy = from_c(privacy).unwrap_or_default();
    let ctx = h.ctx.clone();
    let user = SendPtr::new(ud);

    h.runtime.spawn(async move {
        let api = ctx.session.api();
        let result = playlists::edit_playlist(
            &*api,
            &playlist_id,
            none_if_empty(&title),
            none_if_empty(&description),
            none_if_empty(&privacy),
        )
        .await
        .map_err(|e| e.to_string());
        dispatch_done(cb, user.raw(), result);
    });
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_record_play_start(
    handle: *mut TimbrePlayerHandle,
    track_id: *const c_char,
    cb: Option<TimbreDoneCallback>,
    ud: *mut c_void,
) -> bool {
    let Some(h) = handle.as_ref() else {
        return false;
    };
    let Some(track_id) = from_c(track_id) else {
        return false;
    };
    if track_id.is_empty() {
        return false;
    }

    let ctx = h.ctx.clone();
    let slot = h.playback_session.clone();
    let gen_ctl = h.playback_gen.clone();
    let my_gen = gen_ctl.fetch_add(1, Ordering::SeqCst) + 1;
    let user = SendPtr::new(ud);

    // Short-circuit for anonymous users: there is no history to record
    // server-side, and the /player call inside `begin_play` would
    // otherwise request a PO token — spawning the BotGuard worker
    // (~40 MB baseline RAM) on every single track played, even though
    // the VISIONOS resolver already served the audio without any token.
    if !ctx.session.is_authenticated() {
        dispatch_done(cb, user.raw(), Ok(()));
        return true;
    }

    h.runtime.spawn(async move {
        let auth = ctx.session.media_auth();
        let sts = ctx.session.signature_timestamp().await;

        let outcome =
            history::begin_play(&ctx.http, auth.as_ref(), &track_id, &ctx.tokens, sts).await;

        if gen_ctl.load(Ordering::SeqCst) != my_gen {
            dispatch_done(cb, user.raw(), Err("superseded".into()));
            return;
        }

        match outcome {
            Ok(session) => {
                let old = slot.lock().unwrap().replace(session);
                if let Some(old) = old {
                    if old.video_id() != track_id.as_str() {
                        history::end_play(&ctx.http, auth.as_ref(), &old, old.reported_secs).await;
                    }
                }
                dispatch_done(cb, user.raw(), Ok(()));
            }
            Err(e) => dispatch_done(cb, user.raw(), Err(e.to_string())),
        }
    });
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_record_play_end(
    handle: *mut TimbrePlayerHandle,
    track_id: *const c_char,
) {
    let Some(h) = handle.as_ref() else { return };
    let expected = from_c(track_id);
    let ctx = h.ctx.clone();
    let slot = h.playback_session.clone();
    let gen_ctl = h.playback_gen.clone();
    gen_ctl.fetch_add(1, Ordering::SeqCst);

    let position = h.player.get_position().as_secs_f64();

    h.runtime.spawn(async move {
        let session = {
            let mut guard = slot.lock().unwrap();
            match (guard.as_ref(), expected.as_deref()) {
                (Some(s), Some(id)) if s.video_id() == id => guard.take(),
                _ => None,
            }
        };
        if let Some(s) = session {
            let auth = ctx.session.media_auth();
            history::end_play(&ctx.http, auth.as_ref(), &s, position).await;
        }
    });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_record_play_tick(
    handle: *mut TimbrePlayerHandle,
    track_id: *const c_char,
    position_secs: f64,
) {
    let Some(h) = handle.as_ref() else { return };
    let Some(track_id) = from_c(track_id) else {
        return;
    };
    if position_secs < 0.0 {
        return;
    }

    let ctx = h.ctx.clone();
    let slot = h.playback_session.clone();

    h.runtime.spawn(async move {
        let mut session = {
            let guard = slot.lock().unwrap();
            match guard.as_ref() {
                Some(s) if s.video_id() == track_id.as_str() => Some(s.clone()),
                _ => None,
            }
        };
        let Some(ref mut s) = session else { return };
        let auth = ctx.session.media_auth();
        history::tick_play(&ctx.http, auth.as_ref(), s, position_secs).await;

        let mut guard = slot.lock().unwrap();
        if let Some(ref mut existing) = *guard {
            if existing.cpn == s.cpn {
                existing.reported_secs = s.reported_secs;
                existing.atr_sent = s.atr_sent;
            }
        }
    });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_audio_release_sink(handle: *mut TimbrePlayerHandle) {
    if let Some(h) = handle.as_ref() {
        h.player.release_sink();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_audio_rebuild_sink(handle: *mut TimbrePlayerHandle) -> bool {
    handle
        .as_ref()
        .map(|h| h.player.rebuild_sink().is_ok())
        .unwrap_or(false)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn timbre_player_set_active(handle: *mut TimbrePlayerHandle, active: bool) {
    if let Some(h) = handle.as_ref() {
        h.player.set_active(active);
    }
}
