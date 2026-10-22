//! One live host: connection with reconnects, updates for the view, pane
//! followers, actions, uploads and the Claude Code history.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use herdr_core::pane::{self, Pacing};
use herdr_core::sync::{self, SyncState};
use herdr_core::{actions, claude, fullscreen};
use herdr_transport::{Connection, HostKeyPolicy, Identity, SshTarget, TransportError, keys};
use tokio::runtime::Handle;
use tokio::sync::watch;
use tokio::task::JoinHandle;

use crate::access::{gate_options, key_error};
use crate::view::{self, PaneContent, SessionUpdate};

/// Where uploads land, relative to the login's home directory.
pub const UPLOAD_DIR: &str = ".amiscara-agents/uploads";

#[derive(Debug, thiserror::Error, serde::Serialize)]
#[serde(tag = "kind", content = "message", rename_all = "camelCase")]
pub enum SessionError {
    #[error("{0}")]
    Key(String),
    #[error("{0}")]
    Unsupported(String),
    /// No live connection right now; the session reconnects on its own.
    #[error("{0}")]
    NotConnected(String),
    /// The agent waits at an approval or question dialog; answer it first.
    #[error("{0}")]
    AgentBlocked(String),
    /// herdr refused the input, e.g. an unknown pane or key.
    #[error("{0}")]
    Rejected(String),
    /// A file could not be uploaded (no SFTP for this key, or the server
    /// refused the write).
    #[error("{0}")]
    Upload(String),
    /// A scanned or opened "add host" link was refused.
    #[error("{0}")]
    InvalidLink(#[from] crate::link::LinkError),
    /// Files on the host could not be read: no SFTP for this key, or no
    /// Claude Code session for the pane.
    #[error("{0}")]
    Files(String),
    /// herdr collects a full-screen agent's history only while it is idle.
    #[error("{0}")]
    AgentWorking(String),
}

impl From<claude::ClaudeError> for SessionError {
    fn from(err: claude::ClaudeError) -> Self {
        match err {
            claude::ClaudeError::Transport(TransportError::Files(message)) => Self::Files(message),
            claude::ClaudeError::Transport(other) => Self::NotConnected(other.to_string()),
            other => Self::Files(other.to_string()),
        }
    }
}

impl From<pane::PaneError> for SessionError {
    fn from(err: pane::PaneError) -> Self {
        match err {
            pane::PaneError::Transport(_) => Self::NotConnected(err.to_string()),
            pane::PaneError::Json(_) => Self::Rejected(err.to_string()),
        }
    }
}

impl From<fullscreen::HistoryError> for SessionError {
    fn from(err: fullscreen::HistoryError) -> Self {
        match err {
            fullscreen::HistoryError::AgentWorking => Self::AgentWorking(err.to_string()),
            fullscreen::HistoryError::Pane(err) => err.into(),
        }
    }
}

impl From<actions::ActionError> for SessionError {
    fn from(err: actions::ActionError) -> Self {
        match err {
            actions::ActionError::AgentBlocked => Self::AgentBlocked(err.to_string()),
            actions::ActionError::Rejected { .. } => Self::Rejected(err.to_string()),
            actions::ActionError::Transport(_) => Self::NotConnected(err.to_string()),
        }
    }
}

fn upload_error(err: TransportError) -> SessionError {
    match err {
        TransportError::Upload(message) => SessionError::Upload(message),
        other => SessionError::NotConnected(other.to_string()),
    }
}

/// Where a herdr server lives.
#[derive(Debug, Clone)]
pub enum Endpoint {
    /// The Unix socket on this machine. `None` uses `~/.config/herdr/herdr.sock`.
    Local { socket_path: Option<String> },
    /// A remote server over SSH streamlocal.
    Ssh {
        host: String,
        port: u16,
        user: String,
        identity: SshIdentity,
        /// Trusted host key as an OpenSSH public key line. `None` on first
        /// contact: the session then reports `HostStatus::HostKeyUnknown`.
        pinned_host_key: Option<String>,
        /// Absolute path of `herdr.sock` on the server.
        socket_path: String,
    },
}

/// How a session logs in over SSH.
#[derive(Clone)]
pub enum SshIdentity {
    /// Unencrypted OpenSSH private key, e.g. from the OS key store.
    Key(String),
    /// The SSH agent: `SSH_AUTH_SOCK`, on Windows the OpenSSH agent's
    /// named pipe.
    Agent,
}

impl std::fmt::Debug for SshIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Key(_) => f.write_str("Key(..)"),
            Self::Agent => f.write_str("Agent"),
        }
    }
}

