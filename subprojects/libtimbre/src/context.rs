use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use anyhow::{Context as _, Result};
use serde_json::Value;

use crate::net::cache::Caches;
use crate::net::player_endpoint::PlayerEndpointResolver;
use crate::net::potoken::PoTokens;
use crate::net::session::Session;
use crate::net::stream::{StreamResolver, YtDlpResolver};

#[derive(Clone, Debug)]
pub struct Locale {
    pub hl: String, // "pt-BR", "en", "ja"
    pub gl: String, // "BR", "US", "JP"
}

impl Default for Locale {
    fn default() -> Self {
        Self {
            hl: "en".into(),
            gl: "US".into(),
        }
    }
}

static LOCALE: OnceLock<Locale> = OnceLock::new();

pub fn set_locale(hl: String, gl: String) {
    let _ = LOCALE.set(Locale { hl, gl });
}

pub fn locale() -> Locale {
    LOCALE.get().cloned().unwrap_or_default()
}

#[derive(Clone)]
pub struct Paths {
    pub data_dir: PathBuf,
    pub cache_dir: PathBuf,
    pub auth_file: PathBuf,
    pub stream_cache_dir: PathBuf,
    pub prefs_file: PathBuf,
}

impl Paths {
    pub fn discover() -> Result<Self> {
        let base = std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
            .context("no XDG_DATA_HOME or HOME")?;
        let data_dir = base.join("timbre");

        let cache_base = std::env::var_os("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))
            .unwrap_or_else(|| data_dir.clone());
        let cache_dir = cache_base.join("timbre");

        std::fs::create_dir_all(&data_dir).ok();
        std::fs::create_dir_all(&cache_dir).ok();

        Ok(Self {
            auth_file: data_dir.join("headers_auth.json"),
            stream_cache_dir: cache_dir.join("streams"),
            prefs_file: data_dir.join("prefs.json"),
            data_dir,
            cache_dir,
        })
    }

    pub fn read_prefs(&self) -> Value {
        std::fs::read_to_string(&self.prefs_file)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_else(|| Value::Object(Default::default()))
    }

    pub fn write_prefs(&self, value: &Value) -> Result<()> {
        let bytes = serde_json::to_vec_pretty(value)?;
        std::fs::write(&self.prefs_file, bytes)?;
        Ok(())
    }
}

pub struct TimbreContext {
    pub paths: Paths,
    pub http: reqwest::Client,
    pub session: Arc<Session>,
    pub resolver: Arc<dyn StreamResolver>,
    pub tokens: Arc<PoTokens>,
    pub caches: Arc<Caches>,
}

impl TimbreContext {
    pub fn new(runtime: &tokio::runtime::Runtime) -> Result<Arc<Self>> {
        let paths = Paths::discover()?;
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .gzip(true)
            .build()?;
        let session = Session::new(&paths)?;
        let tokens = Arc::new(PoTokens::new());
        let ytdlp: Arc<dyn StreamResolver> = Arc::new(YtDlpResolver::new(&paths, tokens.clone()));
        let native = Arc::new(PlayerEndpointResolver::new(&paths, ytdlp));
        let resolver: Arc<dyn StreamResolver> = native.clone();

        // Warm the visitor before the first VISIONOS call, otherwise it
        // answers "Sign in to confirm you're not a bot".
        let warm = native.clone();
        runtime.spawn(async move { warm.warm().await });

        Ok(Arc::new(Self {
            caches: Arc::new(Caches::new(&paths)),
            session,
            resolver,
            tokens,
            http,
            paths,
        }))
    }
}
