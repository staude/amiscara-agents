//! Swift (and later Kotlin) face of the Amiscara Agents core, via UniFFI.
//!
//! The apps start one [`HostSession`] per host and get every state change
//! through a [`SessionObserver`]; an open pane is followed with
//! [`HostSession::follow_pane`]. Callbacks arrive on a background thread,
//! the app hops to its UI thread itself. Keys live in the app (Keychain) and
//! are handed over as OpenSSH text.

mod add_host;
mod convert;

use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use herdr_core::pane::{self, Pacing};
use herdr_core::sync::{self, SyncState};
use herdr_core::{actions, claude};
use herdr_transport::{Connection, HostKeyPolicy, Identity, SshTarget, TransportError, keys};
use tokio::runtime::Runtime;
use tokio::sync::watch;
use tokio::task::JoinHandle;

pub use add_host::{
    ADD_HOST_PREFIX, ADD_HOST_VERSION, AddHostLink, decode_add_host_link, encode_add_host_link,
    public_key_fingerprint,
};
pub use convert::{
    AgentState, BoardItem, HostStatus, PaneContent, PaneFrame, PaneItem, SessionUpdate, SpaceSlot,
    SplitLayout, StyledLine, StyledSpan, TabItem, TermColor, TokenItem, WorkspaceItem,
};

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum FfiError {
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
    /// A scanned or opened "add host" link was refused; the message is
    /// German and meant for the user as is.
    #[error("{0}")]
    InvalidLink(String),
    /// Files on the host could not be read: no SFTP for this key, or no
    /// Claude Code session for the pane.
    #[error("{0}")]
    Files(String),
}

impl From<claude::ClaudeError> for FfiError {
    fn from(err: claude::ClaudeError) -> Self {
        match err {
            claude::ClaudeError::Transport(TransportError::Files(message)) => Self::Files(message),
            claude::ClaudeError::Transport(other) => Self::NotConnected(other.to_string()),
            other => Self::Files(other.to_string()),
        }
    }
}

/// Who wrote an entry of a Claude Code conversation.
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum TranscriptKind {
    User,
    Assistant,
    Tool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TranscriptEntry {
    pub kind: TranscriptKind,
    pub text: String,
    /// ISO 8601, as Claude Code wrote it.
    pub timestamp: Option<String>,
}

/// Where to continue a conversation backwards, from a [`TranscriptPage`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct TranscriptCursor {
    pub session_path: String,
    pub start: u64,
}

/// Part of a Claude Code conversation, oldest entry first.
#[derive(Debug, Clone, uniffi::Record)]
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

impl From<actions::ActionError> for FfiError {
    fn from(err: actions::ActionError) -> Self {
        match err {
            actions::ActionError::AgentBlocked => Self::AgentBlocked(err.to_string()),
            actions::ActionError::Rejected { .. } => Self::Rejected(err.to_string()),
            actions::ActionError::Transport(_) => Self::NotConnected(err.to_string()),
        }
    }
}

/// Where a herdr server lives.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum Endpoint {
    /// The Unix socket on this machine. `None` uses `~/.config/herdr/herdr.sock`.
    Local { socket_path: Option<String> },
    /// A remote server over SSH streamlocal.
    Ssh {
        host: String,
        port: u16,
        user: String,
        /// Unencrypted OpenSSH private key, e.g. from the Keychain.
        private_key_openssh: String,
        /// Trusted host key as an OpenSSH public key line. `None` on first
        /// contact: the session then reports `HostStatus::HostKeyUnknown`.
        pinned_host_key: Option<String>,
        /// Absolute path of `herdr.sock` on the server.
        socket_path: String,
    },
}

/// A key pair in OpenSSH text form.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SshKey {
    pub private_openssh: String,
    /// `ssh-ed25519 AAAA... comment`
    pub public_openssh: String,
    /// `SHA256:...`
    pub fingerprint: String,
}

impl From<keys::GeneratedKey> for SshKey {
    fn from(key: keys::GeneratedKey) -> Self {
        Self {
            private_openssh: key.private_openssh,
            public_openssh: key.public_openssh,
            fingerprint: key.fingerprint,
        }
    }
}

