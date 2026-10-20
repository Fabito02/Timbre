use std::collections::HashMap;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use tokio::process::Command;

use crate::context::Paths;
use crate::net::media::{HttpAuth, StreamInfo, VideoId};

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

#[derive(Debug, thiserror::Error)]
pub enum ResolveError {
    #[error("{0}")]
    Unavailable(String),
    #[error("resolver failed: {0}")]
    Tool(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

pub trait StreamResolver: Send + Sync {
    fn resolve(
        &self,
        video_id: VideoId,
        auth: Option<HttpAuth>,
    ) -> BoxFuture<'_, Result<StreamInfo, ResolveError>>;
    fn invalidate(&self, video_id: &VideoId) -> BoxFuture<'_, ()>;
}

const YTDLP_FORMAT: &str =
    "bestaudio[acodec=opus]/bestaudio[protocol=https]/bestaudio[protocol=http]/bestaudio/best";
const YTDLP_FORMAT_SORT: &str = "proto:https,acodec:opus";
const YTDLP_PLAYER_CLIENTS: &str =
    "youtube:player_client=web_music,mweb,tv,web_safari,android_vr,android,ios";

pub struct YtDlpResolver {
    binary: PathBuf,
    tokens: Arc<crate::net::potoken::PoTokens>,
    tmp_dir: PathBuf,
}

impl YtDlpResolver {
    pub fn new(paths: &Paths, tokens: Arc<crate::net::potoken::PoTokens>) -> Self {
        let binary = find_executable("yt-dlp").unwrap_or_else(|| PathBuf::from("yt-dlp"));
        Self {
            binary,
            tokens,
            tmp_dir: paths.cache_dir.clone(),
        }
    }

    async fn run(
        &self,
        video_id: &VideoId,
        auth: Option<&HttpAuth>,
    ) -> Result<StreamInfo, ResolveError> {
        let url = format!("https://music.youtube.com/watch?v={video_id}");
        let mut cmd = Command::new(&self.binary);
        cmd.args([
            "-j",
            "--no-playlist",
            "--no-warnings",
            "-f",
            YTDLP_FORMAT,
            "-S",
            YTDLP_FORMAT_SORT,
        ])
        .args(["--extractor-args", YTDLP_PLAYER_CLIENTS])
        .args(["--js-runtimes", "node"]);
        if let Some(token) = self.tokens.for_video(video_id.as_str()).await {
            cmd.arg("--extractor-args")
                .arg(crate::net::potoken::extractor_arg(&token));
        }
        let cookie_file = match auth {
            Some(auth) => {
                let path = write_netscape_cookies(&self.tmp_dir, &auth.cookie).await?;
                cmd.arg("--cookies")
                    .arg(&path)
                    .arg("--user-agent")
                    .arg(&auth.user_agent);
                if let Some(a) = &auth.authorization {
                    cmd.arg("--add-headers").arg(format!("Authorization:{a}"));
                }
                Some(path)
            }
            None => None,
        };
        cmd.arg(&url)
            .kill_on_drop(true)
            .stdin(std::process::Stdio::null());

        let output = cmd.output().await;
        if let Some(path) = cookie_file {
            let _ = tokio::fs::remove_file(path).await;
        }
        let output = output?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let line = stderr
                .lines()
                .rev()
                .find(|l| l.contains("ERROR"))
                .unwrap_or("yt-dlp failed")
                .trim();
            return Err(ResolveError::Unavailable(line.to_owned()));
        }

        #[derive(Deserialize)]
        struct Info {
            url: String,
            format_id: Option<String>,
            protocol: Option<String>,
            ext: Option<String>,
            acodec: Option<String>,
            title: Option<String>,
            uploader: Option<String>,
            thumbnail: Option<String>,
            abr: Option<f64>,
        }
        let info: Info = serde_json::from_slice(&output.stdout)?;
        Ok(StreamInfo {
            uri: info.url,
            format_id: info.format_id,
            protocol: info.protocol,
            ext: info.ext,
            acodec: info.acodec,
            title: info.title,
            uploader: info.uploader,
            thumbnail: info.thumbnail,
            is_local: false,
            from_cache: false,
            user_agent: None,
            bitrate: info.abr.map(|b| b as u64),
            sample_rate: None,
            channels: None,
        })
    }
}

impl StreamResolver for YtDlpResolver {
    fn resolve(
        &self,
        video_id: VideoId,
        auth: Option<HttpAuth>,
    ) -> BoxFuture<'_, Result<StreamInfo, ResolveError>> {
        Box::pin(async move { self.run(&video_id, auth.as_ref()).await })
    }

    fn invalidate(&self, _video_id: &VideoId) -> BoxFuture<'_, ()> {
        Box::pin(async move {})
    }
}

pub struct DemoResolver {
    inner: Arc<dyn StreamResolver>,
    uris: HashMap<String, String>,
}

impl DemoResolver {
    pub fn new(inner: Arc<dyn StreamResolver>, uris: HashMap<String, String>) -> Self {
        Self { inner, uris }
    }
}

impl StreamResolver for DemoResolver {
    fn resolve(
        &self,
        video_id: VideoId,
        auth: Option<HttpAuth>,
    ) -> BoxFuture<'_, Result<StreamInfo, ResolveError>> {
        if let Some(uri) = self.uris.get(video_id.as_str()).cloned() {
            let is_local = uri.starts_with("file://");
            return Box::pin(async move {
                Ok(StreamInfo {
                    uri,
                    is_local,
                    ..StreamInfo::default()
                })
            });
        }
        self.inner.resolve(video_id, auth)
    }

    fn invalidate(&self, video_id: &VideoId) -> BoxFuture<'_, ()> {
        self.inner.invalidate(video_id)
    }
}

fn now_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

pub async fn write_netscape_cookies(dir: &Path, cookie_header: &str) -> std::io::Result<PathBuf> {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let path = dir.join(format!("ytdlp-cookies-{}-{nanos}.txt", std::process::id()));
    let expiry = now_secs() as u64 + 365 * 24 * 3600;
    let mut body = String::from("# Netscape HTTP Cookie File\n");
    for part in cookie_header.split(';') {
        if let Some((k, v)) = part.trim().split_once('=') {
            body.push_str(&format!(
                ".youtube.com\tTRUE\t/\tTRUE\t{expiry}\t{k}\t{v}\n"
            ));
        }
    }
    let write_path = path.clone();
    tokio::task::spawn_blocking(move || {
        use std::io::Write;
        let mut opts = std::fs::OpenOptions::new();
        opts.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        opts.open(&write_path)?.write_all(body.as_bytes())
    })
    .await
    .map_err(|e| std::io::Error::other(e.to_string()))??;
    Ok(path)
}

pub fn find_executable(name: &str) -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).map(|d| d.join(name)).collect())
        .unwrap_or_default();
    if let Some(home) = std::env::var_os("HOME") {
        candidates.push(PathBuf::from(home).join(".cargo/bin").join(name));
    }
    candidates.push(PathBuf::from("/usr/lib/timbre/bin").join(name));
    candidates.push(PathBuf::from("/usr/local/bin").join(name));
    candidates.push(PathBuf::from("/usr/bin").join(name));
    candidates.into_iter().find(|p| p.is_file())
}
