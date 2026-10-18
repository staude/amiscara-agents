//! Tauri commands: hosts and keys, live sessions, pane followers, actions.
//!
//! Session updates go out as the event `session-update`
//! (`{ hostId, update }`); a followed pane reports through its own
//! channel until `stop_follow` or the session ends.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use herdr_session::view::{PaneContent, SessionUpdate};
use herdr_session::{
    AddHostLink, Endpoint, PaneFollow, PaneSink, Session, SshIdentity, TranscriptCursor,
    TranscriptPage,
};
use herdr_transport::keys;
use serde::Serialize;
use tauri::ipc::Channel;
use tauri::{AppHandle, Emitter, Manager, State};

use crate::error::AppError;
use crate::hosts::{self, Auth, HostConfig, HostKind, HostStore, QuickReplies};
use crate::notify::{self, Notice};
use crate::tray::{self, WaitingAgents};

pub struct AppState {
    store: Mutex<HostStore>,
    quick_replies: Mutex<QuickReplies>,
    waiting: Mutex<WaitingAgents>,
    /// The pane the window shows; it gets no notification while the
    /// window has the focus.
    visible: Mutex<Option<(String, String)>>,
    sessions: Mutex<HashMap<String, Arc<Session>>>,
    follows: Mutex<HashMap<u64, PaneFollow>>,
    next_follow: AtomicU64,
    /// Counts session starts; pane followers end with their session, so the
    /// window follows anew when an update carries another generation.
    next_generation: AtomicU64,
}