/// A step through a full-screen agent's own view, see
/// [`Session::scroll_agent`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ScrollStep {
    /// Half a screen up.
    PageUp,
    PageDown,
    /// Back to the newest output, which the agent then follows again.
    Bottom,
}

impl From<ScrollStep> for fullscreen::Scroll {
    fn from(step: ScrollStep) -> Self {
        match step {
            ScrollStep::PageUp => Self::PageUp,
            ScrollStep::PageDown => Self::PageDown,
            ScrollStep::Bottom => Self::Bottom,
        }
    }
}

/// Who wrote an entry of a Claude Code conversation.
#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TranscriptKind {
    User,
    Assistant,
    Tool,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptEntry {
    pub kind: TranscriptKind,
    pub text: String,
    /// ISO 8601, as Claude Code wrote it.
    pub timestamp: Option<String>,
}

/// Where to continue a conversation backwards, from a [`TranscriptPage`].
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptCursor {
    pub session_path: String,
    pub start: u64,
}

/// Part of a Claude Code conversation, oldest entry first.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptPage {
    /// The session file below the host's home directory; pass it back with
    /// `start` to load the entries before this page.
    pub session_path: String,
    pub entries: Vec<TranscriptEntry>,
    /// Byte offset this page starts at; 0 means the conversation's start.
    pub start: u64,
}

impl From<claude::Entry> for TranscriptEntry {
    fn from(entry: claude::Entry) -> Self {
        Self {
            kind: match entry.kind {
                claude::EntryKind::User => TranscriptKind::User,
                claude::EntryKind::Assistant => TranscriptKind::Assistant,
                claude::EntryKind::Tool => TranscriptKind::Tool,
            },
            text: entry.text,
            timestamp: entry.timestamp,
        }
    }
}

/// Receives what a pane follower reads, on a runtime thread.
pub trait PaneSink: Send + Sync + 'static {
    fn on_content(&self, content: PaneContent);
    /// The pane could not be read, e.g. because it was closed or the
    /// connection dropped. Following continues once a connection is back.
    fn on_error(&self, message: String);
}

/// One live host: keeps the session state current until stopped or dropped.
pub struct Session {
    state: Mutex<Option<watch::Receiver<SyncState>>>,
    /// Whether spaces are grouped by their "Bereich/Name" labels. A change
    /// rebuilds the last update, so the app needs no reconnect.
    group_by_name: watch::Sender<bool>,
    forward: JoinHandle<()>,
    runtime: Handle,
}

impl Session {
    /// Connects in the background and calls `on_update` with every state
    /// change from then on, on a runtime thread. `group_spaces_by_name` is
    /// the host's setting for the "Bereich/Name" convention (see
    /// `herdr_core::spaces`). Call it inside a Tokio runtime; the session's
    /// tasks run there.
    pub fn start(
        endpoint: Endpoint,
        group_spaces_by_name: bool,
        on_update: impl Fn(SessionUpdate) + Send + 'static,
    ) -> Result<Self, SessionError> {
        let connector = Connector::new(endpoint)?;
        let runtime = Handle::current();
        let rx = sync::spawn(move || {
            let connector = connector.clone();
            async move { connector.connect().await }
        });
        let mut updates = rx.clone();
        let (group_by_name, mut grouping) = watch::channel(group_spaces_by_name);
        let forward = runtime.spawn(async move {
            // The state the last update was based on, to report what changed.
            let mut previous: Option<Arc<herdr_core::SessionState>> = None;
            loop {
                let state = updates.borrow_and_update().clone();
                let by_name = *grouping.borrow_and_update();
                let update = view::session_update(&state, previous.as_deref(), by_name);
                if state.session.is_some() {
                    previous = state.session.clone();
                }
                on_update(update);
                // A changed setting alone rebuilds the same state; its
                // attention is then empty, so nothing is notified twice.
                tokio::select! {
                    changed = updates.changed() => {
                        if changed.is_err() {
                            return;
                        }
                    }
                    Ok(()) = grouping.changed() => {}
                }
            }
        });
        Ok(Self {
            state: Mutex::new(Some(rx)),
            group_by_name,
            forward,
            runtime,
        })
    }

