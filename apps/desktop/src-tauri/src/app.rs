//! Tauri commands: hosts and keys, live sessions, pane followers, actions.
//!
//! Session updates go out as the event `session-update`
//! (`{ hostId, update }`); a followed pane reports through its own
//! channel until `stop_follow` or the session ends.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use herdr_session::view::{PaneContent, SessionUpdate};
use herdr_session::{AddHostLink, Endpoint, PaneFollow, PaneSink, Session, SshIdentity};
use herdr_transport::keys;
use serde::Serialize;
use tauri::ipc::Channel;
use tauri::{AppHandle, Emitter, Manager, State};

use crate::error::AppError;
use crate::hosts::{self, Auth, HostConfig, HostKind, HostStore};

pub struct AppState {
    store: Mutex<HostStore>,
    sessions: Mutex<HashMap<String, Arc<Session>>>,
    follows: Mutex<HashMap<u64, PaneFollow>>,
    next_follow: AtomicU64,
}

impl AppState {
    pub fn new(store: HostStore) -> Self {
        Self {
            store: Mutex::new(store),
            sessions: Mutex::new(HashMap::new()),
            follows: Mutex::new(HashMap::new()),
            next_follow: AtomicU64::new(1),
        }
    }

    fn store(&self) -> MutexGuard<'_, HostStore> {
        self.store
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    fn sessions(&self) -> MutexGuard<'_, HashMap<String, Arc<Session>>> {
        self.sessions
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    fn follows(&self) -> MutexGuard<'_, HashMap<u64, PaneFollow>> {
        self.follows
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    fn session(&self, host_id: &str) -> Result<Arc<Session>, AppError> {
        self.sessions().get(host_id).cloned().ok_or_else(|| {
            AppError::Session(herdr_session::SessionError::NotConnected(
                "not connected to herdr".into(),
            ))
        })
    }

    fn stop_session(&self, host_id: &str) {
        if let Some(session) = self.sessions().remove(host_id) {
            session.stop();
        }
    }
}

/// What the frontend needs to know about this build and platform.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppInfo {
    version: &'static str,
    protocol: u32,
    /// Whether a host can be this machine's own herdr socket.
    local_socket: bool,
    os: &'static str,
}

#[tauri::command]
pub fn app_info() -> AppInfo {
    AppInfo {
        version: env!("CARGO_PKG_VERSION"),
        protocol: herdr_proto::SUPPORTED_PROTOCOL,
        local_socket: cfg!(unix),
        os: std::env::consts::OS,
    }
}

#[tauri::command]
pub fn list_hosts(state: State<'_, AppState>) -> Vec<HostConfig> {
    state.store().hosts().to_vec()
}

/// Adds or changes a host. An SSH host with its own key gets one on first
/// save. The window then calls `connect`, which restarts a running session
/// with the new settings.
#[tauri::command]
pub async fn save_host(
    state: State<'_, AppState>,
    mut host: HostConfig,
) -> Result<HostConfig, AppError> {
    if host.id.is_empty() {
        host.id = uuid::Uuid::new_v4().to_string();
    }
    host.name = host.name.trim().to_owned();
    host.host = host.host.trim().to_owned();
    host.user = host.user.trim().to_owned();
    host.socket_path = host.socket_path.trim().to_owned();
    if host.name.is_empty() {
        host.name = if host.kind == HostKind::Local {
            "Dieser Rechner".into()
        } else {
            host.host.clone()
        };
    }
    if host.kind == HostKind::Ssh {
        if host.host.is_empty() || host.user.is_empty() {
            return Err(AppError::Config("Host und Benutzer fehlen.".into()));
        }
        if !host.socket_path.starts_with('/') {
            return Err(AppError::Config(
                "Der Socket-Pfad muss absolut sein, z. B. /home/frank/.config/herdr/herdr.sock."
                    .into(),
            ));
        }
        if host.auth == Auth::Key && hosts::private_key(&host.id)?.is_none() {
            host.public_key = Some(new_key(&host)?);
        }
    } else if !cfg!(unix) {
        return Err(AppError::Config(
            "Ein lokaler herdr-Socket geht nur unter Linux.".into(),
        ));
    }
    state.store().put(host.clone())?;
    Ok(host)
}