#[uniffi::export]
pub fn generate_ssh_key(comment: String) -> Result<SshKey, FfiError> {
    Ok(keys::generate_ed25519(&comment).map_err(key_error)?.into())
}

/// Public half and fingerprint of a stored private key.
#[uniffi::export]
pub fn describe_ssh_key(private_openssh: String) -> Result<SshKey, FfiError> {
    let key = keys::parse_private(&private_openssh).map_err(key_error)?;
    Ok(keys::describe(&key).map_err(key_error)?.into())
}

/// The `authorized_keys` line for a client key. Without SFTP: no shell, no
/// commands, no PTY, no agent or X11 forwarding. With SFTP every session runs
/// `sftp-server` instead of failing, which allows uploads but also gives the
/// key read and write access to all files of the user.
///
/// `port-forwarding` is needed for the streamlocal channel to `herdr.sock`,
/// but it also allows TCP forwarding through the server. `permitopen` cannot
/// narrow that: sshd applies it to streamlocal as well and then refuses the
/// socket (tested with OpenSSH 10.3). Closing TCP forwarding needs
/// `AllowTcpForwarding no` in `sshd_config`, which affects every login.
#[uniffi::export]
pub fn authorized_keys_line(public_openssh: String, allow_sftp: bool) -> Result<String, FfiError> {
    let key = keys::parse_public(public_openssh.trim()).map_err(key_error)?;
    let line = key
        .to_openssh()
        .map_err(|err| FfiError::Key(err.to_string()))?;
    let command = if allow_sftp {
        "/usr/libexec/sftp-server"
    } else {
        "/usr/bin/false"
    };
    Ok(format!(
        "restrict,port-forwarding,command=\"{command}\" {line}"
    ))
}

/// A new space or tab: its first pane.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Created {
    pub workspace_id: String,
    pub tab_id: String,
    pub pane_id: String,
}

impl From<actions::Created> for Created {
    fn from(created: actions::Created) -> Self {
        Self {
            workspace_id: created.workspace_id,
            tab_id: created.tab_id,
            pane_id: created.pane_id,
        }
    }
}

/// A worktree to create; empty fields are left to herdr (see
/// `herdr_core::actions::NewWorktree`).
#[derive(Debug, Clone, uniffi::Record)]
pub struct NewWorktree {
    pub branch: Option<String>,
    pub base: Option<String>,
    pub label: Option<String>,
    /// Absolute checkout path; `None` uses herdr's worktree directory.
    pub path: Option<String>,
}

impl From<NewWorktree> for actions::NewWorktree {
    fn from(new: NewWorktree) -> Self {
        Self {
            branch: new.branch,
            base: new.base,
            label: new.label,
            path: new.path,
        }
    }
}

/// Where uploads land, relative to the login's home directory.
pub const UPLOAD_DIR: &str = ".amiscara-agents/uploads";

/// Default `herdr.sock` path for a user on a macOS host.
#[uniffi::export]
pub fn default_remote_socket(user: String) -> String {
    format!("/Users/{user}/.config/herdr/herdr.sock")
}

#[uniffi::export]
pub fn supported_protocol() -> u32 {
    herdr_proto::SUPPORTED_PROTOCOL
}

/// Most history rows herdr returns for one pane read.
#[uniffi::export]
pub fn max_history_lines() -> u32 {
    pane::MAX_HISTORY_LINES
}

#[uniffi::export(callback_interface)]
pub trait SessionObserver: Send + Sync {
    fn on_update(&self, update: SessionUpdate);
}

#[uniffi::export(callback_interface)]
pub trait PaneObserver: Send + Sync {
    fn on_content(&self, content: PaneContent);
    /// The pane could not be read, e.g. because it was closed or the
    /// connection dropped. Following continues once a connection is back.
    fn on_error(&self, message: String);
}

/// One live host: keeps the session state current until stopped or dropped.
#[derive(uniffi::Object)]
pub struct HostSession {
    state: Mutex<Option<watch::Receiver<SyncState>>>,
    /// Whether spaces are grouped by their "Bereich/Name" labels. A change
    /// rebuilds the last update, so the app needs no reconnect.
    group_by_name: watch::Sender<bool>,
    forward: JoinHandle<()>,
}