    /// Switches grouping by "Bereich/Name" on or off; a rebuilt update
    /// follows right away, without reconnecting.
    pub fn set_group_spaces_by_name(&self, on: bool) {
        self.group_by_name.send_if_modified(|current| {
            let changed = *current != on;
            *current = on;
            changed
        });
    }

    /// Ends the session and closes the connection. Pane followers stop too.
    pub fn stop(&self) {
        self.forward.abort();
        if let Ok(mut state) = self.state.lock() {
            state.take();
        }
    }

    fn connection(&self) -> Result<Arc<Connection>, SessionError> {
        self.state
            .lock()
            .ok()
            .and_then(|state| state.as_ref().and_then(|rx| rx.borrow().connection.clone()))
            .ok_or_else(|| SessionError::NotConnected("not connected to herdr".into()))
    }

    /// Sends a prompt to the agent in a pane, followed by Enter.
    pub async fn send_prompt(&self, pane_id: &str, text: &str) -> Result<(), SessionError> {
        let conn = self.connection()?;
        Ok(actions::send_prompt(&conn, pane_id, text).await?)
    }

    /// The last `max_lines` lines with text of a pane's visible screen,
    /// without styles, e.g. what a waiting agent asks (#156). Read only.
    pub async fn screen_excerpt(
        &self,
        pane_id: &str,
        max_lines: u32,
    ) -> Result<String, SessionError> {
        let conn = self.connection()?;
        let read = pane::read_screen(&conn, pane_id).await?;
        Ok(read.screen.excerpt(max_lines as usize))
    }

    /// Sends logical keys (`enter`, `esc`, `1`, `ctrl+c`, ...) to a pane.
    pub async fn send_keys(&self, pane_id: &str, keys: &[String]) -> Result<(), SessionError> {
        let conn = self.connection()?;
        Ok(actions::send_keys(&conn, pane_id, keys).await?)
    }

    /// Types text into a pane without Enter.
    pub async fn send_text(&self, pane_id: &str, text: &str) -> Result<(), SessionError> {
        let conn = self.connection()?;
        Ok(actions::send_text(&conn, pane_id, text).await?)
    }

    /// Creates a space with a shell in `cwd` (absolute path) and returns
    /// its first pane. Not focused in herdr's own client.
    pub async fn create_workspace(
        &self,
        label: Option<&str>,
        cwd: &str,
    ) -> Result<actions::Created, SessionError> {
        let conn = self.connection()?;
        Ok(actions::create_workspace(&conn, label, cwd).await?)
    }

    /// Creates a tab in a space and returns its first pane.
    pub async fn create_tab(
        &self,
        workspace_id: &str,
        cwd: Option<&str>,
    ) -> Result<actions::Created, SessionError> {
        let conn = self.connection()?;
        Ok(actions::create_tab(&conn, workspace_id, cwd).await?)
    }

    /// Creates a Git worktree from the repository of space `workspace_id`
    /// and opens it as a new space; returns its first pane once
    /// `git worktree add` is done.
    pub async fn create_worktree(
        &self,
        workspace_id: &str,
        worktree: &actions::NewWorktree,
    ) -> Result<actions::Created, SessionError> {
        let conn = self.connection()?;
        Ok(actions::create_worktree(&conn, workspace_id, worktree).await?)
    }

