use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime};

use tokio::sync::{mpsc, oneshot};

const WORKER_QUEUE: usize = 16;

struct Token {
    value: String,
    expires: SystemTime,
}

// The inner `Botguard` runs on its own thread, away from tokio. Requests go
// through mpsc and responses come back on a oneshot; the type never crosses
// an await point.
enum Request {
    Mint {
        identifier: String,
        reply: oneshot::Sender<Result<String, String>>,
    },
}

pub struct PoTokens {
    worker: OnceLock<mpsc::Sender<Request>>,
    minted: Mutex<HashMap<String, Token>>,
}

impl PoTokens {
    pub fn new() -> Self {
        Self {
            worker: OnceLock::new(),
            minted: Mutex::new(HashMap::new()),
        }
    }

    fn worker(&self) -> Option<&mpsc::Sender<Request>> {
        if let Some(tx) = self.worker.get() {
            return Some(tx);
        }
        let (tx, mut rx) = mpsc::channel::<Request>(WORKER_QUEUE);
        let _ = std::thread::Builder::new()
            .name("rustypipe-botguard".into())
            .spawn(move || {
                let rt = match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(rt) => rt,
                    Err(e) => {
                        tracing::warn!(%e, "botguard worker: runtime not built");
                        return;
                    }
                };
                let mut bg = match rt.block_on(rustypipe_botguard::Botguard::builder().init()) {
                    Ok(bg) => {
                        tracing::info!("BotGuard initialized");
                        bg
                    }
                    Err(e) => {
                        tracing::warn!(%e, "botguard worker: init failed");
                        return;
                    }
                };
                while let Some(Request::Mint { identifier, reply }) = rx.blocking_recv() {
                    let result = rt
                        .block_on(bg.mint_token(&identifier))
                        .map_err(|e| e.to_string());
                    let _ = reply.send(result);
                }
            });
        if self.worker.set(tx).is_err() {
            tracing::warn!("botguard worker: already started");
        }
        self.worker.get()
    }

    pub async fn for_video(&self, video_id: &str) -> Option<String> {
        self.cleanup_expired();
        if let Some(token) = self.cached(video_id) {
            return Some(token);
        }
        let tx = self.worker()?.clone();

        let (reply_tx, reply_rx) = oneshot::channel();
        if tx
            .send(Request::Mint {
                identifier: video_id.to_owned(),
                reply: reply_tx,
            })
            .await
            .is_err()
        {
            return None;
        }
        let value = match reply_rx.await {
            Ok(Ok(v)) => v,
            Ok(Err(e)) => {
                tracing::warn!(%e, video_id, "mint_token failed");
                return None;
            }
            Err(_) => return None,
        };

        self.minted.lock().unwrap().insert(
            video_id.to_owned(),
            Token {
                value: value.clone(),
                expires: SystemTime::now() + Duration::from_secs(6 * 3600),
            },
        );
        Some(value)
    }

    fn cleanup_expired(&self) {
        let now = SystemTime::now();
        let mut minted = self.minted.lock().unwrap();
        minted.retain(|_, token| token.expires > now);
    }

    fn cached(&self, video_id: &str) -> Option<String> {
        let mut minted = self.minted.lock().unwrap();
        match minted.get(video_id) {
            Some(token) if token.expires > SystemTime::now() => Some(token.value.clone()),
            Some(_) => {
                minted.remove(video_id);
                None
            }
            None => None,
        }
    }
}

pub fn extractor_arg(token: &str) -> String {
    format!("youtube:po_token=web_music.gvs+{token}")
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_argument_names_the_client_the_token_is_for() {
        assert_eq!(
            super::extractor_arg("abc"),
            "youtube:po_token=web_music.gvs+abc"
        );
    }
}