#[uniffi::export]
impl HostSession {
    /// Connects in the background and reports to `observer` from then on.
    /// `group_spaces_by_name` is the host's setting for the "Bereich/Name"
    /// convention (see `herdr_core::spaces`).
    #[uniffi::constructor(default(group_spaces_by_name = true))]
    pub fn start(
        endpoint: Endpoint,
        observer: Box<dyn SessionObserver>,
        group_spaces_by_name: bool,
    ) -> Result<Arc<Self>, FfiError> {
        let connector = Connector::new(endpoint)?;
        let runtime = runtime();
        let _entered = runtime.enter();
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
                let update = convert::session_update(&state, previous.as_deref(), by_name);
                if state.session.is_some() {
                    previous = state.session.clone();
                }
                observer.on_update(update);
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
        Ok(Arc::new(Self {
            state: Mutex::new(Some(rx)),
            group_by_name,
            forward,
        }))
    }

    /// Switches grouping by "Bereich/Name" on or off; the observer gets a
    /// rebuilt update right away, without reconnecting.
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

    /// Sends a prompt to the agent in a pane, followed by Enter. Blocks for
    /// one round trip; call it off the main thread.
    pub fn send_prompt(&self, pane_id: String, text: String) -> Result<(), FfiError> {
        let conn = self.connection()?;
        runtime().block_on(actions::send_prompt(&conn, &pane_id, &text))?;
        Ok(())
    }

    /// Sends logical keys (`enter`, `esc`, `1`, `ctrl+c`, ...) to a pane.
    /// Blocks for one round trip; call it off the main thread.
    pub fn send_keys(&self, pane_id: String, keys: Vec<String>) -> Result<(), FfiError> {
        let conn = self.connection()?;
        runtime().block_on(actions::send_keys(&conn, &pane_id, &keys))?;
        Ok(())
    }

    /// Types text into a pane without Enter. Blocks for one round trip.
    pub fn send_text(&self, pane_id: String, text: String) -> Result<(), FfiError> {
        let conn = self.connection()?;
        runtime().block_on(actions::send_text(&conn, &pane_id, &text))?;
        Ok(())
    }

    /// Creates a space with a shell in `cwd` (absolute path) and returns
    /// its first pane. Not focused in herdr's own client.
    pub fn create_workspace(
        &self,
        label: Option<String>,
        cwd: String,
    ) -> Result<Created, FfiError> {
        let conn = self.connection()?;
        Ok(runtime()
            .block_on(actions::create_workspace(&conn, label.as_deref(), &cwd))?
            .into())
    }

    /// Creates a tab in a space and returns its first pane.
    pub fn create_tab(
        &self,
        workspace_id: String,
        cwd: Option<String>,
    ) -> Result<Created, FfiError> {
        let conn = self.connection()?;
        Ok(runtime()
            .block_on(actions::create_tab(&conn, &workspace_id, cwd.as_deref()))?
            .into())
    }

    /// Creates a Git worktree from the repository of space `workspace_id`
    /// and opens it as a new space; returns its first pane. Blocks until
    /// `git worktree add` is done; call it off the main thread.
    pub fn create_worktree(
        &self,
        workspace_id: String,
        worktree: NewWorktree,
    ) -> Result<Created, FfiError> {
        let conn = self.connection()?;
        Ok(runtime()
            .block_on(actions::create_worktree(
                &conn,
                &workspace_id,
                &worktree.into(),
            ))?
            .into())
    }

    /// Starts an agent of `kind` (e.g. `claude`) in a pane at its shell
    /// prompt and returns the agent's name. Without `name` it is named
    /// after its kind, numbered when taken. Returns once herdr has typed
    /// the command; the agent's state follows in the session updates.
    pub fn start_agent(
        &self,
        pane_id: String,
        kind: String,
        name: Option<String>,
    ) -> Result<String, FfiError> {
        let conn = self.connection()?;
        Ok(runtime()
            .block_on(actions::start_agent(
                &conn,
                &pane_id,
                &kind,
                name.as_deref(),
            ))?
            .name)
    }