    /// Starts an agent of `kind` (e.g. `claude`) in a pane at its shell
    /// prompt and returns the agent's name. Without `name` it is named
    /// after its kind, numbered when taken. Returns once herdr has typed
    /// the command; the agent's state follows in the session updates.
    pub async fn start_agent(
        &self,
        pane_id: &str,
        kind: &str,
        name: Option<&str>,
    ) -> Result<String, SessionError> {
        let conn = self.connection()?;
        Ok(actions::start_agent(&conn, pane_id, kind, name).await?.name)
    }

    /// Agent kinds the server can start, the usual ones first. Never fails:
    /// without an answer it returns the kinds herdr 0.9 knows.
    pub async fn agent_kinds(&self) -> Vec<String> {
        match self.connection() {
            Ok(conn) => actions::agent_kinds(&conn).await,
            Err(_) => actions::AGENT_KINDS
                .iter()
                .map(|k| (*k).to_string())
                .collect(),
        }
    }

    /// The newest part of the Claude Code conversation in a pane, read from
    /// the session file on the host (SFTP over SSH). With `before`, the part
    /// that ends there in that file: a page's `session_path` and `start`.
    /// Read only.
    pub async fn claude_history(
        &self,
        pane_id: &str,
        before: Option<TranscriptCursor>,
    ) -> Result<TranscriptPage, SessionError> {
        let conn = self.connection()?;
        let (session, end) = match before {
            Some(cursor) => (
                claude::Session {
                    path: cursor.session_path,
                    size: cursor.start,
                },
                cursor.start,
            ),
            None => {
                let session = claude::find_session(&conn, pane_id).await?;
                let end = session.size;
                (session, end)
            }
        };
        let page = claude::read_back(&conn, &session, end).await?;
        Ok(TranscriptPage {
            session_path: session.path,
            entries: page.entries.into_iter().map(Into::into).collect(),
            start: page.start,
        })
    }

    /// The transcript of a full-screen agent such as Claude Code, which
    /// herdr keeps no scrollback for: up to `pane::MAX_HISTORY_LINES` rows
    /// as plain text, the screen included. herdr scrolls the agent's view
    /// on the host through it and back down, so this is more than a read;
    /// it fails with [`SessionError::AgentWorking`] unless the agent is
    /// idle. Takes a moment.
    pub async fn agent_history(&self, pane_id: &str) -> Result<PaneContent, SessionError> {
        let conn = self.connection()?;
        let screen = fullscreen::read_history(&conn, pane_id).await?;
        Ok(view::pane_content(&screen))
    }

    /// Scrolls the view of a full-screen agent, also while it works. Moves
    /// the view in herdr's own client on the host too; end with
    /// [`ScrollStep::Bottom`].
    pub async fn scroll_agent(&self, pane_id: &str, step: ScrollStep) -> Result<(), SessionError> {
        let conn = self.connection()?;
        Ok(fullscreen::scroll(&conn, pane_id, step.into()).await?)
    }

    /// Renames a space.
    pub async fn rename_workspace(
        &self,
        workspace_id: &str,
        label: &str,
    ) -> Result<(), SessionError> {
        let conn = self.connection()?;
        Ok(actions::rename_workspace(&conn, workspace_id, label).await?)
    }

    /// Renames a tab.
    pub async fn rename_tab(&self, tab_id: &str, label: &str) -> Result<(), SessionError> {
        let conn = self.connection()?;
        Ok(actions::rename_tab(&conn, tab_id, label).await?)
    }

    /// Closes a tab and what runs in it.
    pub async fn close_tab(&self, tab_id: &str) -> Result<(), SessionError> {
        let conn = self.connection()?;
        Ok(actions::close_tab(&conn, tab_id).await?)
    }

    /// Closes a space with all its tabs; `with_worktrees` also closes the
    /// linked worktree spaces of a repository's space, which herdr requires
    /// when there are any.
    pub async fn close_workspace(
        &self,
        workspace_id: &str,
        with_worktrees: bool,
    ) -> Result<(), SessionError> {
        let conn = self.connection()?;
        Ok(actions::close_workspace(&conn, workspace_id, with_worktrees).await?)
    }