impl AppState {
    pub fn new(store: HostStore, quick_replies: QuickReplies) -> Self {
        Self {
            store: Mutex::new(store),
            quick_replies: Mutex::new(quick_replies),
            waiting: Mutex::new(WaitingAgents::default()),
            visible: Mutex::new(None),
            sessions: Mutex::new(HashMap::new()),
            follows: Mutex::new(HashMap::new()),
            next_follow: AtomicU64::new(1),
            next_generation: AtomicU64::new(1),
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

    /// Whether the user looks at this pane right now.
    fn is_watched(&self, app: &AppHandle, host_id: &str, pane_id: &str) -> bool {
        let shown = self
            .visible
            .lock()
            .map(|visible| {
                visible
                    .as_ref()
                    .is_some_and(|(host, pane)| host == host_id && pane == pane_id)
            })
            .unwrap_or(false);
        shown
            && app.get_webview_window("main").is_some_and(|window| {
                window.is_visible().unwrap_or(false) && window.is_focused().unwrap_or(false)
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
pub fn delete_host(
    app: AppHandle,
    state: State<'_, AppState>,
    host_id: String,
) -> Result<(), AppError> {
    state.stop_session(&host_id);
    let mut waiting = state.waiting.lock().unwrap_or_else(|p| p.into_inner());
    if waiting.remove(&host_id) {
        tray::refresh(&app, &waiting);
    }
    drop(waiting);
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

/// Adds the host of a confirmed link with a new key of its own.
/// `trust_host_key` pins the link's host key; only for links the user pasted
/// from their own device. A link opened through the URL scheme can come from
/// any web page, so its key is not trusted: the first connection asks for
/// the fingerprint as usual.
#[tauri::command]
pub async fn add_from_link(
    state: State<'_, AppState>,
    link: AddHostLink,
    trust_host_key: bool,
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
        pinned_host_key: trust_host_key.then_some(link.host_key),
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
    generation: u64,
    update: &'a SessionUpdate,
}

/// Runs inside the async runtime: the session spawns its tasks there.
fn start(app: &AppHandle, state: &AppState, host: &HostConfig) -> Result<(), AppError> {
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
    let generation = state.next_generation.fetch_add(1, Ordering::Relaxed);
    // Held until the new session is stored: its first update can reach the
    // window before `start` returns, and `follow_pane` must not find the
    // old session then.
    let mut sessions = state.sessions();
    if let Some(old) = sessions.remove(&host.id) {
        old.stop();
    }
    let host_name = host.name.clone();
    let notify_on = host.notify.unwrap_or(true);
    let session = Session::start(endpoint, host.group_spaces_by_name(), move |update| {
        let _ = emitter.emit(
            "session-update",
            UpdateEvent {
                host_id: &host_id,
                generation,
                update: &update,
            },
        );
        let state = emitter.state::<AppState>();
        let mut waiting = state.waiting.lock().unwrap_or_else(|p| p.into_inner());
        if waiting.set(&host_id, &host_name, &update.board) {
            tray::refresh(&emitter, &waiting);
        }
        drop(waiting);
        if notify_on {
            for item in &update.attention {
                if !state.is_watched(&emitter, &host_id, &item.pane_id) {
                    notify::show(&emitter, Notice::new(&host_id, &host_name, item));
                }
            }
        }
    })?;
    sessions.insert(host.id.clone(), Arc::new(session));
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

/// Sends what the composer holds: to an agent as a prompt, to a shell as
/// typed text followed by Enter.
#[tauri::command]
pub async fn submit(
    state: State<'_, AppState>,
    host_id: String,
    pane_id: String,
    text: String,
    is_agent: bool,
) -> Result<(), AppError> {
    input_allowed(&state, &host_id)?;
    let session = state.session(&host_id)?;
    if is_agent {
        session.send_prompt(&pane_id, &text).await?;
    } else {
        session.send_text(&pane_id, &text).await?;
        session.send_keys(&pane_id, &["enter".to_owned()]).await?;
    }
    Ok(())
}

/// Part of the Claude Code conversation in a pane (#102); read only.
#[tauri::command]
pub async fn claude_history(
    state: State<'_, AppState>,
    host_id: String,
    pane_id: String,
    before: Option<TranscriptCursor>,
) -> Result<TranscriptPage, AppError> {
    let session = state.session(&host_id)?;
    Ok(session.claude_history(&pane_id, before).await?)
}

/// Uploads one file, sent as the raw request body to spare a JSON array of
/// numbers. Headers: `x-host-id`, and either `x-file-name` (any file, kept
/// under its name, percent-encoded) or `x-file-extension` (a prepared
/// image). Returns the absolute path on the host.
#[tauri::command]
pub async fn upload(
    state: State<'_, AppState>,
    request: tauri::ipc::Request<'_>,
) -> Result<String, AppError> {
    let header = |name: &str| {
        request
            .headers()
            .get(name)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned)
    };
    let host_id =
        header("x-host-id").ok_or_else(|| AppError::Config("x-host-id missing".into()))?;
    let tauri::ipc::InvokeBody::Raw(data) = request.body() else {
        return Err(AppError::Config("upload without raw body".into()));
    };
    let host = state.store().get(&host_id)?;
    if host.kind == HostKind::Ssh && !host.allow_upload.unwrap_or(false) {
        return Err(AppError::Config(format!(
            "Dateien hochladen ist für {} aus. Einschalten unter „Bearbeiten“.",
            host.name
        )));
    }
    input_allowed(&state, &host_id)?;
    let session = state.session(&host_id)?;
    if let Some(name) = header("x-file-name") {
        let name = percent_decode(&name);
        Ok(session.upload_named_file(data, &name).await?)
    } else {
        let ext = header("x-file-extension").unwrap_or_default();
        Ok(session.upload_file(data, &ext).await?)
    }
}

/// `%XX` escapes from `encodeURIComponent`; anything malformed stays as is.
fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && let Some(hex) = text.get(i + 1..i + 3)
            && let Ok(byte) = u8::from_str_radix(hex, 16)
        {
            out.push(byte);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[tauri::command]
pub fn quick_replies(state: State<'_, AppState>) -> Vec<String> {
    state
        .quick_replies
        .lock()
        .map(|replies| replies.list().to_vec())
        .unwrap_or_default()
}

#[tauri::command]
pub fn save_quick_replies(
    state: State<'_, AppState>,
    replies: Vec<String>,
) -> Result<(), AppError> {
    state
        .quick_replies
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .set(replies)
}

/// Prefix of the link that opens a pane: `amiscara-agents://open?host=<id>
/// &workspace=<id>&pane=<id>`, e.g. from a script or another app.
const OPEN_PREFIX: &str = "amiscara-agents://open?";

/// Hands opened `amiscara-agents://` links to the window: add-host links
/// for confirmation, open links straight to their pane.
pub fn open_links(app: &AppHandle, urls: impl IntoIterator<Item = String>) {
    for url in urls {
        let starts = |prefix: &str| {
            url.get(..prefix.len())
                .is_some_and(|start| start.eq_ignore_ascii_case(prefix))
        };
        if starts(herdr_session::ADD_HOST_PREFIX) {
            let _ = app.emit("add-host-link", url);
        } else if starts(OPEN_PREFIX) {
            let query = &url[OPEN_PREFIX.len()..];
            let field = |name: &str| {
                query.split('&').find_map(|pair| {
                    let (key, value) = pair.split_once('=')?;
                    (key == name).then(|| percent_decode(value))
                })
            };
            if let (Some(host), Some(pane)) = (field("host"), field("pane")) {
                open_pane(app, &host, &field("workspace").unwrap_or_default(), &pane);
            }
        }
    }
    tray::show_window(app);
}

/// Fronts the window and selects a pane (tray menu, notification, link).
pub fn open_pane(app: &AppHandle, host_id: &str, workspace_id: &str, pane_id: &str) {
    tray::show_window(app);
    let _ = app.emit(
        "open-pane",
        serde_json::json!({ "hostId": host_id, "workspaceId": workspace_id, "paneId": pane_id }),
    );
}

/// Sends an answer key chosen on a notification.
#[cfg_attr(not(any(windows, target_os = "linux")), allow(dead_code))]
pub fn answer(app: &AppHandle, host_id: &str, pane_id: &str, key: String) {
    let app = app.clone();
    let host_id = host_id.to_owned();
    let pane_id = pane_id.to_owned();
    tauri::async_runtime::spawn(async move {
        let state = app.state::<AppState>();
        if input_allowed(&state, &host_id).is_err() {
            return;
        }
        if let Ok(session) = state.session(&host_id) {
            let _ = session.send_keys(&pane_id, &[key]).await;
        }
    });
}

/// The pane the window shows, or none; for leaving out its notifications.
#[tauri::command]
pub fn set_visible_pane(
    state: State<'_, AppState>,
    host_id: Option<String>,
    pane_id: Option<String>,
) {
    if let Ok(mut visible) = state.visible.lock() {
        *visible = host_id.zip(pane_id);
    }
}

/// A new space or tab: its first pane.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Created {
    workspace_id: String,
    tab_id: String,
    pane_id: String,
}

impl From<herdr_core::actions::Created> for Created {
    fn from(created: herdr_core::actions::Created) -> Self {
        Self {
            workspace_id: created.workspace_id,
            tab_id: created.tab_id,
            pane_id: created.pane_id,
        }
    }
}

/// `~` and paths below it on the host, made absolute: herdr wants absolute
/// directories. The home is taken from the socket path when it has the
/// default form, else the macOS default for the login.
fn absolute_path(host: &HostConfig, input: &str) -> String {
    let input = input.trim();
    let home = match host.kind {
        HostKind::Local => std::env::var("HOME").unwrap_or_default(),
        HostKind::Ssh => host
            .socket_path
            .strip_suffix("/.config/herdr/herdr.sock")
            .map(str::to_owned)
            .unwrap_or_else(|| format!("/Users/{}", host.user)),
    };
    if input.is_empty() || input == "~" {
        home
    } else if let Some(rest) = input.strip_prefix("~/") {
        format!("{home}/{rest}")
    } else if input.starts_with('/') {
        input.to_owned()
    } else {
        format!("{home}/{input}")
    }
}

/// Session of a host that takes input; the check every write goes through.
fn writable(state: &AppState, host_id: &str) -> Result<Arc<Session>, AppError> {
    input_allowed(state, host_id)?;
    state.session(host_id)
}

/// Agent kinds the host's herdr can start, the usual ones first.
#[tauri::command]
pub async fn agent_kinds(
    state: State<'_, AppState>,
    host_id: String,
) -> Result<Vec<String>, AppError> {
    Ok(state.session(&host_id)?.agent_kinds().await)
}

/// A space with a shell in `directory` (`~` allowed).
#[tauri::command]
pub async fn create_workspace(
    state: State<'_, AppState>,
    host_id: String,
    label: String,
    directory: String,
) -> Result<Created, AppError> {
    let host = state.store().get(&host_id)?;
    let session = writable(&state, &host_id)?;
    let label = label.trim();
    let cwd = absolute_path(&host, &directory);
    Ok(session
        .create_workspace((!label.is_empty()).then_some(label), &cwd)
        .await?
        .into())
}

#[tauri::command]
pub async fn create_tab(
    state: State<'_, AppState>,
    host_id: String,
    workspace_id: String,
) -> Result<Created, AppError> {
    let session = writable(&state, &host_id)?;
    Ok(session.create_tab(&workspace_id, None).await?.into())
}

/// A worktree of the space's repository as a new space; empty fields are
/// left to herdr.
#[tauri::command]
pub async fn create_worktree(
    state: State<'_, AppState>,
    host_id: String,
    workspace_id: String,
    branch: String,
    base: String,
    label: String,
) -> Result<Created, AppError> {
    let session = writable(&state, &host_id)?;
    let field = |text: String| {
        let text = text.trim().to_owned();
        (!text.is_empty()).then_some(text)
    };
    let worktree = herdr_core::actions::NewWorktree {
        branch: field(branch),
        base: field(base),
        label: field(label),
        path: None,
    };
    Ok(session
        .create_worktree(&workspace_id, &worktree)
        .await?
        .into())
}

#[tauri::command]
pub async fn start_agent(
    state: State<'_, AppState>,
    host_id: String,
    pane_id: String,
    kind: String,
) -> Result<String, AppError> {
    let session = writable(&state, &host_id)?;
    Ok(session.start_agent(&pane_id, &kind, None).await?)
}

/// Renames a space, tab or agent (`kind`: `space`, `tab`, `agent`); an
/// agent's empty name removes it.
#[tauri::command]
pub async fn rename(
    state: State<'_, AppState>,
    host_id: String,
    kind: String,
    id: String,
    name: String,
) -> Result<(), AppError> {
    let session = writable(&state, &host_id)?;
    let name = name.trim();
    match kind.as_str() {
        "space" => session.rename_workspace(&id, name).await?,
        "tab" => session.rename_tab(&id, name).await?,
        "agent" => {
            session
                .rename_agent(&id, (!name.is_empty()).then_some(name))
                .await?
        }
        other => return Err(AppError::Config(format!("unknown kind {other}"))),
    }
    Ok(())
}

/// Closes a tab, or a space (with its linked worktree spaces when asked).
#[tauri::command]
pub async fn close(
    state: State<'_, AppState>,
    host_id: String,
    kind: String,
    id: String,
    with_worktrees: bool,
) -> Result<(), AppError> {
    let session = writable(&state, &host_id)?;
    match kind.as_str() {
        "space" => session.close_workspace(&id, with_worktrees).await?,
        "tab" => session.close_tab(&id).await?,
        other => return Err(AppError::Config(format!("unknown kind {other}"))),
    }
    Ok(())
}

#[tauri::command]
pub fn autostart(app: AppHandle) -> bool {
    use tauri_plugin_autostart::ManagerExt;
    app.autolaunch().is_enabled().unwrap_or(false)
}

#[tauri::command]
pub fn set_autostart(app: AppHandle, on: bool) -> Result<(), AppError> {
    use tauri_plugin_autostart::ManagerExt;
    let manager = app.autolaunch();
    let result = if on {
        manager.enable()
    } else {
        manager.disable()
    };
    result.map_err(|err| AppError::Config(format!("Autostart: {err}")))
}

#[cfg(test)]
mod tests {
    use super::{absolute_path, percent_decode};
    use crate::hosts::HostConfig;

    #[test]
    fn percent_decoding_matches_encode_uri_component() {
        assert_eq!(
            percent_decode("Rechnung%20M%C3%A4rz.xlsx"),
            "Rechnung März.xlsx"
        );
        assert_eq!(percent_decode("a%2"), "a%2");
        assert_eq!(percent_decode("100%"), "100%");
    }

    #[test]
    fn paths_below_the_home_of_the_host() {
        let host: HostConfig = serde_json::from_str(
            r#"{"id":"a","name":"w","kind":"ssh","user":"frank","socketPath":"/home/frank/.config/herdr/herdr.sock"}"#,
        )
        .expect("host");
        assert_eq!(absolute_path(&host, "~"), "/home/frank");
        assert_eq!(absolute_path(&host, "~/dev/x"), "/home/frank/dev/x");
        assert_eq!(absolute_path(&host, "dev"), "/home/frank/dev");
        assert_eq!(absolute_path(&host, "/srv"), "/srv");
    }
}