/// Replaces the host's key; the old line in `authorized_keys` stops working.
#[tauri::command]
pub fn regenerate_key(state: State<'_, AppState>, host_id: String) -> Result<HostConfig, AppError> {
    let mut host = state.store().get(&host_id)?;
    host.public_key = Some(new_key(&host)?);
    state.store().put(host.clone())?;
    Ok(host)
}

fn new_key(host: &HostConfig) -> Result<String, AppError> {
    let device = std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| std::env::consts::OS.to_owned());
    let key = keys::generate_ed25519(&format!("amiscara-agents {device}"))
        .map_err(|err| AppError::Session(herdr_session::SessionError::Key(err.to_string())))?;
    hosts::store_private_key(&host.id, &key.private_openssh)?;
    Ok(key.public_openssh)
}

#[tauri::command]
pub fn delete_host(state: State<'_, AppState>, host_id: String) -> Result<(), AppError> {
    state.stop_session(&host_id);
    hosts::delete_private_key(&host_id)?;
    state.store().remove(&host_id)
}

/// The restricted `authorized_keys` line for the host's key (#132).
#[tauri::command]
pub fn key_line(
    state: State<'_, AppState>,
    host_id: String,
    allow_sftp: bool,
) -> Result<String, AppError> {
    let host = state.store().get(&host_id)?;
    let public = host
        .public_key
        .as_deref()
        .ok_or_else(|| AppError::Config("Dieser Host hat keinen eigenen Schlüssel.".into()))?;
    Ok(herdr_session::authorized_keys_line(
        public,
        allow_sftp,
        host.custom_socket(),
    )?)
}

/// Reads a pasted or opened "add host" link; the caller shows it and
/// confirms with `add_from_link`.
#[tauri::command]
pub fn decode_link(text: String) -> Result<AddHostLink, AppError> {
    Ok(herdr_session::decode_add_host_link(text)?)
}

/// `SHA256:...` of an OpenSSH public key line.
#[tauri::command]
pub fn key_fingerprint(public_key: String) -> Result<String, AppError> {
    Ok(herdr_session::public_key_fingerprint(public_key)?)
}

/// Adds the host of a confirmed link, its host key already trusted, with a
/// new key of its own.
#[tauri::command]
pub async fn add_from_link(
    state: State<'_, AppState>,
    link: AddHostLink,
) -> Result<HostConfig, AppError> {
    let socket_path = if link.socket_path.is_empty() {
        format!("/Users/{}/.config/herdr/herdr.sock", link.user)
    } else {
        link.socket_path
    };
    let host = HostConfig {
        id: String::new(),
        name: if link.name.is_empty() {
            link.host.clone()
        } else {
            link.name
        },
        kind: HostKind::Ssh,
        host: link.host,
        port: link.port,
        user: link.user,
        socket_path,
        pinned_host_key: Some(link.host_key),
        public_key: None,
        auth: Auth::Key,
        allow_input: None,
        allow_upload: None,
        notify: None,
        group_spaces: None,
    };
    save_host(state, host).await
}

/// Starts (or restarts) the live session of a host.
#[tauri::command]
pub async fn connect(
    app: AppHandle,
    state: State<'_, AppState>,
    host_id: String,
) -> Result<(), AppError> {
    let host = state.store().get(&host_id)?;
    start(&app, &state, &host)
}

#[tauri::command]
pub fn disconnect(state: State<'_, AppState>, host_id: String) {
    state.stop_session(&host_id);
}

/// Trusts `key` (from a host key prompt) and reconnects.
#[tauri::command]
pub async fn trust_host_key(
    app: AppHandle,
    state: State<'_, AppState>,
    host_id: String,
    key: String,
) -> Result<(), AppError> {
    let mut host = state.store().get(&host_id)?;
    host.pinned_host_key = Some(key);
    state.store().put(host.clone())?;
    start(&app, &state, &host)
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct UpdateEvent<'a> {
    host_id: &'a str,
    update: &'a SessionUpdate,
}