    /// Names the agent in a pane; `None` or an empty name removes the name.
    /// herdr does not announce names with an event, so a fresh snapshot
    /// follows.
    pub async fn rename_agent(
        &self,
        pane_id: &str,
        name: Option<&str>,
    ) -> Result<(), SessionError> {
        let conn = self.connection()?;
        actions::rename_agent(&conn, pane_id, name).await?;
        if let Ok(state) = self.state.lock()
            && let Some(rx) = state.as_ref()
        {
            rx.borrow().request_snapshot();
        }
        Ok(())
    }

    /// Lets another device of the user (an Apple TV, #127) in: adds the
    /// restricted line for `public_openssh` (no shell, no files, only the
    /// herdr socket) with `comment` to `~/.ssh/authorized_keys` on the host.
    /// Returns false when the key was there already. Needs SFTP.
    pub async fn authorize_device_key(
        &self,
        public_openssh: &str,
        comment: &str,
    ) -> Result<bool, SessionError> {
        // Options, key type and key, without the key's own comment: the
        // line ends with one comment naming the device.
        let key = keys::parse_public(public_openssh.trim()).map_err(key_error)?;
        let typed = key
            .to_openssh()
            .map_err(|err| SessionError::Key(err.to_string()))?;
        let mut fields = typed.split_whitespace();
        let (Some(kind), Some(blob)) = (fields.next(), fields.next()) else {
            return Err(SessionError::Key("no key in line".into()));
        };
        let base = format!("{} {kind} {blob}", gate_options(false, None)?);
        let comment: String = comment
            .chars()
            .map(|ch| {
                if ch.is_alphanumeric() || matches!(ch, '-' | '_' | '.') {
                    ch
                } else {
                    '-'
                }
            })
            .collect();
        let line = format!("{base} amiscara-agents-{comment}");
        let conn = self.connection()?;
        conn.add_authorized_key(&line, blob)
            .await
            .map_err(upload_error)
    }

    /// Uploads any file to `~/.amiscara-agents/uploads` under its own name,
    /// made unique and safe (`file-<time>-<name>`), and returns the absolute
    /// path. The name helps the agent tell what the file is.
    pub async fn upload_named_file(
        &self,
        data: &[u8],
        file_name: &str,
    ) -> Result<String, SessionError> {
        let conn = self.connection()?;
        let name = named_upload(file_name);
        conn.upload(UPLOAD_DIR, &name, data)
            .await
            .map_err(upload_error)
    }

    /// Uploads a file (e.g. an image for a prompt) to `~/.amiscara-agents/uploads`
    /// on the host under a fresh name and returns its absolute path.
    pub async fn upload_file(
        &self,
        data: &[u8],
        file_extension: &str,
    ) -> Result<String, SessionError> {
        let ext = file_extension.trim_start_matches('.').to_ascii_lowercase();
        if ext.is_empty() || ext.len() > 5 || !ext.chars().all(|c| c.is_ascii_alphanumeric()) {
            return Err(SessionError::Upload(format!(
                "invalid file extension {file_extension:?}"
            )));
        }
        let conn = self.connection()?;
        let name = upload_name(&ext);
        conn.upload(UPLOAD_DIR, &name, data)
            .await
            .map_err(upload_error)
    }

