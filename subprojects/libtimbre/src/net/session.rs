use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::{Arc, RwLock};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::watch;
use ytmusicapi::{BrowserAuth, YTMusicClient};

use super::error::NetError;
use super::media::{HttpAuth, LikeStatus};
use crate::context::Paths;

const LOGIN_USER_AGENT: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36";

pub const CHANNEL_PREF: &str = "account_page_id";

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountInfo {
    pub name: String,
    pub handle: Option<String>,
    pub photo_url: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Account {
    pub name: String,
    pub byline: Option<String>,
    pub handle: Option<String>,
    pub photo_url: Option<String>,
    pub page_id: Option<String>,
    pub selected: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AuthState {
    Anonymous,
    Unverified,
    Authenticated(AccountInfo),
    Invalid(String),
}

impl AuthState {
    pub fn is_authenticated(&self) -> bool {
        matches!(self, AuthState::Authenticated(_))
    }

    pub fn has_session(&self) -> bool {
        matches!(self, AuthState::Authenticated(_) | AuthState::Unverified)
    }
}

#[derive(Default)]
struct Credentials {
    headers: BTreeMap<String, String>,
    browser_auth: Option<BrowserAuth>,
}

pub struct Session {
    http: reqwest::Client,
    auth_file: PathBuf,
    api: RwLock<Arc<YTMusicClient>>,
    credentials: RwLock<Credentials>,
    auth: watch::Sender<AuthState>,
    known_likes: RwLock<HashMap<String, LikeStatus>>,
    page_id: RwLock<Option<String>>,
}

impl Session {
    pub fn new(paths: &Paths) -> anyhow::Result<Arc<Self>> {
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .gzip(true)
            .build()?;
        let (auth, _) = watch::channel(AuthState::Anonymous);
        let anonymous = YTMusicClient::builder().build()?;
        let page_id = paths
            .read_prefs()
            .get(CHANNEL_PREF)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_owned);
        let session = Arc::new(Self {
            http,
            auth_file: paths.auth_file.clone(),
            api: RwLock::new(Arc::new(anonymous)),
            credentials: RwLock::new(Credentials::default()),
            auth,
            known_likes: RwLock::new(HashMap::new()),
            page_id: RwLock::new(page_id),
        });
        session.load_saved_session();
        Ok(session)
    }

    pub fn http(&self) -> &reqwest::Client {
        &self.http
    }

    pub fn api(&self) -> Arc<YTMusicClient> {
        self.api.read().unwrap().clone()
    }

    pub fn auth_state(&self) -> AuthState {
        self.auth.borrow().clone()
    }

    pub fn subscribe_auth(&self) -> watch::Receiver<AuthState> {
        self.auth.subscribe()
    }

    pub fn is_authenticated(&self) -> bool {
        self.auth.borrow().is_authenticated()
    }

    fn publish(&self, state: AuthState) {
        self.auth.send_replace(state);
    }

    pub fn media_auth(&self) -> Option<HttpAuth> {
        if !self.auth.borrow().has_session() {
            return None;
        }
        let credentials = self.credentials.read().unwrap();
        let cookie = credentials.headers.get("Cookie")?.clone();
        let user_agent = credentials
            .headers
            .get("User-Agent")
            .cloned()
            .unwrap_or_else(|| LOGIN_USER_AGENT.to_owned());
        let authorization = credentials
            .browser_auth
            .as_ref()
            .and_then(|a| a.get_authorization().ok());
        Some(HttpAuth { cookie, user_agent, authorization })
    }

    pub fn browser_headers(&self) -> Option<BTreeMap<String, String>> {
        if !self.auth.borrow().has_session() {
            return None;
        }
        let credentials = self.credentials.read().unwrap();
        if credentials.headers.is_empty() {
            return None;
        }
        let mut headers = credentials.headers.clone();
        if let Some(auth) = credentials
            .browser_auth
            .as_ref()
            .and_then(|a| a.get_authorization().ok())
        {
            headers.insert("Authorization".to_owned(), auth);
        }
        Some(headers)
    }

    fn load_saved_session(&self) {
        let Ok(text) = std::fs::read_to_string(&self.auth_file) else {
            self.publish(AuthState::Anonymous);
            return;
        };
        match serde_json::from_str::<BTreeMap<String, String>>(&text) {
            Ok(raw) => match self.install_headers(normalize_headers(raw)) {
                Ok(()) => {
                    tracing::info!(
                        path = %self.auth_file.display(),
                        "saved session loaded, validation deferred"
                    );
                    self.publish(AuthState::Unverified);
                }
                Err(err) => {
                    tracing::warn!(%err, "saved session unusable");
                    self.publish(AuthState::Anonymous);
                }
            },
            Err(err) => {
                tracing::warn!(%err, "headers_auth.json unreadable");
                self.publish(AuthState::Anonymous);
            }
        }
    }

    fn install_headers(&self, headers: BTreeMap<String, String>) -> Result<(), NetError> {
        let browser_auth = BrowserAuth::from_json(&serde_json::to_string(&headers)?)
            .map_err(|e| NetError::InvalidAuth(e.to_string()))?;
        browser_auth
            .sapisid()
            .map_err(|e| NetError::InvalidAuth(e.to_string()))?;
        let mut builder = YTMusicClient::builder().with_browser_auth(browser_auth.clone());
        if let Some(page_id) = self.page_id.read().unwrap().clone() {
            builder = builder.with_user(page_id);
        }
        *self.api.write().unwrap() = Arc::new(builder.build()?);
        let mut credentials = self.credentials.write().unwrap();
        credentials.headers = headers;
        credentials.browser_auth = Some(browser_auth);
        Ok(())
    }

    pub async fn validate(&self) -> Result<AuthState, NetError> {
        if !self.auth.borrow().has_session() {
            return Ok(self.auth_state());
        }
        match self.account_info().await {
            Ok(Some(info)) => {
                tracing::info!(name = %info.name, "session validated");
                self.publish(AuthState::Authenticated(info));
            }
            Ok(None) => {
                tracing::warn!("session rejected: no active account in the menu");
                self.publish(AuthState::Invalid("session expired".into()));
            }
            Err(err) if matches!(err.status(), Some(401) | Some(403)) => {
                self.publish(AuthState::Invalid(err.to_string()));
            }
            Err(err) => {
                tracing::warn!(%err, "validation skipped, keeping cached session");
                return Err(err);
            }
        }
        Ok(self.auth_state())
    }

    pub async fn login(&self, input: &str) -> Result<AccountInfo, NetError> {
        let raw = parse_auth_input(input)?;
        let mut headers = normalize_headers(raw);
        headers
            .entry("User-Agent".into())
            .or_insert_with(|| LOGIN_USER_AGENT.to_owned());
        headers.insert("Accept-Language".into(), "en-US,en;q=0.9".into());
        headers
            .entry("Content-Type".into())
            .or_insert_with(|| "application/json; charset=UTF-8".into());

        self.install_headers(headers.clone())?;
        self.publish(AuthState::Unverified);
        match self.account_info().await? {
            Some(info) => {
                if let Some(parent) = self.auth_file.parent() {
                    tokio::fs::create_dir_all(parent).await?;
                }
                tokio::fs::write(&self.auth_file, serde_json::to_vec(&headers)?).await?;
                self.publish(AuthState::Authenticated(info.clone()));
                Ok(info)
            }
            None => {
                self.clear_session();
                Err(NetError::InvalidAuth("server rejected these headers".into()))
            }
        }
    }

    pub async fn logout(&self) {
        let _ = tokio::fs::remove_file(&self.auth_file).await;
        self.clear_session();
    }

    fn clear_session(&self) {
        if let Ok(anonymous) = YTMusicClient::builder().build() {
            *self.api.write().unwrap() = Arc::new(anonymous);
        }
        *self.credentials.write().unwrap() = Credentials::default();
        self.known_likes.write().unwrap().clear();
        self.publish(AuthState::Anonymous);
    }

    pub fn channel(&self) -> Option<String> {
        self.page_id.read().unwrap().clone()
    }

    pub async fn set_channel(&self, page_id: Option<String>) -> Result<AuthState, NetError> {
        *self.page_id.write().unwrap() = page_id;
        let headers = self.credentials.read().unwrap().headers.clone();
        if headers.is_empty() {
            return Ok(self.auth_state());
        }
        self.install_headers(headers)?;
        self.known_likes.write().unwrap().clear();
        self.validate().await
    }

    pub async fn accounts(&self) -> Result<Vec<Account>, NetError> {
        if !self.auth.borrow().has_session() {
            return Ok(Vec::new());
        }
        let resp = self.post("account/accounts_list", json!({})).await?;
        Ok(parse_accounts(&resp))
    }

    pub fn known_like_status(&self, video_id: &str) -> Option<LikeStatus> {
        self.known_likes.read().unwrap().get(video_id).copied()
    }

    pub fn set_known_like_status(&self, video_id: &str, status: LikeStatus) {
        self.known_likes
            .write()
            .unwrap()
            .insert(video_id.to_owned(), status);
    }

    pub async fn rate_song(&self, video_id: &str, status: LikeStatus) -> Result<(), NetError> {
        if !self.auth.borrow().has_session() {
            return Err(NetError::Unauthenticated);
        }
        let rating = match status {
            LikeStatus::Like => ytmusicapi::LikeStatus::Like,
            LikeStatus::Dislike => ytmusicapi::LikeStatus::Dislike,
            LikeStatus::Indifferent => ytmusicapi::LikeStatus::Indifferent,
        };
        self.api().rate_song(video_id, rating).await?;
        Ok(())
    }

    pub async fn post(&self, endpoint: &str, body: Value) -> Result<Value, NetError> {
        Ok(self.api().send_request(endpoint, body).await?)
    }

    pub async fn account_info(&self) -> Result<Option<AccountInfo>, NetError> {
        let resp = self.post("account/account_menu", json!({})).await?;
        let header = resp.pointer(
            "/actions/0/openPopupAction/popup/multiPageMenuRenderer/header/activeAccountHeaderRenderer",
        );
        let Some(header) = header else { return Ok(None) };
        let name = header
            .pointer("/accountName/runs/0/text")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        if name.is_empty() {
            return Ok(None);
        }
        let handle = header
            .pointer("/channelHandle/runs/0/text")
            .and_then(Value::as_str)
            .map(str::to_owned);
        let photo_url = header
            .pointer("/accountPhoto/thumbnails")
            .and_then(Value::as_array)
            .and_then(|t| t.last())
            .and_then(|t| t.get("url"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        Ok(Some(AccountInfo { name, handle, photo_url }))
    }
}

pub fn parse_accounts(resp: &Value) -> Vec<Account> {
    let mut items = Vec::new();
    collect_key(resp, "accountItem", &mut items);
    items.into_iter().filter_map(parse_account).collect()
}

fn collect_key<'a>(value: &'a Value, key: &str, out: &mut Vec<&'a Value>) {
    match value {
        Value::Object(map) => {
            for (k, v) in map {
                if k == key {
                    out.push(v);
                } else {
                    collect_key(v, key, out);
                }
            }
        }
        Value::Array(list) => list.iter().for_each(|v| collect_key(v, key, out)),
        _ => {}
    }
}

fn parse_account(item: &Value) -> Option<Account> {
    let text = |node: Option<&Value>| -> Option<String> {
        let node = node?;
        node.get("simpleText")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| {
                let runs = node.get("runs")?.as_array()?;
                Some(
                    runs.iter()
                        .filter_map(|r| r.get("text").and_then(Value::as_str))
                        .collect::<String>(),
                )
            })
    };
    let name = text(item.get("accountName")).filter(|n| !n.is_empty())?;
    let mut tokens = Vec::new();
    collect_key(item, "pageIdToken", &mut tokens);
    let page_id = tokens
        .iter()
        .find_map(|t| t.get("pageId").and_then(Value::as_str))
        .filter(|p| !p.is_empty())
        .map(str::to_owned);
    Some(Account {
        name,
        byline: text(item.get("accountByline")).filter(|b| !b.is_empty()),
        handle: text(item.get("channelHandle")).filter(|h| !h.is_empty()),
        photo_url: item
            .pointer("/accountPhoto/thumbnails")
            .and_then(Value::as_array)
            .and_then(|t| t.last())
            .and_then(|t| t.get("url"))
            .and_then(Value::as_str)
            .map(str::to_owned),
        page_id,
        selected: item.get("isSelected").and_then(Value::as_bool).unwrap_or(false),
    })
}

pub fn normalize_headers(raw: BTreeMap<String, String>) -> BTreeMap<String, String> {
    const DROP: &[&str] = &[
        "oauth_credentials",
        "client_id",
        "client_secret",
        "access_token",
        "refresh_token",
        "token_type",
        "expires_at",
        "expires_in",
    ];
    let mut out = BTreeMap::new();
    for (k, v) in raw {
        let lk = k.to_ascii_lowercase().replace('-', "_");
        match lk.as_str() {
            "cookie" => out.insert("Cookie".to_owned(), v),
            "user_agent" => out.insert("User-Agent".to_owned(), v),
            "accept_language" => out.insert("Accept-Language".to_owned(), v),
            "content_type" => out.insert("Content-Type".to_owned(), v),
            "x_goog_authuser" => out.insert("X-Goog-AuthUser".to_owned(), v),
            "x_goog_visitor_id" => out.insert("X-Goog-Visitor-Id".to_owned(), v),
            "authorization" if v.to_ascii_lowercase().starts_with("bearer") => None,
            "authorization" => out.insert("Authorization".to_owned(), v),
            _ if DROP.contains(&lk.as_str()) => None,
            _ if lk.starts_with("x_") => out.insert(k, v),
            _ => out.insert(title_case(&k), v),
        };
    }
    out.entry("Accept-Language".into())
        .or_insert_with(|| "en-US,en;q=0.9".into());
    out.entry("Content-Type".into())
        .or_insert_with(|| "application/json".into());
    out
}

fn title_case(key: &str) -> String {
    key.split('-')
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                Some(first) => first.to_ascii_uppercase().to_string() + &chars.as_str().to_ascii_lowercase(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join("-")
}

fn parse_auth_input(input: &str) -> Result<BTreeMap<String, String>, NetError> {
    let trimmed = input.trim();
    let path = std::path::Path::new(trimmed);
    if path.is_file() {
        let text = std::fs::read_to_string(path)?;
        return Ok(serde_json::from_str(&text)?);
    }
    if trimmed.starts_with('{') {
        return Ok(serde_json::from_str(trimmed)?);
    }
    let mut map = BTreeMap::new();
    for line in trimmed.lines() {
        if let Some((k, v)) = line.split_once(':') {
            let k = k.trim_start_matches(':').trim();
            if !k.is_empty() {
                map.insert(k.to_owned(), v.trim().to_owned());
            }
        }
    }
    if map.keys().any(|k| k.eq_ignore_ascii_case("cookie")) {
        Ok(map)
    } else {
        Err(NetError::InvalidAuth("no Cookie header found".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_normalization_drops_oauth() {
        let mut raw = BTreeMap::new();
        raw.insert("cookie".into(), "c".into());
        raw.insert("authorization".into(), "Bearer t".into());
        raw.insert("access_token".into(), "t".into());
        raw.insert("x-goog-authuser".into(), "0".into());
        let out = normalize_headers(raw);
        assert_eq!(out.get("Cookie").map(String::as_str), Some("c"));
        assert!(!out.contains_key("Authorization"));
        assert!(!out.contains_key("access_token"));
        assert_eq!(out.get("X-Goog-AuthUser").map(String::as_str), Some("0"));
    }

    #[test]
    fn crate_accepts_normalized_headers() {
        let mut raw = BTreeMap::new();
        raw.insert("cookie".into(), "a=1; __Secure-3PAPISID=xyz".into());
        raw.insert("x-goog-authuser".into(), "1".into());
        let headers = normalize_headers(raw);
        let auth = BrowserAuth::from_json(&serde_json::to_string(&headers).unwrap()).unwrap();
        assert_eq!(auth.sapisid().unwrap(), "xyz");
        assert_eq!(auth.x_goog_authuser, "1");
    }

    #[test]
    fn brand_accounts_come_with_page_id() {
        let resp = json!({"actions":[{"openPopupAction":{"popup":{"multiPageMenuRenderer":{"sections":[{"accountSectionListRenderer":{"contents":[{"accountItemSectionRenderer":{"contents":[
            {"accountItem":{"accountName":{"simpleText":"Asnanon"},"accountByline":{"simpleText":"No channel"},"isSelected":false}},
            {"accountItem":{"accountName":{"runs":[{"text":"asnanon"}]},"channelHandle":{"simpleText":"@asnanon"},"isSelected":true,
                "accountPhoto":{"thumbnails":[{"url":"a"},{"url":"b"}]},
                "serviceEndpoint":{"selectActiveIdentityEndpoint":{"supportedTokens":[{"pageIdToken":{"pageId":"1234"}}]}}}}
        ]}}]}}]}}}}]});
        let accounts = parse_accounts(&resp);
        assert_eq!(accounts.len(), 2);
        assert_eq!(accounts[1].page_id.as_deref(), Some("1234"));
        assert!(accounts[1].selected);
    }
}