    /// Agent kinds the server can start, the usual ones first. Never fails:
    /// without an answer it returns the kinds herdr 0.9 knows.
    pub fn agent_kinds(&self) -> Vec<String> {
        match self.connection() {
            Ok(conn) => runtime().block_on(actions::agent_kinds(&conn)),
            Err(_) => actions::AGENT_KINDS
                .iter()
                .map(|k| (*k).to_string())
                .collect(),
        }
    }

    /// The newest part of the Claude Code conversation in a pane, read from
    /// the session file on the host (SFTP over SSH). With `before`, the part
    /// that ends there in that file: a page's `session_path` and `start`.
    /// Read only. Blocks for several round trips; call it off the main thread.
    pub fn claude_history(
        &self,
        pane_id: String,
        before: Option<TranscriptCursor>,
    ) -> Result<TranscriptPage, FfiError> {
        let conn = self.connection()?;
        runtime().block_on(async {
            let (session, end) = match before {
                Some(cursor) => (
                    claude::Session {
                        path: cursor.session_path,
                        size: cursor.start,
                    },
                    cursor.start,
                ),
                None => {
                    let session = claude::find_session(&conn, &pane_id).await?;
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
        })
    }

    /// Renames a space. Blocks for one round trip.
    pub fn rename_workspace(&self, workspace_id: String, label: String) -> Result<(), FfiError> {
        let conn = self.connection()?;
        runtime().block_on(actions::rename_workspace(&conn, &workspace_id, &label))?;
        Ok(())
    }

    /// Renames a tab. Blocks for one round trip.
    pub fn rename_tab(&self, tab_id: String, label: String) -> Result<(), FfiError> {
        let conn = self.connection()?;
        runtime().block_on(actions::rename_tab(&conn, &tab_id, &label))?;
        Ok(())
    }

    /// Closes a tab and what runs in it. Blocks for one round trip.
    pub fn close_tab(&self, tab_id: String) -> Result<(), FfiError> {
        let conn = self.connection()?;
        runtime().block_on(actions::close_tab(&conn, &tab_id))?;
        Ok(())
    }

    /// Closes a space with all its tabs; `with_worktrees` also closes the
    /// linked worktree spaces of a repository's space, which herdr requires
    /// when there are any. Blocks for one round trip.
    pub fn close_workspace(
        &self,
        workspace_id: String,
        with_worktrees: bool,
    ) -> Result<(), FfiError> {
        let conn = self.connection()?;
        runtime().block_on(actions::close_workspace(
            &conn,
            &workspace_id,
            with_worktrees,
        ))?;
        Ok(())
    }

    /// Names the agent in a pane; `None` or an empty name removes the name.
    /// herdr does not announce names with an event, so a fresh snapshot
    /// follows. Blocks for one round trip.
    pub fn rename_agent(&self, pane_id: String, name: Option<String>) -> Result<(), FfiError> {
        let conn = self.connection()?;
        runtime().block_on(actions::rename_agent(&conn, &pane_id, name.as_deref()))?;
        if let Ok(state) = self.state.lock()
            && let Some(rx) = state.as_ref()
        {
            rx.borrow().request_snapshot();
        }
        Ok(())
    }

    /// Uploads any file to `~/.amiscara-agents/uploads` under its own name,
    /// made unique and safe (`file-<time>-<name>`), and returns the absolute
    /// path. The name helps the agent tell what the file is.
    pub fn upload_named_file(&self, data: Vec<u8>, file_name: String) -> Result<String, FfiError> {
        let conn = self.connection()?;
        let name = named_upload(&file_name);
        runtime()
            .block_on(conn.upload(UPLOAD_DIR, &name, &data))
            .map_err(|err| match err {
                TransportError::Upload(message) => FfiError::Upload(message),
                other => FfiError::NotConnected(other.to_string()),
            })
    }

    /// Uploads a file (e.g. an image for a prompt) to `~/.amiscara-agents/uploads`
    /// on the host under a fresh name and returns its absolute path. Blocks
    /// until the upload is done; call it off the main thread.
    pub fn upload_file(&self, data: Vec<u8>, file_extension: String) -> Result<String, FfiError> {
        let ext = file_extension.trim_start_matches('.').to_ascii_lowercase();
        if ext.is_empty() || ext.len() > 5 || !ext.chars().all(|c| c.is_ascii_alphanumeric()) {
            return Err(FfiError::Upload(format!(
                "invalid file extension {file_extension:?}"
            )));
        }
        let conn = self.connection()?;
        let name = upload_name(&ext);
        runtime()
            .block_on(conn.upload(UPLOAD_DIR, &name, &data))
            .map_err(|err| match err {
                TransportError::Upload(message) => FfiError::Upload(message),
                other => FfiError::NotConnected(other.to_string()),
            })
    }

    /// Follows the visible screen of a pane until the returned handle is
    /// stopped or dropped. [`PaneFollow::set_history_lines`] switches to
    /// the screen plus scrollback.
    pub fn follow_pane(&self, pane_id: String, observer: Box<dyn PaneObserver>) -> Arc<PaneFollow> {
        self.follow_pane_paced(pane_id, true, observer)
    }

    /// Like `follow_pane`; `live: false` reads the pane only every few
    /// seconds, for panes shown next to the selected one. The pace can be
    /// changed later with [`PaneFollow::set_live`].
    pub fn follow_pane_paced(
        &self,
        pane_id: String,
        live: bool,
        observer: Box<dyn PaneObserver>,
    ) -> Arc<PaneFollow> {
        let state = self.state.lock().ok().and_then(|state| state.clone());
        let (pacing_tx, pacing) = watch::channel(pacing_for(live));
        let (history_tx, history) = watch::channel(0);
        let (stop_tx, mut stop) = watch::channel(false);
        runtime().spawn(async move {
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
                        history.clone(),
                        stop.clone(),
                        observer.as_ref(),
                    )
                    .await
                {
                    observer.on_error(message);
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
        Arc::new(PaneFollow {
            stop: stop_tx,
            pacing: pacing_tx,
            history: history_tx,
        })
    }
}

impl HostSession {
    fn connection(&self) -> Result<Arc<Connection>, FfiError> {
        self.state
            .lock()
            .ok()
            .and_then(|state| state.as_ref().and_then(|rx| rx.borrow().connection.clone()))
            .ok_or_else(|| FfiError::NotConnected("not connected to herdr".into()))
    }
}

impl Drop for HostSession {
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
    history: watch::Receiver<u32>,
    mut stop: watch::Receiver<bool>,
    observer: &dyn PaneObserver,
) -> Result<(), String> {
    let (tx, mut rx) = watch::channel(None);
    let follow = pane::follow_with_history(conn, pane_id, pacing, history, &tx);
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
                        observer.on_content(convert::pane_content(&screen));
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

/// Handle for [`HostSession::follow_pane`].
#[derive(uniffi::Object)]
pub struct PaneFollow {
    stop: watch::Sender<bool>,
    pacing: watch::Sender<Pacing>,
    history: watch::Sender<u32>,
}

#[uniffi::export]
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
    /// [`max_history_lines`]. Content with the new value follows at once.
    pub fn set_history_lines(&self, lines: u32) {
        self.history
            .send_replace(lines.min(pane::MAX_HISTORY_LINES));
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
    fn new(endpoint: Endpoint) -> Result<Self, FfiError> {
        match endpoint {
            #[cfg(unix)]
            Endpoint::Local { socket_path } => {
                let path = match socket_path {
                    Some(path) => std::path::PathBuf::from(path),
                    None => Connection::default_local_socket().ok_or_else(|| {
                        FfiError::Unsupported("no home directory for the local socket".into())
                    })?,
                };
                Ok(Self::Local(path))
            }
            #[cfg(not(unix))]
            Endpoint::Local { .. } => Err(FfiError::Unsupported(
                "a local herdr socket needs a Unix system".into(),
            )),
            Endpoint::Ssh {
                host,
                port,
                user,
                private_key_openssh,
                pinned_host_key,
                socket_path,
            } => {
                let key = keys::parse_private(&private_key_openssh).map_err(key_error)?;
                Ok(Self::Ssh {
                    target: SshTarget {
                        host,
                        port,
                        user,
                        identity: Identity::Key(Arc::new(key)),
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

fn key_error(err: TransportError) -> FfiError {
    FfiError::Key(err.to_string())
}

fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("herdr-core")
            .enable_all()
            .build()
            .unwrap_or_else(|err| panic!("cannot start the tokio runtime: {err}"))
    })
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