    /// Follows the screen of a pane until the returned handle is stopped or
    /// dropped. `live: false` reads the pane only every few seconds, for
    /// panes shown next to the selected one; see [`PaneFollow`] for
    /// changing the pace and showing scrollback.
    pub fn follow_pane(&self, pane_id: String, live: bool, sink: impl PaneSink) -> PaneFollow {
        let state = self.state.lock().ok().and_then(|state| state.clone());
        let (pacing_tx, pacing) = watch::channel(pacing_for(live));
        let (reading_tx, reading) = watch::channel(pane::Reading::default());
        let (stop_tx, mut stop) = watch::channel(false);
        self.runtime.spawn(async move {
            let Some(mut state) = state else {
                return;
            };
            loop {
                let connection = state.borrow_and_update().connection.clone();
                if let Some(conn) = connection
                    && let Err(message) = follow_once(
                        &conn,
                        &pane_id,
                        pacing.clone(),
                        reading.clone(),
                        stop.clone(),
                        &sink,
                    )
                    .await
                {
                    sink.on_error(message);
                }
                if *stop.borrow() {
                    return;
                }
                // Wait for a new connection, or retry after a pause on the same one.
                tokio::select! {
                    changed = state.changed() => if changed.is_err() { return },
                    () = tokio::time::sleep(Duration::from_secs(2)) => {}
                    _ = stop.wait_for(|stopped| *stopped) => return,
                }
            }
        });
        PaneFollow {
            stop: stop_tx,
            pacing: pacing_tx,
            reading: reading_tx,
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.forward.abort();
    }
}

fn pacing_for(live: bool) -> Pacing {
    if live {
        Pacing::default()
    } else {
        Pacing::background()
    }
}

async fn follow_once(
    conn: &Connection,
    pane_id: &str,
    pacing: watch::Receiver<Pacing>,
    reading: watch::Receiver<pane::Reading>,
    mut stop: watch::Receiver<bool>,
    sink: &impl PaneSink,
) -> Result<(), String> {
    let (tx, mut rx) = watch::channel(None);
    let follow = pane::follow_with_history(conn, pane_id, pacing, reading, &tx);
    tokio::pin!(follow);
    // Owns `rx`: when it ends, the follower sees nobody watching and returns
    // at its next pause.
    let forward = async move {
        loop {
            tokio::select! {
                changed = rx.changed() => {
                    if changed.is_err() {
                        return;
                    }
                    let screen = rx.borrow_and_update().clone();
                    if let Some(screen) = screen {
                        sink.on_content(view::pane_content(&screen));
                    }
                }
                _ = stop.wait_for(|stopped| *stopped) => return,
            }
        }
    };
    tokio::select! {
        result = &mut follow => return result.map_err(|err| err.to_string()),
        () = forward => {}
    }
    // Stopped. Let a request in flight finish instead of dropping it: an
    // SSH request dropped half way left the session unable to open new
    // channels, so every later read hung (#107).
    let _ = tokio::time::timeout(STOP_GRACE, follow).await;
    Ok(())
}

/// How long a stopped pane follower may take to finish its request.
const STOP_GRACE: Duration = Duration::from_secs(10);

/// Handle for [`Session::follow_pane`].
pub struct PaneFollow {
    stop: watch::Sender<bool>,
    pacing: watch::Sender<Pacing>,
    reading: watch::Sender<pane::Reading>,
}

impl PaneFollow {
    /// Ends following once a request in flight has finished; no content is
    /// reported after this.
    pub fn stop(&self) {
        self.stop.send_replace(true);
    }

    /// Switches between the fast pace of the selected pane and the slow one
    /// of a pane beside it. Switching reads the pane once right away.
    pub fn set_live(&self, live: bool) {
        let pacing = pacing_for(live);
        self.pacing.send_if_modified(|current| {
            let changed = *current != pacing;
            *current = pacing;
            changed
        });
    }

    /// Shows the last `lines` rows including scrollback instead of only the
    /// visible screen; 0 goes back to the screen. Capped at
    /// `herdr_core::pane::MAX_HISTORY_LINES`. Content with the new value
    /// follows at once.
    pub fn set_history_lines(&self, lines: u32) {
        let lines = lines.min(pane::MAX_HISTORY_LINES);
        self.reading
            .send_modify(|reading| reading.history_lines = lines);
    }

