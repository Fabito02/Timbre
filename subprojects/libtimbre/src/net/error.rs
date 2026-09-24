#[derive(Debug, thiserror::Error)]
pub enum NetError {
    #[error("network: {0}")]
    Transport(#[from] reqwest::Error),
    #[error("{0}")]
    Api(#[from] ytmusicapi::Error),
    #[error("HTTP {status}: {message}")]
    Http { status: u16, message: String },
    #[error("not signed in")]
    Unauthenticated,
    #[error("invalid auth input: {0}")]
    InvalidAuth(String),
    #[error("{0}")]
    Message(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

impl NetError {
    pub fn status(&self) -> Option<u16> {
        match self {
            NetError::Api(ytmusicapi::Error::Server { status, .. }) => Some(*status),
            NetError::Http { status, .. } => Some(*status),
            _ => None,
        }
    }
}