/// Runs inside the async runtime: the session spawns its tasks there.
fn start(app: &AppHandle, state: &AppState, host: &HostConfig) -> Result<(), AppError> {
    state.stop_session(&host.id);
    let endpoint = match host.kind {
        HostKind::Local => Endpoint::Local {
            socket_path: (!host.socket_path.is_empty()).then(|| host.socket_path.clone()),
        },
        HostKind::Ssh => Endpoint::Ssh {
            host: host.host.clone(),
            port: host.port,
            user: host.user.clone(),
            identity: match host.auth {
                Auth::Agent => SshIdentity::Agent,
                Auth::Key => SshIdentity::Key(hosts::private_key(&host.id)?.ok_or_else(|| {
                    AppError::Config("Der Schlüssel dieses Hosts fehlt im Schlüsselbund.".into())
                })?),
            },
            pinned_host_key: host.pinned_host_key.clone(),
            socket_path: host.socket_path.clone(),
        },
    };
    let emitter = app.clone();
    let host_id = host.id.clone();
    let session = Session::start(endpoint, host.group_spaces_by_name(), move |update| {
        let _ = emitter.emit(
            "session-update",
            UpdateEvent {
                host_id: &host_id,
                update: &update,
            },
        );
    })?;
    state.sessions().insert(host.id.clone(), Arc::new(session));
    Ok(())
}

/// What a pane channel carries.
#[derive(Clone, Serialize)]
#[serde(tag = "kind", content = "data", rename_all = "camelCase")]
pub enum PaneEvent {
    Content(PaneContent),
    Error(String),
}

struct ChannelSink(Channel<PaneEvent>);

impl PaneSink for ChannelSink {
    fn on_content(&self, content: PaneContent) {
        let _ = self.0.send(PaneEvent::Content(content));
    }

    fn on_error(&self, message: String) {
        let _ = self.0.send(PaneEvent::Error(message));
    }
}

/// Follows a pane into `channel`; returns the id for `stop_follow` and the
/// setters. `live: false` reads only every few seconds.
#[tauri::command]
pub fn follow_pane(
    state: State<'_, AppState>,
    host_id: String,
    pane_id: String,
    live: bool,
    channel: Channel<PaneEvent>,
) -> Result<u64, AppError> {
    let session = state.session(&host_id)?;
    let follow = session.follow_pane(pane_id, live, ChannelSink(channel));
    let id = state.next_follow.fetch_add(1, Ordering::Relaxed);
    state.follows().insert(id, follow);
    Ok(id)
}

/// Ends a follower once its request in flight is done (#107).
#[tauri::command]
pub fn stop_follow(state: State<'_, AppState>, follow_id: u64) {
    if let Some(follow) = state.follows().remove(&follow_id) {
        follow.stop();
    }
}

#[tauri::command]
pub fn set_follow_live(state: State<'_, AppState>, follow_id: u64, live: bool) {
    if let Some(follow) = state.follows().get(&follow_id) {
        follow.set_live(live);
    }
}

#[tauri::command]
pub fn set_follow_history(state: State<'_, AppState>, follow_id: u64, lines: u32) {
    if let Some(follow) = state.follows().get(&follow_id) {
        follow.set_history_lines(lines);
    }
}

fn input_allowed(state: &AppState, host_id: &str) -> Result<(), AppError> {
    if state.store().get(host_id)?.allow_input.unwrap_or(true) {
        Ok(())
    } else {
        Err(AppError::Config(
            "Eingaben sind für diesen Host ausgeschaltet.".into(),
        ))
    }
}

#[tauri::command]
pub async fn send_prompt(
    state: State<'_, AppState>,
    host_id: String,
    pane_id: String,
    text: String,
) -> Result<(), AppError> {
    input_allowed(&state, &host_id)?;
    let session = state.session(&host_id)?;
    Ok(session.send_prompt(&pane_id, &text).await?)
}

#[tauri::command]
pub async fn send_keys(
    state: State<'_, AppState>,
    host_id: String,
    pane_id: String,
    keys: Vec<String>,
) -> Result<(), AppError> {
    input_allowed(&state, &host_id)?;
    let session = state.session(&host_id)?;
    Ok(session.send_keys(&pane_id, &keys).await?)
}

#[tauri::command]
pub async fn send_text(
    state: State<'_, AppState>,
    host_id: String,
    pane_id: String,
    text: String,
) -> Result<(), AppError> {
    input_allowed(&state, &host_id)?;
    let session = state.session(&host_id)?;
    Ok(session.send_text(&pane_id, &text).await?)
}

/// Hands an opened `amiscara-agents://add-host` link to the window.
pub fn open_links(app: &AppHandle, urls: impl IntoIterator<Item = String>) {
    for url in urls {
        if url
            .get(..herdr_session::ADD_HOST_PREFIX.len())
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case(herdr_session::ADD_HOST_PREFIX))
        {
            let _ = app.emit("add-host-link", url);
        }
    }
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}