    /// Joins the rows the terminal wrapped at the pane width into whole
    /// lines, for a client that wraps them at its own width (#191). Content
    /// with the new value follows at once.
    pub fn set_unwrap(&self, unwrap: bool) {
        self.reading.send_if_modified(|reading| {
            let changed = reading.unwrap != unwrap;
            reading.unwrap = unwrap;
            changed
        });
    }
}

impl Drop for PaneFollow {
    fn drop(&mut self) {
        self.stop.send_replace(true);
    }
}

/// Everything needed to (re)connect, checked once up front.
#[derive(Clone)]
enum Connector {
    #[cfg(unix)]
    Local(std::path::PathBuf),
    Ssh {
        target: SshTarget,
        socket: String,
    },
}

impl Connector {
    fn new(endpoint: Endpoint) -> Result<Self, SessionError> {
        match endpoint {
            #[cfg(unix)]
            Endpoint::Local { socket_path } => {
                let path = match socket_path {
                    Some(path) => std::path::PathBuf::from(path),
                    None => Connection::default_local_socket().ok_or_else(|| {
                        SessionError::Unsupported("no home directory for the local socket".into())
                    })?,
                };
                Ok(Self::Local(path))
            }
            #[cfg(not(unix))]
            Endpoint::Local { .. } => Err(SessionError::Unsupported(
                "a local herdr socket needs a Unix system".into(),
            )),
            Endpoint::Ssh {
                host,
                port,
                user,
                identity,
                pinned_host_key,
                socket_path,
            } => {
                let identity = match identity {
                    SshIdentity::Key(text) => {
                        Identity::Key(Arc::new(keys::parse_private(&text).map_err(key_error)?))
                    }
                    SshIdentity::Agent => Identity::Agent,
                };
                Ok(Self::Ssh {
                    target: SshTarget {
                        host,
                        port,
                        user,
                        identity,
                        host_key: HostKeyPolicy::Pinned(pinned_host_key),
                    },
                    socket: socket_path,
                })
            }
        }
    }

    async fn connect(&self) -> Result<Connection, TransportError> {
        match self {
            #[cfg(unix)]
            Self::Local(path) => Ok(Connection::local(path.clone())),
            Self::Ssh { target, socket } => Connection::ssh(target, socket.clone()).await,
        }
    }
}

/// `file-<secs>-<nanos>-<name>`. The name keeps only letters, digits, `.`,
/// `_` and `-` (everything else becomes `_`), so the path the app appends
/// to a prompt or shell command carries no whitespace or shell characters;
/// no leading dots, at most 120 characters (the end, with the extension).
fn named_upload(file_name: &str) -> String {
    let cleaned: String = file_name
        .trim()
        .chars()
        .map(|ch| {
            if ch.is_alphanumeric() || matches!(ch, '.' | '_' | '-') {
                ch
            } else {
                '_'
            }
        })
        .collect();
    let cleaned = cleaned.trim_start_matches('.');
    let chars: Vec<char> = cleaned.chars().collect();
    let name: String = if chars.len() > 120 {
        chars[chars.len() - 120..].iter().collect()
    } else {
        cleaned.to_owned()
    };
    let name = if name.is_empty() {
        "datei".to_owned()
    } else {
        name
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    format!("file-{}-{:09}-{name}", now.as_secs(), now.subsec_nanos())
}

/// `img-<unix seconds>-<nanos>.<ext>` for images, `file-…` for anything
/// else: sortable, unique enough for one device uploading by hand, and a
/// listing of the upload folder says what is what.
fn upload_name(ext: &str) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let image = matches!(
        ext,
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "heic" | "tif" | "tiff"
    );
    let prefix = if image { "img" } else { "file" };
    format!("{prefix}-{}-{:09}.{ext}", now.as_secs(), now.subsec_nanos())
}

#[cfg(test)]
mod tests {
    use super::named_upload;

    #[test]
    fn named_uploads_are_safe_and_keep_the_name() {
        let name = named_upload("Rechnung März.xlsx");
        assert!(
            name.starts_with("file-") && name.ends_with("-Rechnung_März.xlsx"),
            "{name}"
        );
        let name = named_upload("x;rm -rf ~ $(id) `id` 'a'\"b\".txt");
        assert!(
            name.chars()
                .all(|ch| ch.is_alphanumeric() || matches!(ch, '.' | '_' | '-')),
            "{name}"
        );
        let name = named_upload("../../.ssh/authorized_keys");
        assert!(
            !name.contains('/') && name.ends_with("-_.._.ssh_authorized_keys"),
            "{name}"
        );
        assert!(named_upload(".hidden").ends_with("-hidden"));
        assert!(named_upload("  ").ends_with("-datei"));
        let long = format!("{}.textClipping", "x".repeat(200));
        let name = named_upload(&long);
        assert!(
            name.ends_with(".textClipping") && name.len() < 160,
            "{name}"
        );
    }
}
