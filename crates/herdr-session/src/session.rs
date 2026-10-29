//! One live host: connection with reconnects, updates for the view, pane
//! followers, actions, uploads and the Claude Code history.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use herdr_core::chains::{self, Chain};
use herdr_core::pane::{self, Pacing};
use herdr_core::spaces::SpaceSort;
use herdr_core::sync::{self, SyncState, SyncStatus};
use herdr_core::{actions, browse, claude, diff, fullscreen, github};
use herdr_proto::{AgentGetResult, AgentStatus, PaneGetResult};
use herdr_transport::{
    Connection, HerdrSessionEntry, HostKeyPolicy, Identity, SshTarget, TransportError, keys,
};
use tokio::runtime::Handle;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;

use crate::access::{gate_options, key_error};
use crate::forward::{self, Forwards};
use crate::secrets;
use crate::view::{
    self, ChainOutcome, ChainResult, ChainTrigger, ChoiceQuestion, PaneContent, SessionUpdate,
};

/// Where uploads land, relative to the login's home directory.
pub const UPLOAD_DIR: &str = ".amiscara-agents/uploads";

/// The metadata source the apps mark opened requests under (#247); the
/// host's browser stand-in reports them as `amiscara-agents`.
const OPEN_DONE_SOURCE: &str = "amiscara-agents-done";
/// How long a request lives, as in `scripts/host/amiscara-open`.
const OPEN_TTL_MS: u64 = 120_000;
/// The same for folders the host's `code` stand-in offers (#288), which
/// reports them as `amiscara-agents-editor` and opens VS Code on the host
/// once the request ran out unmarked.
const EDITOR_DONE_SOURCE: &str = "amiscara-agents-editor-done";
const EDITOR_TTL_MS: u64 = 30_000;
/// How long a device's claim on one run of a chain stays (#300): herdr's
/// longest time to live, so a late device still finds it.
const CHAIN_CLAIM_TTL_MS: u64 = 86_400_000;

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
    /// The host does not forward its `localhost` for this key: the key's
    /// `authorized_keys` line predates web forwarding (#247) and needs to
    /// be renewed, or sshd forbids TCP forwarding.
    #[error("{0}")]
    Forward(String),
    /// A file was not saved: it changed on the host since it was opened
    /// (#271).
    #[error("{0}")]
    FileChanged(String),
    /// A file was saved but could not be read back (#271): the copy on the
    /// device is out of date, reload it.
    #[error("{0}")]
    SavedNotRead(String),
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

fn files_error(err: TransportError) -> SessionError {
    match err {
        TransportError::Files(message) if message.ends_with(herdr_transport::CHANGED_ON_HOST) => {
            SessionError::FileChanged(message)
        }
        TransportError::Files(message) if message.starts_with(browse::SAVED_NOT_READ) => {
            SessionError::SavedNotRead(message)
        }
        TransportError::Files(message) => SessionError::Files(message),
        other => SessionError::NotConnected(other.to_string()),
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
    /// How spaces are sorted in the sidebar; a change rebuilds the same way.
    space_sort: watch::Sender<SpaceSort>,
    /// This device's id when it runs chains (#300), see
    /// [`Session::set_chain_runner`].
    chain_runner: watch::Sender<Option<String>>,
    forward: JoinHandle<()>,
    /// Over SSH: pages on the host's `localhost` need forwarding, and open
    /// requests are reported (a local host opens them itself).
    remote: bool,
    /// Listeners for pages on the host's `localhost`, see [`Session::open_url`].
    forwards: Forwards,
    runtime: Handle,
}

impl Session {
    /// Connects in the background and calls `on_update` with every state
    /// change from then on, on a runtime thread. `group_spaces_by_name` is
    /// the host's setting for the "Bereich/Name" convention, `space_sort`
    /// its order of spaces (see `herdr_core::spaces`). Call it inside a Tokio runtime; the session's
    /// tasks run there.
    pub fn start(
        endpoint: Endpoint,
        group_spaces_by_name: bool,
        space_sort: SpaceSort,
        on_update: impl Fn(SessionUpdate) + Send + 'static,
    ) -> Result<Self, SessionError> {
        let remote = matches!(endpoint, Endpoint::Ssh { .. });
        let connector = Connector::new(endpoint)?;
        let runtime = Handle::current();
        let rx = sync::spawn(move || {
            let connector = connector.clone();
            async move { connector.connect().await }
        });
        let mut updates = rx.clone();
        let (group_by_name, mut grouping) = watch::channel(group_spaces_by_name);
        let (space_sort, mut sorting) = watch::channel(space_sort);
        let (chain_runner, runner) = watch::channel(None);
        let forward = runtime.spawn(async move {
            // The state the last update was based on, to report what changed.
            let mut previous: Option<Arc<herdr_core::SessionState>> = None;
            // Since when each agent is in its state; kept across reconnects.
            let mut clock = view::StateClock::default();
            let (results_tx, mut results) = mpsc::unbounded_channel();
            // Chain runs finished since the last update.
            let mut ran = Vec::new();
            let claimed = Arc::new(Mutex::new(HashSet::new()));
            loop {
                let state = updates.borrow_and_update().clone();
                let by_name = *grouping.borrow_and_update();
                let sort = sorting.borrow_and_update().clone();
                let mut update =
                    view::session_update(&state, previous.as_deref(), by_name, &sort, remote);
                if let Some(now) = &state.session {
                    clock.stamp(&mut update.board, &mut update.attention, unix_ms());
                    let device = runner.borrow().clone();
                    if let (Some(device), Some(before), Some(conn)) =
                        (device, &previous, &state.connection)
                        && !Arc::ptr_eq(before, now)
                    {
                        let runs = ChainRuns {
                            conn: conn.clone(),
                            device,
                            state: now.clone(),
                            claimed: claimed.clone(),
                            results: results_tx.clone(),
                        };
                        runs.start(before);
                    }
                    previous = state.session.clone();
                }
                update.chain_results = std::mem::take(&mut ran);
                on_update(update);
                // A changed setting alone rebuilds the same state; its
                // attention is then empty, so nothing is notified twice.
                // A finished chain run does the same to report its result.
                tokio::select! {
                    changed = updates.changed() => {
                        if changed.is_err() {
                            return;
                        }
                    }
                    Ok(()) = grouping.changed() => {}
                    Ok(()) = sorting.changed() => {}
                    Some(result) = results.recv() => {
                        ran.push(result);
                        while let Ok(result) = results.try_recv() {
                            ran.push(result);
                        }
                    }
                }
            }
        });
        Ok(Self {
            state: Mutex::new(Some(rx)),
            group_by_name,
            space_sort,
            chain_runner,
            forward,
            remote,
            forwards: Forwards::default(),
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

    /// Changes the order of spaces; a rebuilt update follows right away,
    /// without reconnecting.
    pub fn set_space_sort(&self, sort: SpaceSort) {
        self.space_sort.send_if_modified(|current| {
            let changed = *current != sort;
            *current = sort;
            changed
        });
    }

    /// Lets this session run chains (#300) as the device `device_id`, or
    /// stops it with `None` (the default). Only one device sends per state
    /// change: the first to claim it on the host. A device that cannot
    /// send input to the host must not run them.
    pub fn set_chain_runner(&self, device_id: Option<String>) {
        let device_id = device_id.filter(|id| !id.trim().is_empty());
        self.chain_runner.send_if_modified(|current| {
            let changed = *current != device_id;
            *current = device_id;
            changed
        });
    }

    /// Adds a chain to the agent in `pane_id` (#300): when it reaches
    /// `trigger`, `text` goes as a prompt to the agent in `target_pane_id`,
    /// once or with `repeat` every time. Stored on the host, so every
    /// device shows it; returns its id. At most
    /// [`chains::MAX_CHAINS_PER_PANE`] per pane, the text one line of at most
    /// [`chains::MAX_CHAIN_TEXT`] characters, and a repeating chain must not
    /// prompt its own agent, or one that prompts this agent every time,
    /// which would keep them busy for good; nor can a chain on waiting,
    /// since a waiting agent refuses prompts.
    pub async fn set_chain(
        &self,
        pane_id: &str,
        trigger: ChainTrigger,
        repeat: bool,
        target_pane_id: &str,
        text: &str,
    ) -> Result<String, SessionError> {
        let text = chains::normalize_text(text).ok_or_else(|| {
            SessionError::Rejected(format!(
                "a chain's prompt needs 1 to {} characters without control characters",
                chains::MAX_CHAIN_TEXT
            ))
        })?;
        if repeat && target_pane_id == pane_id {
            return Err(SessionError::Rejected(
                "a repeating chain cannot prompt its own agent".into(),
            ));
        }
        // It waits at a dialog then, which refuses prompts.
        if trigger == ChainTrigger::Blocked && target_pane_id == pane_id {
            return Err(SessionError::Rejected(
                "a waiting agent takes no prompt; chain it to another agent".into(),
            ));
        }
        let session = self
            .session_state()
            .ok_or_else(|| SessionError::NotConnected("not connected to herdr".into()))?;
        let pane = session
            .pane(pane_id)
            .ok_or_else(|| SessionError::Rejected(format!("no pane {pane_id}")))?;
        if session.pane(target_pane_id).is_none() {
            return Err(SessionError::Rejected(format!(
                "no pane {target_pane_id} to prompt"
            )));
        }
        // Two repeating chains back and forth would prompt each other for
        // good.
        if repeat
            && session.pane(target_pane_id).is_some_and(|target| {
                chains::chains_of(target)
                    .iter()
                    .any(|back| back.repeat && !back.failed && back.target_pane_id == pane_id)
            })
        {
            return Err(SessionError::Rejected(
                "the target already prompts this agent every time; make one of them once".into(),
            ));
        }
        let existing = chains::chains_of(pane);
        if existing.len() >= chains::MAX_CHAINS_PER_PANE {
            return Err(SessionError::Rejected(format!(
                "an agent has at most {} chains",
                chains::MAX_CHAINS_PER_PANE
            )));
        }
        let chain = Chain {
            id: chains::new_chain_id(&existing),
            trigger: trigger.into(),
            repeat,
            failed: false,
            target_pane_id: target_pane_id.to_owned(),
            text,
        };
        let conn = self.connection()?;
        write_chain_tokens(&conn, pane_id, chains::chain_tokens(&chain))
            .await
            .map_err(|err| SessionError::from(actions::ActionError::from(err)))?;
        Ok(chain.id)
    }

    /// Removes a chain of the agent in `pane_id`; an unknown one is no
    /// error.
    pub async fn remove_chain(&self, pane_id: &str, chain_id: &str) -> Result<(), SessionError> {
        if !chains::is_chain_id(chain_id) {
            return Err(SessionError::Rejected(format!("no chain {chain_id:?}")));
        }
        let conn = self.connection()?;
        write_chain_tokens(&conn, pane_id, chains::clear_tokens(chain_id))
            .await
            .map_err(|err| SessionError::from(actions::ActionError::from(err)))?;
        // Its claim would otherwise take one of the pane's tokens for a day.
        let _ = conn
            .request(
                "pane.report_metadata",
                serde_json::json!({
                    "pane_id": pane_id,
                    "source": chains::claim_source(chain_id),
                    "tokens": { chains::claim_token(chain_id): null },
                }),
            )
            .await;
        Ok(())
    }

    /// The last known state of the server, if any.
    fn session_state(&self) -> Option<Arc<herdr_core::SessionState>> {
        self.state
            .lock()
            .ok()
            .and_then(|state| state.as_ref()?.borrow().session.clone())
    }

    /// Ends the session and closes the connection. Pane followers stop too.
    pub fn stop(&self) {
        self.forward.abort();
        self.forwards.stop();
        if let Ok(mut state) = self.state.lock() {
            state.take();
        }
    }

    /// Drops the connection and connects again at once, for a link that
    /// may have died while the device slept (#264). The known state and the
    /// pane followers stay; followers move to the new connection on their
    /// own, and the first update afterwards reports what changed in the
    /// meantime. Returns `false` when the session has stopped, after
    /// [`Session::stop`] or with a status a retry cannot fix (host key,
    /// refused login); start a new one then.
    pub fn reconnect(&self) -> bool {
        let Ok(state) = self.state.lock() else {
            return false;
        };
        match state.as_ref() {
            Some(rx) if !driver_stopped(rx) => {
                rx.borrow().request_reconnect();
                true
            }
            _ => false,
        }
    }

    fn connection(&self) -> Result<Arc<Connection>, SessionError> {
        self.state
            .lock()
            .ok()
            .and_then(|state| state.as_ref().and_then(|rx| rx.borrow().connection.clone()))
            .ok_or_else(|| SessionError::NotConnected("not connected to herdr".into()))
    }

    /// The address to open for a page an agent asked for (#247). A page on
    /// the host's own `localhost` gets a listener on this machine's
    /// loopback that tunnels through the connection; the URL then names its
    /// port and keeps the host name. Other URLs come back unchanged. Fails
    /// with [`SessionError::Forward`] when the key's line does not allow
    /// it, checked with one connection to the port.
    pub async fn open_url(&self, url: &str) -> Result<String, SessionError> {
        let Some(port) = forward::local_port(url).filter(|_| self.remote) else {
            return Ok(url.to_owned());
        };
        let conn = self.connection()?;
        conn.check_tcp(port).await.map_err(|err| match err {
            TransportError::Forward(message) => SessionError::Forward(message),
            TransportError::Io(err) if err.kind() == std::io::ErrorKind::ConnectionRefused => {
                SessionError::Rejected(err.to_string())
            }
            other => SessionError::NotConnected(other.to_string()),
        })?;
        let state = self
            .state
            .lock()
            .ok()
            .and_then(|state| state.clone())
            .ok_or_else(|| SessionError::NotConnected("session stopped".into()))?;
        let (local, ipv6) = self
            .forwards
            .ensure(port, state, &self.runtime)
            .map_err(|err| SessionError::Rejected(format!("no local port to forward to: {err}")))?;
        forward::with_port(url, local, ipv6)
            .ok_or_else(|| SessionError::Rejected(format!("cannot read the address {url}")))
    }

    /// Takes an open request back on the host, so no other client offers
    /// it any more: marks it done (`open_done`); a newer request of the
    /// pane stays.
    pub async fn dismiss_open_request(
        &self,
        pane_id: &str,
        request_id: &str,
    ) -> Result<(), SessionError> {
        // A mark under a source of its own instead of clearing the
        // request: herdr has no compare-and-set, and clearing could take a
        // newer request of the pane along that this client has not seen
        // yet. The mark outlives the request (same time to live, set later).
        // An older id must not hide a newer request another client marked.
        let current = self.state.lock().ok().and_then(|state| {
            let session = state.as_ref()?.borrow().session.clone()?;
            session
                .pane(pane_id)?
                .tokens
                .get(herdr_core::OPEN_ID_TOKEN)
                .cloned()
        });
        if current.as_deref() != Some(request_id) {
            return Ok(());
        }
        let conn = self.connection()?;
        conn.request(
            "pane.report_metadata",
            serde_json::json!({
                "pane_id": pane_id,
                "source": OPEN_DONE_SOURCE,
                "tokens": { herdr_core::OPEN_DONE_TOKEN: request_id },
                "ttl_ms": OPEN_TTL_MS,
            }),
        )
        .await
        .map_err(|err| SessionError::from(actions::ActionError::from(err)))?;
        Ok(())
    }

    /// Takes an editor request back on the host (#288) like
    /// [`Self::dismiss_open_request`]: marks it done (`editor_done`), so no
    /// other client offers it and the stand-in does not open VS Code on the
    /// host as well.
    pub async fn dismiss_editor_request(
        &self,
        pane_id: &str,
        request_id: &str,
    ) -> Result<(), SessionError> {
        let current = self.state.lock().ok().and_then(|state| {
            let session = state.as_ref()?.borrow().session.clone()?;
            session
                .pane(pane_id)?
                .tokens
                .get(herdr_core::EDITOR_ID_TOKEN)
                .cloned()
        });
        if current.as_deref() != Some(request_id) {
            return Ok(());
        }
        let conn = self.connection()?;
        conn.request(
            "pane.report_metadata",
            serde_json::json!({
                "pane_id": pane_id,
                "source": EDITOR_DONE_SOURCE,
                "tokens": { herdr_core::EDITOR_DONE_TOKEN: request_id },
                "ttl_ms": EDITOR_TTL_MS,
            }),
        )
        .await
        .map_err(|err| SessionError::from(actions::ActionError::from(err)))?;
        Ok(())
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

    /// The last `max_lines` rows of a pane including scrollback as plain
    /// text, joined where the terminal wrapped them with `unwrap`: trailing
    /// spaces trimmed, blank lines at the bottom dropped. For a summary of
    /// what happened since the last visit (#273). Read only.
    pub async fn recent_text(
        &self,
        pane_id: &str,
        max_lines: u32,
        unwrap: bool,
    ) -> Result<String, SessionError> {
        let conn = self.connection()?;
        let read = pane::read_recent(&conn, pane_id, max_lines, unwrap).await?;
        let mut lines: Vec<String> = read
            .screen
            .text_lines()
            .into_iter()
            .map(|line| line.trim_end().to_owned())
            .collect();
        while lines.last().is_some_and(String::is_empty) {
            lines.pop();
        }
        Ok(lines.join("\n"))
    }

    /// The choice question an agent asks at the bottom of a pane's visible
    /// screen, for a notification's actions (#272). Read only.
    pub async fn choice_question(
        &self,
        pane_id: &str,
    ) -> Result<Option<ChoiceQuestion>, SessionError> {
        let conn = self.connection()?;
        let read = pane::read_screen(&conn, pane_id).await?;
        Ok(view::choice_question(&read.screen))
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
        let base = format!("{} {kind} {blob}", gate_options(false, false, None)?);
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

    /// The named herdr sessions on this host, running or stopped (#213).
    /// Over SSH this needs SFTP, like uploads.
    pub async fn herdr_sessions(&self) -> Result<Vec<HerdrSessionEntry>, SessionError> {
        let conn = self.connection()?;
        conn.herdr_sessions()
            .await
            .map_err(|err| SessionError::Files(err.to_string()))
    }

    /// What changed in the working directory of a pane (#228): `git diff`
    /// against `HEAD` plus untracked files, read only. herdr has no method
    /// for it and device keys reach no shell, so a small script runs in a
    /// short-lived, unfocused tab in the pane's directory and leaves its
    /// output in the uploads folder, read and removed through SFTP. Needs
    /// file access like uploads; takes a moment.
    pub async fn working_tree_diff(
        &self,
        pane_id: &str,
    ) -> Result<diff::WorkingTreeDiff, SessionError> {
        let conn = self.connection()?;
        let (workspace_id, cwd) = self.pane_directory(pane_id).ok_or_else(|| {
            SessionError::Files(format!("no working directory known for pane {pane_id}"))
        })?;

        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        let stamp = format!("diff-{}-{:09}", now.as_secs(), now.subsec_nanos());
        let out = format!("{UPLOAD_DIR}/{stamp}.txt");
        let script = conn
            .upload(
                UPLOAD_DIR,
                &format!("{stamp}.sh"),
                diff::diff_script(&out).as_bytes(),
            )
            .await
            .map_err(|err| SessionError::Files(err.to_string()))?;
        let script_rel = format!("{UPLOAD_DIR}/{stamp}.sh");
        let done = format!("{out}.done");
        let err_file = format!("{out}.err");

        let result = async {
            // A leading space keeps it out of the shell's history where the
            // shell honours that (fish, zsh/bash with ignorespace).
            let tab =
                run_in_tab(&conn, &workspace_id, &cwd, &format!(" sh '{script}'; exit")).await?;
            let finished = wait_for_file(&conn, &format!("{stamp}.txt.done")).await;
            // The shell exits by itself; close the tab in case it stayed.
            let _ = actions::close_tab(&conn, &tab).await;
            finished?;
            let mut data = conn
                .read_file_range(&done, 0, MAX_DIFF_BYTES + 1)
                .await
                .map_err(|err| SessionError::Files(err.to_string()))?;
            let truncated = data.len() as u64 > MAX_DIFF_BYTES;
            if truncated {
                // Up to the last complete line.
                data.truncate(MAX_DIFF_BYTES as usize);
                if let Some(end) = data.iter().rposition(|byte| *byte == b'\n') {
                    data.truncate(end + 1);
                }
            }
            let text = String::from_utf8_lossy(&data).into_owned();
            if text.trim().is_empty() || text.trim() == diff::UNTRACKED_MARK {
                let errors = conn
                    .read_file_range(&err_file, 0, 4096)
                    .await
                    .unwrap_or_default();
                let errors = String::from_utf8_lossy(&errors).trim().to_owned();
                if !errors.is_empty() {
                    return Err(SessionError::Files(errors));
                }
            }
            Ok(diff::WorkingTreeDiff {
                files: diff::parse(&text),
                truncated,
            })
        }
        .await;
        for file in [&script_rel, &done, &err_file, &out] {
            let _ = conn.remove_file(file).await;
        }
        result
    }

    /// The space and working directory of a pane: its foreground process's
    /// directory, else the pane's.
    fn pane_directory(&self, pane_id: &str) -> Option<(String, String)> {
        let state = self.state.lock().ok()?;
        let session = state.as_ref()?.borrow().session.clone()?;
        let pane = session.pane(pane_id)?;
        let cwd = pane.foreground_cwd.clone().or_else(|| pane.cwd.clone())?;
        Some((pane.workspace_id.clone(), cwd))
    }

    /// The folder to open a pane in VS Code with (#288): its working
    /// directory as for the file browser. `None` when herdr reports none.
    pub fn pane_folder(&self, pane_id: &str) -> Option<String> {
        self.pane_directory(pane_id).map(|(_, dir)| dir)
    }

    /// The folder to open a space in VS Code with (#288): that of the
    /// focused pane in its active tab, else of the tab's first pane.
    pub fn space_folder(&self, workspace_id: &str) -> Option<String> {
        let pane_id = {
            let state = self.state.lock().ok()?;
            let session = state.as_ref()?.borrow().session.clone()?;
            let tab_id = session.workspace(workspace_id)?.active_tab_id.clone();
            let panes: Vec<_> = session
                .panes
                .iter()
                .filter(|pane| pane.tab_id == tab_id)
                .collect();
            let focused = session
                .layout(&tab_id)
                .map(|layout| layout.focused_pane_id.as_str())
                .and_then(|id| panes.iter().find(|pane| pane.pane_id == id))
                .or_else(|| panes.iter().find(|pane| pane.focused));
            focused.or(panes.first())?.pane_id.clone()
        };
        self.pane_folder(&pane_id)
    }

    /// The directory at the absolute `path` on the host, empty for the
    /// home directory (#259). Read only; paths outside the home directory
    /// fail. Needs file access like uploads.
    pub async fn list_directory(&self, path: &str) -> Result<browse::Directory, SessionError> {
        let conn = self.connection()?;
        browse::list(&conn, path).await.map_err(files_error)
    }

    /// The working directory of a pane for the file browser (#259); the
    /// home directory when none is known or it lies outside the home.
    pub async fn open_pane_directory(
        &self,
        pane_id: &str,
    ) -> Result<browse::Directory, SessionError> {
        let conn = self.connection()?;
        if let Some((_, dir)) = self.pane_directory(pane_id) {
            match browse::list(&conn, &dir).await {
                Err(TransportError::Files(message))
                    if message.ends_with(herdr_transport::OUTSIDE_HOME) => {}
                result => return result.map_err(files_error),
            }
        }
        browse::list(&conn, "").await.map_err(files_error)
    }

    /// The file at the absolute `path` on the host to show (#259): text up
    /// to 1 MB, an image up to 10 MB, otherwise only size and name.
    pub async fn file_preview(&self, path: &str) -> Result<browse::FilePreview, SessionError> {
        let conn = self.connection()?;
        browse::preview(&conn, path).await.map_err(files_error)
    }

    /// Writes `text` to the file at the absolute `path` on the host (#271)
    /// and returns it as now saved. `size` and `modified` are those of the
    /// [`browse::FilePreview`] it was edited from; when the file changed
    /// since, nothing is written and it fails with
    /// [`SessionError::FileChanged`]; written but not read back, with
    /// [`SessionError::SavedNotRead`]. Up to 256 KB of text.
    pub async fn save_file(
        &self,
        path: &str,
        text: &str,
        size: u64,
        modified: u64,
    ) -> Result<browse::FilePreview, SessionError> {
        let conn = self.connection()?;
        browse::save(&conn, path, text, size, modified)
            .await
            .map_err(files_error)
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

    /// Writes the secret `name` with `value` to `~/.amiscara-agents/env` on
    /// the host (#291), file mode 0600, replacing an earlier value. Needs
    /// file access like uploads; errors never contain the value.
    pub async fn send_secret(&self, name: &str, value: &str) -> Result<(), SessionError> {
        secrets::check_name(name)?;
        secrets::check_value(value)?;
        let conn = self.connection()?;
        conn.write_private_file(secrets::ENV_DIR, name, value.as_bytes())
            .await
            .map(|_| ())
            .map_err(upload_error)
    }

    /// Deletes the secret `name` on the host; a missing one is no error.
    pub async fn remove_secret(&self, name: &str) -> Result<(), SessionError> {
        secrets::check_name_shape(name)?;
        let conn = self.connection()?;
        conn.remove_file(&format!("{}/{name}", secrets::ENV_DIR))
            .await
            .map_err(files_error)
    }

    /// The names of the secrets on the host, sorted; files whose name is no
    /// variable are left out. Only names: values are never read back.
    pub async fn secret_names(&self) -> Result<Vec<String>, SessionError> {
        let conn = self.connection()?;
        let mut names: Vec<String> = conn
            .list_files_if_present(secrets::ENV_DIR)
            .await
            .map_err(files_error)?
            .into_iter()
            .map(|file| file.name)
            .filter(|name| secrets::has_env_name_shape(name))
            .collect();
        names.sort();
        Ok(names)
    }

    /// The GitHub repositories of the spaces on the host (#296), sorted,
    /// each with its spaces: the `origin` in the `config` of each Git
    /// repository the spaces show. Repositories elsewhere and unreadable
    /// configs are left out; it fails only without a connection. Needs
    /// file access like uploads.
    pub async fn github_repos(&self) -> Result<Vec<github::GitHubRepo>, SessionError> {
        let conn = self.connection()?;
        let by_key = {
            let state = self.state.lock().ok();
            let session = state
                .as_ref()
                .and_then(|state| state.as_ref())
                .and_then(|rx| rx.borrow().session.clone());
            spaces_by_repo_key(session.iter().flat_map(|session| &session.workspaces))
        };
        let mut origins = Vec::new();
        for (key, workspace_ids) in by_key {
            // The key is absolute, so `read_file_head` and not
            // `read_file_range`, which reads relative to the home.
            let Ok(head) = conn
                .read_file_head(&format!("{key}/config"), |size| {
                    size.min(MAX_GIT_CONFIG_BYTES)
                })
                .await
            else {
                continue;
            };
            if let Some(repo) = github::origin_repo(&String::from_utf8_lossy(&head.data)) {
                origins.push((repo, workspace_ids));
            }
        }
        Ok(merge_github_repos(origins))
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
        let (stop_tx, stop) = watch::channel(false);
        if let Some(state) = state {
            self.runtime
                .spawn(follow_loop(state, pane_id, pacing, reading, stop, sink));
        }
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

/// Writes tokens of [`chains::CHAINS_SOURCE`] to a pane; `None` removes one.
async fn write_chain_tokens(
    conn: &Connection,
    pane_id: &str,
    tokens: std::collections::BTreeMap<String, Option<String>>,
) -> Result<(), TransportError> {
    conn.request(
        "pane.report_metadata",
        serde_json::json!({
            "pane_id": pane_id,
            "source": chains::CHAINS_SOURCE,
            "tokens": tokens,
        }),
    )
    .await
    .map(|_| ())
}

/// The chains to run after a state change (#300), with what they share.
struct ChainRuns {
    conn: Arc<Connection>,
    device: String,
    /// The state the change was seen in: chains, targets and names.
    state: Arc<herdr_core::SessionState>,
    /// Chain id and state change each run on this device already handled,
    /// so seeing a change again (e.g. around a reconnect) sends nothing.
    claimed: Arc<Mutex<HashSet<(String, u64)>>>,
    results: mpsc::UnboundedSender<ChainResult>,
}

impl ChainRuns {
    /// Starts a task per chain whose agent changed to its trigger since
    /// `before`; each reports its result unless another device ran it.
    fn start(&self, before: &herdr_core::SessionState) {
        for (pane_id, trigger) in chains::fired(before, &self.state) {
            let Some(pane) = self.state.pane(&pane_id) else {
                continue;
            };
            for chain in chains::chains_of(pane) {
                if chain.trigger != trigger || chain.failed {
                    continue;
                }
                let trigger_label = view::pane_label(&self.state, &pane_id);
                let target_label = view::pane_label(&self.state, &chain.target_pane_id);
                let run = ChainRun {
                    conn: self.conn.clone(),
                    device: self.device.clone(),
                    pane_id: pane_id.clone(),
                    target_present: self.state.pane(&chain.target_pane_id).is_some(),
                    claimed: self.claimed.clone(),
                    chain,
                };
                let results = self.results.clone();
                tokio::spawn(async move {
                    let (chain_id, text) = (run.chain.id.clone(), run.chain.text.clone());
                    let trigger_pane_id = run.pane_id.clone();
                    if let Some((outcome, reason)) = run.run().await {
                        let _ = results.send(ChainResult {
                            chain_id,
                            trigger_pane_id,
                            trigger_label,
                            target_label,
                            text,
                            outcome,
                            reason,
                            at_ms: unix_ms(),
                        });
                    }
                });
            }
        }
    }
}

/// One chain after its agent changed.
struct ChainRun {
    conn: Arc<Connection>,
    device: String,
    pane_id: String,
    chain: Chain,
    target_present: bool,
    claimed: Arc<Mutex<HashSet<(String, u64)>>>,
}

impl ChainRun {
    /// Checks the change, claims it, sends. `None` when another device
    /// claimed it or this one handled it already.
    async fn run(self) -> Option<(ChainOutcome, Option<String>)> {
        let skipped = |reason: String| Some((ChainOutcome::Skipped, Some(reason)));
        let agent = match self.agent().await {
            Ok(agent) => agent,
            Err(reason) => return skipped(reason),
        };
        let holds = match self.chain.trigger {
            chains::ChainTrigger::Blocked => agent.agent_status == AgentStatus::Blocked,
            // herdr 0.9.5 sets `completion_seq` after an Esc as well, so an
            // interrupted turn counts as done.
            chains::ChainTrigger::Done => {
                matches!(agent.agent_status, AgentStatus::Done | AgentStatus::Idle)
                    && agent.completion_seq == Some(agent.state_change_seq)
            }
        };
        if !holds {
            return skipped("the agent changed again before the chain ran".into());
        }
        let seq = agent.state_change_seq;
        if seq == 0 {
            return skipped("this herdr version does not count state changes".into());
        }
        let first_here = self
            .claimed
            .lock()
            .is_ok_and(|mut claimed| claimed.insert((self.chain.id.clone(), seq)));
        if !first_here {
            return None;
        }
        // herdr ignores a report whose `seq` is not newer than the last one
        // of its source and has no compare-and-set: every device writes its
        // claim with the change's number, only the first one sticks.
        // The mark names this run, not only the device: two sessions with
        // one device id (the same host added twice, a device restored from
        // another's backup) must not both take it.
        let claim = chains::claim_token(&self.chain.id);
        let mark = format!("{}:{}:{seq}", self.device, run_nonce());
        let claimed = self
            .conn
            .request(
                "pane.report_metadata",
                serde_json::json!({
                    "pane_id": self.pane_id,
                    "source": chains::claim_source(&self.chain.id),
                    "tokens": { &claim: &mark },
                    "seq": seq,
                    "ttl_ms": CHAIN_CLAIM_TTL_MS,
                }),
            )
            .await;
        if let Err(err) = claimed {
            return skipped(err.to_string());
        }
        let pane = match self.pane().await {
            Ok(pane) => pane,
            Err(reason) => return skipped(reason),
        };
        if pane.tokens.get(&claim) != Some(&mark) {
            return None;
        }
        // Deleted, failed or sent by now (e.g. a slower device that saw it
        // before a one-shot chain went): the host's copy decides.
        if !chains::chains_of(&pane)
            .iter()
            .any(|chain| chain.id == self.chain.id && !chain.failed)
        {
            return None;
        }
        if !self.target_present {
            self.mark_failed().await;
            return Some((ChainOutcome::Failed, Some("the target pane is gone".into())));
        }
        // A one-shot chain goes before it sends: left behind after a send,
        // the agent's next change would claim it anew and send again.
        if !self.chain.repeat
            && let Err(err) = write_chain_tokens(
                &self.conn,
                &self.pane_id,
                chains::clear_tokens(&self.chain.id),
            )
            .await
        {
            return skipped(err.to_string());
        }
        match actions::send_prompt(&self.conn, &self.chain.target_pane_id, &self.chain.text).await {
            Ok(()) => {}
            // The target waits at a dialog or the link dropped: this time
            // only. A one-shot chain comes back to run on the next change.
            Err(
                err @ (actions::ActionError::AgentBlocked | actions::ActionError::Transport(_)),
            ) => {
                if !self.chain.repeat {
                    let _ = write_chain_tokens(
                        &self.conn,
                        &self.pane_id,
                        chains::chain_tokens(&self.chain),
                    )
                    .await;
                }
                return skipped(err.to_string());
            }
            Err(err) => {
                self.mark_failed().await;
                return Some((ChainOutcome::Failed, Some(err.to_string())));
            }
        }
        if !self.chain.repeat {
            // The chain is gone; its claim need not wait out its time.
            let _ = self
                .conn
                .request(
                    "pane.report_metadata",
                    serde_json::json!({
                        "pane_id": self.pane_id,
                        "source": chains::claim_source(&self.chain.id),
                        "tokens": { &claim: null },
                    }),
                )
                .await;
        }
        Some((ChainOutcome::Sent, None))
    }

    async fn agent(&self) -> Result<herdr_proto::AgentInfo, String> {
        let value = self
            .conn
            .request("agent.get", serde_json::json!({ "target": self.pane_id }))
            .await
            .map_err(|err| err.to_string())?;
        serde_json::from_value::<AgentGetResult>(value)
            .map(|got| got.agent)
            .map_err(|err| err.to_string())
    }

    async fn pane(&self) -> Result<herdr_proto::PaneInfo, String> {
        let value = self
            .conn
            .request("pane.get", serde_json::json!({ "pane_id": self.pane_id }))
            .await
            .map_err(|err| err.to_string())?;
        let got: PaneGetResult = serde_json::from_value(value).map_err(|err| err.to_string())?;
        Ok(got.pane)
    }

    /// Keeps the chain, marked failed, so it shows and never runs again.
    /// Best effort: on a dropped connection it stays active.
    async fn mark_failed(&self) {
        let failed = Chain {
            failed: true,
            ..self.chain.clone()
        };
        let _ = write_chain_tokens(&self.conn, &self.pane_id, chains::chain_tokens(&failed)).await;
    }
}

/// Eight random hex digits that tell one chain run's claim from another's.
fn run_nonce() -> String {
    use std::hash::BuildHasher;
    format!(
        "{:08x}",
        std::collections::hash_map::RandomState::new().hash_one(unix_ms()) & 0xffff_ffff
    )
}

/// Whether the sync driver behind `rx` has ended. It drops its sender when
/// it stops, right after setting the final status; either tells.
fn driver_stopped(rx: &watch::Receiver<SyncState>) -> bool {
    rx.has_changed().is_err()
        || matches!(
            rx.borrow().status,
            SyncStatus::HostKeyUnknown { .. }
                | SyncStatus::HostKeyChanged { .. }
                | SyncStatus::Failed { .. }
        )
}

/// Follows a pane across reconnects until stopped. A read on a connection
/// the session has since replaced is given up without an error: after the
/// device slept it can hang on the dead link for good, while the session
/// already has a new one (#258).
async fn follow_loop(
    mut state: watch::Receiver<SyncState>,
    pane_id: String,
    pacing: watch::Receiver<Pacing>,
    reading: watch::Receiver<pane::Reading>,
    mut stop: watch::Receiver<bool>,
    sink: impl PaneSink,
) {
    let mut replaced = state.clone();
    loop {
        let connection = state.borrow_and_update().connection.clone();
        if let Some(conn) = connection {
            let follow = follow_once(
                &conn,
                &pane_id,
                pacing.clone(),
                reading.clone(),
                stop.clone(),
                &sink,
            );
            // Only cancel once another connection replaced this one, not while
            // none is there: a read dropped half way leaves a connection still
            // in use unable to open channels (#107).
            let replaced_by_another = |s: &SyncState| {
                s.connection
                    .as_ref()
                    .is_some_and(|current| !Arc::ptr_eq(current, &conn))
            };
            tokio::select! {
                result = follow => {
                    if let Err(message) = result {
                        sink.on_error(message);
                    }
                }
                changed = replaced.wait_for(replaced_by_another) => {
                    if changed.is_err() || *stop.borrow() {
                        return;
                    }
                    continue;
                }
            }
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
/// The most of a diff the apps read; a bigger one is cut off.
const MAX_DIFF_BYTES: u64 = 4 * 1024 * 1024;
/// The spaces of each Git repository, by its `.git` path (#296); spaces
/// outside a repository are left out.
fn spaces_by_repo_key<'a>(
    workspaces: impl IntoIterator<Item = &'a herdr_proto::WorkspaceInfo>,
) -> std::collections::BTreeMap<String, Vec<String>> {
    let mut by_key: std::collections::BTreeMap<String, Vec<String>> = Default::default();
    for ws in workspaces {
        if let Some(wt) = ws.worktree.as_ref().filter(|wt| !wt.repo_key.is_empty()) {
            by_key
                .entry(wt.repo_key.clone())
                .or_default()
                .push(ws.workspace_id.clone());
        }
    }
    by_key
}

/// One entry per GitHub repository, sorted: two clones of the same
/// repository share it with the spaces of both.
fn merge_github_repos(origins: Vec<(String, Vec<String>)>) -> Vec<github::GitHubRepo> {
    let mut repos: std::collections::BTreeMap<String, Vec<String>> = Default::default();
    for (repo, workspace_ids) in origins {
        repos.entry(repo).or_default().extend(workspace_ids);
    }
    repos
        .into_iter()
        .map(|(repo, workspace_ids)| github::GitHubRepo {
            repo,
            workspace_ids,
        })
        .collect()
}

/// The most of a Git `config` read for its `origin` (#296).
const MAX_GIT_CONFIG_BYTES: u64 = 64 * 1024;

/// Opens an unfocused tab in `cwd` and types `command` with Enter;
/// returns the tab's id.
async fn run_in_tab(
    conn: &Connection,
    workspace_id: &str,
    cwd: &str,
    command: &str,
) -> Result<String, SessionError> {
    let created = actions::create_tab(conn, workspace_id, Some(cwd)).await?;
    let typed = async {
        actions::send_text(conn, &created.pane_id, command).await?;
        actions::send_keys(conn, &created.pane_id, &["enter".to_owned()]).await
    }
    .await;
    if let Err(err) = typed {
        // Leave no idle shell tab behind.
        let _ = actions::close_tab(conn, &created.tab_id).await;
        return Err(err.into());
    }
    Ok(created.tab_id)
}

/// Waits until `name` shows up in the uploads folder, up to half a minute.
async fn wait_for_file(conn: &Connection, name: &str) -> Result<(), SessionError> {
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        let files = conn
            .list_files(UPLOAD_DIR)
            .await
            .map_err(|err| SessionError::Files(err.to_string()))?;
        if files.iter().any(|file| file.name == name) {
            return Ok(());
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(SessionError::Files(
                "git diff did not finish in time".into(),
            ));
        }
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    }
}

/// The current time in Unix milliseconds.
fn unix_ms() -> u64 {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    u64::try_from(now.as_millis()).unwrap_or(u64::MAX)
}

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
    use super::{
        SessionError, TransportError, files_error, merge_github_repos, named_upload,
        spaces_by_repo_key,
    };

    fn workspace(value: serde_json::Value) -> herdr_proto::WorkspaceInfo {
        match serde_json::from_value(value) {
            Ok(ws) => ws,
            Err(err) => panic!("fixture: {err}"),
        }
    }

    #[test]
    fn spaces_are_grouped_by_their_repository() {
        let spaces = [
            workspace(
                serde_json::json!({"workspace_id": "w1", "number": 1, "label": "app",
                "worktree": {"repo_key": "/Users/a/app/.git", "repo_name": "app", "checkout_path": "/Users/a/app"}}),
            ),
            workspace(serde_json::json!({"workspace_id": "w2", "number": 2, "label": "notes"})),
            workspace(
                serde_json::json!({"workspace_id": "w3", "number": 3, "label": "app-wt",
                "worktree": {"repo_key": "/Users/a/app/.git", "repo_name": "app",
                             "checkout_path": "/Users/a/app/.worktrees/x", "is_linked_worktree": true}}),
            ),
            workspace(
                serde_json::json!({"workspace_id": "w4", "number": 4, "label": "empty",
                "worktree": {"repo_key": "", "repo_name": "e", "checkout_path": "/e"}}),
            ),
        ];
        let by_key = spaces_by_repo_key(&spaces);
        assert_eq!(by_key.len(), 1);
        assert_eq!(
            by_key.get("/Users/a/app/.git").map(Vec::as_slice),
            Some(["w1".to_owned(), "w3".to_owned()].as_slice())
        );
    }

    #[test]
    fn clones_of_one_github_repository_share_an_entry() {
        let repos = merge_github_repos(vec![
            ("o/zeta".into(), vec!["w5".into()]),
            ("o/app".into(), vec!["w1".into(), "w3".into()]),
            ("o/app".into(), vec!["w7".into()]),
        ]);
        let shown: Vec<(&str, Vec<&str>)> = repos
            .iter()
            .map(|r| {
                (
                    r.repo.as_str(),
                    r.workspace_ids.iter().map(String::as_str).collect(),
                )
            })
            .collect();
        assert_eq!(
            shown,
            vec![("o/app", vec!["w1", "w3", "w7"]), ("o/zeta", vec!["w5"])]
        );
    }

    #[test]
    fn a_file_changed_on_the_host_gets_its_own_error() {
        let changed = format!("/home/a/x.txt {}", herdr_transport::CHANGED_ON_HOST);
        assert!(matches!(
            files_error(TransportError::Files(changed)),
            SessionError::FileChanged(_)
        ));
        assert!(matches!(
            files_error(TransportError::Files(
                "/home/a/x.txt: Permission denied".into()
            )),
            SessionError::Files(_)
        ));
        let unread = format!("{}: connection lost", herdr_core::browse::SAVED_NOT_READ);
        assert!(matches!(
            files_error(TransportError::Files(unread)),
            SessionError::SavedNotRead(_)
        ));
        assert!(matches!(
            files_error(TransportError::Timeout),
            SessionError::NotConnected(_)
        ));
    }

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

    // A herdr stand-in for chains (#300): one agent pane `w1:p1` with a
    // chain to `w1:p2`, metadata with herdr's `seq` rule, prompts counted.
    #[cfg(unix)]
    mod chain_runs {
        use super::super::*;
        use std::collections::BTreeMap;
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
        use tokio::net::UnixListener;

        #[derive(Default)]
        struct Fake {
            status: &'static str,
            seq: u64,
            /// Source to its tokens and the last `seq` it took.
            sources: BTreeMap<String, (BTreeMap<String, String>, Option<u64>)>,
            panes: Vec<&'static str>,
            /// Targets waiting at a dialog, which refuse prompts.
            blocked: Vec<&'static str>,
            prompts: Vec<(String, String)>,
        }

        impl Fake {
            fn tokens(&self) -> BTreeMap<String, String> {
                self.sources
                    .values()
                    .flat_map(|(tokens, _)| tokens.clone())
                    .collect()
            }

            fn answer(&mut self, method: &str, params: &serde_json::Value) -> serde_json::Value {
                use serde_json::json;
                match method {
                    "agent.get" => json!({"result": {"type": "agent_info", "agent": {
                        "pane_id": "w1:p1", "agent_status": self.status,
                        "state_change_seq": self.seq, "completion_seq": self.seq
                    }}}),
                    "pane.get" => json!({"result": {"type": "pane_info", "pane": {
                        "pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
                        "tokens": self.tokens()
                    }}}),
                    "pane.report_metadata" => {
                        let source = params["source"].as_str().unwrap_or_default().to_owned();
                        let entry = self.sources.entry(source).or_default();
                        let seq = params["seq"].as_u64();
                        if let (Some(seq), Some(last)) = (seq, entry.1)
                            && seq <= last
                        {
                            return json!({"result": {"type": "ok"}});
                        }
                        if seq.is_some() {
                            entry.1 = seq;
                        }
                        for (key, value) in params["tokens"].as_object().into_iter().flatten() {
                            match value.as_str() {
                                Some(value) => entry.0.insert(key.clone(), value.to_owned()),
                                None => entry.0.remove(key),
                            };
                        }
                        json!({"result": {"type": "ok"}})
                    }
                    "agent.prompt" => {
                        let target = params["target"].as_str().unwrap_or_default();
                        if self.blocked.contains(&target) {
                            return json!({"error": {"code": "agent_blocked", "message": "waits"}});
                        }
                        if !self.panes.contains(&target) {
                            return json!({"error": {"code": "agent_not_found", "message": "gone"}});
                        }
                        self.prompts.push((
                            target.to_owned(),
                            params["text"].as_str().unwrap_or_default().to_owned(),
                        ));
                        json!({"result": {"type": "agent_prompted"}})
                    }
                    _ => json!({"error": {"code": "unknown_method", "message": method}}),
                }
            }
        }

        fn fake_herdr(name: &str, fake: Arc<Mutex<Fake>>) -> std::path::PathBuf {
            let path = std::env::temp_dir()
                .join(format!("herdr-chains-{name}-{}.sock", std::process::id()));
            let _ = std::fs::remove_file(&path);
            let listener = UnixListener::bind(&path).expect("bind fake socket");
            tokio::spawn(async move {
                while let Ok((stream, _)) = listener.accept().await {
                    let fake = fake.clone();
                    tokio::spawn(async move {
                        let (read, mut write) = stream.into_split();
                        let mut lines = BufReader::new(read).lines();
                        while let Ok(Some(line)) = lines.next_line().await {
                            let request: serde_json::Value =
                                serde_json::from_str(&line).expect("json");
                            let mut reply = fake.lock().expect("fake").answer(
                                request["method"].as_str().unwrap_or_default(),
                                &request["params"],
                            );
                            reply["id"] = request["id"].clone();
                            let _ = write.write_all(format!("{reply}\n").as_bytes()).await;
                        }
                    });
                }
            });
            path
        }

        fn state(status: &str, tokens: &BTreeMap<String, String>) -> Arc<herdr_core::SessionState> {
            Arc::new(herdr_core::SessionState::from_snapshot(
                serde_json::from_value(serde_json::json!({
                    "version": "0.9.5", "protocol": 22,
                    "workspaces": [{"workspace_id": "w1", "number": 1, "label": "space"}],
                    "tabs": [{"tab_id": "w1:t1", "workspace_id": "w1", "number": 1, "label": "1"}],
                    "panes": [
                        {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
                         "agent": "claude", "agent_status": status, "tokens": tokens},
                        {"pane_id": "w1:p2", "workspace_id": "w1", "tab_id": "w1:t1",
                         "agent": "codex", "agent_status": "idle"}
                    ],
                    "agents": [{"pane_id": "w1:p2", "name": "reviewer"}]
                }))
                .expect("snapshot"),
            ))
        }

        fn chain_tokens(fake: &Arc<Mutex<Fake>>) -> BTreeMap<String, String> {
            let chain = Chain {
                id: "0a1b2c".into(),
                trigger: chains::ChainTrigger::Done,
                repeat: false,
                failed: false,
                target_pane_id: "w1:p2".into(),
                text: "/issue-approve 1".into(),
            };
            let tokens: BTreeMap<String, String> = chains::chain_tokens(&chain)
                .into_iter()
                .filter_map(|(key, value)| Some((key, value?)))
                .collect();
            fake.lock()
                .expect("fake")
                .sources
                .insert(chains::CHAINS_SOURCE.into(), (tokens.clone(), None));
            tokens
        }

        /// Runs the chains `before` → `now` on the devices and collects
        /// what they report within a second.
        async fn run(
            path: &std::path::Path,
            devices: &[&str],
            before: &herdr_core::SessionState,
            now: &Arc<herdr_core::SessionState>,
        ) -> Vec<ChainResult> {
            let (tx, mut rx) = mpsc::unbounded_channel();
            for device in devices {
                ChainRuns {
                    conn: Arc::new(Connection::local(path)),
                    device: (*device).to_owned(),
                    state: now.clone(),
                    claimed: Arc::new(Mutex::new(HashSet::new())),
                    results: tx.clone(),
                }
                .start(before);
            }
            drop(tx);
            let mut results = Vec::new();
            while let Ok(Some(result)) =
                tokio::time::timeout(Duration::from_secs(1), rx.recv()).await
            {
                results.push(result);
            }
            results
        }

        #[tokio::test]
        async fn two_devices_send_once_and_a_one_shot_chain_ends() {
            let fake = Arc::new(Mutex::new(Fake {
                status: "done",
                seq: 10,
                panes: vec!["w1:p1", "w1:p2"],
                ..Fake::default()
            }));
            let path = fake_herdr("once", fake.clone());
            let tokens = chain_tokens(&fake);
            let results = run(
                &path,
                &["mac", "iphone"],
                &state("working", &tokens),
                &state("done", &tokens),
            )
            .await;
            assert_eq!(results.len(), 1, "{results:?}");
            assert_eq!(results[0].outcome, ChainOutcome::Sent);
            assert_eq!(results[0].target_label, "reviewer");
            assert_eq!(results[0].trigger_label, "claude · Tab 1");
            let fake = fake.lock().expect("fake");
            assert_eq!(
                fake.prompts,
                [("w1:p2".to_owned(), "/issue-approve 1".to_owned())]
            );
            assert!(
                chains::chains_of(&state("done", &fake.tokens()).panes[0]).is_empty(),
                "a one-shot chain is gone once sent"
            );
            let _ = std::fs::remove_file(&path);
        }

        #[tokio::test]
        async fn a_missing_target_fails_for_good() {
            let fake = Arc::new(Mutex::new(Fake {
                status: "done",
                seq: 10,
                panes: vec!["w1:p1"],
                ..Fake::default()
            }));
            let path = fake_herdr("gone", fake.clone());
            let tokens = chain_tokens(&fake);
            let mut now = (*state("done", &tokens)).clone();
            now.panes.retain(|pane| pane.pane_id != "w1:p2");
            let now = Arc::new(now);
            let results = run(&path, &["mac"], &state("working", &tokens), &now).await;
            assert_eq!(results.len(), 1, "{results:?}");
            assert_eq!(results[0].outcome, ChainOutcome::Failed);
            assert!(fake.lock().expect("fake").prompts.is_empty());

            // The next change finds the chain marked failed and sends nothing.
            let tokens = fake.lock().expect("fake").tokens();
            let chains = chains::chains_of(&state("done", &tokens).panes[0]);
            assert!(chains.len() == 1 && chains[0].failed, "{chains:?}");
            fake.lock().expect("fake").seq = 12;
            let results = run(
                &path,
                &["mac"],
                &state("working", &tokens),
                &state("done", &tokens),
            )
            .await;
            assert!(results.is_empty(), "{results:?}");
            assert!(fake.lock().expect("fake").prompts.is_empty());
            let _ = std::fs::remove_file(&path);
        }

        #[tokio::test]
        async fn a_waiting_target_skips_and_keeps_the_chain() {
            let fake = Arc::new(Mutex::new(Fake {
                status: "done",
                seq: 10,
                panes: vec!["w1:p1", "w1:p2"],
                blocked: vec!["w1:p2"],
                ..Fake::default()
            }));
            let path = fake_herdr("blocked", fake.clone());
            let tokens = chain_tokens(&fake);
            let results = run(
                &path,
                &["mac"],
                &state("working", &tokens),
                &state("done", &tokens),
            )
            .await;
            assert_eq!(results.len(), 1, "{results:?}");
            assert_eq!(results[0].outcome, ChainOutcome::Skipped);
            let chains =
                chains::chains_of(&state("done", &fake.lock().expect("fake").tokens()).panes[0]);
            assert!(chains.len() == 1 && !chains[0].failed, "{chains:?}");

            // Once the target is free, the next change sends.
            {
                let mut fake = fake.lock().expect("fake");
                fake.blocked.clear();
                fake.seq = 12;
            }
            let results = run(
                &path,
                &["mac"],
                &state("working", &tokens),
                &state("done", &tokens),
            )
            .await;
            assert_eq!(results.len(), 1, "{results:?}");
            assert_eq!(results[0].outcome, ChainOutcome::Sent);
            let fake = fake.lock().expect("fake");
            assert_eq!(fake.prompts.len(), 1);
            assert!(
                !fake
                    .tokens()
                    .keys()
                    .any(|key| key.starts_with("chain_0a1b2c")),
                "chain and claim gone: {:?}",
                fake.tokens()
            );
            let _ = std::fs::remove_file(&path);
        }

        #[tokio::test]
        async fn one_device_id_twice_still_sends_once() {
            let fake = Arc::new(Mutex::new(Fake {
                status: "done",
                seq: 10,
                panes: vec!["w1:p1", "w1:p2"],
                ..Fake::default()
            }));
            let path = fake_herdr("twice", fake.clone());
            let tokens = chain_tokens(&fake);
            let results = run(
                &path,
                &["mac", "mac"],
                &state("working", &tokens),
                &state("done", &tokens),
            )
            .await;
            assert_eq!(results.len(), 1, "{results:?}");
            assert_eq!(fake.lock().expect("fake").prompts.len(), 1);
            let _ = std::fs::remove_file(&path);
        }

        #[tokio::test]
        async fn repeating_chains_both_ways_are_refused() {
            let mut back = chain_tokens(&Arc::new(Mutex::new(Fake::default())));
            // w1:p1 prompts w1:p2 every time; seen from w1:p2 that is "back".
            back.insert("chain_0a1b2c".into(), "dran|w1:p2".into());
            let (_tx, rx) = watch::channel(SyncState {
                session: Some(state("idle", &back)),
                ..Default::default()
            });
            let session = Session {
                state: Mutex::new(Some(rx)),
                group_by_name: watch::channel(false).0,
                space_sort: watch::channel(SpaceSort::default()).0,
                chain_runner: watch::channel(None).0,
                forward: tokio::spawn(async {}),
                remote: false,
                forwards: Forwards::default(),
                runtime: Handle::current(),
            };
            let refused = session
                .set_chain("w1:p2", ChainTrigger::Done, true, "w1:p1", "weiter")
                .await;
            assert!(
                matches!(refused, Err(SessionError::Rejected(_))),
                "{refused:?}"
            );
            // Once is fine: without a connection it gets as far as sending.
            let once = session
                .set_chain("w1:p2", ChainTrigger::Done, false, "w1:p1", "weiter")
                .await;
            assert!(
                matches!(once, Err(SessionError::NotConnected(_))),
                "{once:?}"
            );
        }

        #[tokio::test]
        async fn a_change_gone_by_is_skipped() {
            let fake = Arc::new(Mutex::new(Fake {
                status: "working",
                seq: 11,
                panes: vec!["w1:p1", "w1:p2"],
                ..Fake::default()
            }));
            let path = fake_herdr("skip", fake.clone());
            let tokens = chain_tokens(&fake);
            let results = run(
                &path,
                &["mac"],
                &state("working", &tokens),
                &state("done", &tokens),
            )
            .await;
            assert_eq!(results.len(), 1, "{results:?}");
            assert_eq!(results[0].outcome, ChainOutcome::Skipped);
            assert!(fake.lock().expect("fake").prompts.is_empty());
            let _ = std::fs::remove_file(&path);
        }
    }

    // The fake servers listen on Unix sockets, which `Connection::local` needs.
    #[cfg(unix)]
    mod follow {
        use super::super::*;
        use std::sync::atomic::{AtomicUsize, Ordering};
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
        use tokio::net::UnixListener;

        #[derive(Clone, Default)]
        struct Counts {
            contents: Arc<AtomicUsize>,
            errors: Arc<AtomicUsize>,
        }

        impl PaneSink for Counts {
            fn on_content(&self, _content: PaneContent) {
                self.contents.fetch_add(1, Ordering::SeqCst);
            }

            fn on_error(&self, _message: String) {
                self.errors.fetch_add(1, Ordering::SeqCst);
            }
        }

        /// A herdr stand-in; `answer: false` takes requests and never
        /// replies, like a link that died while the device slept.
        fn fake_herdr(name: &str, answer: bool) -> std::path::PathBuf {
            let path = std::env::temp_dir()
                .join(format!("herdr-session-{name}-{}.sock", std::process::id()));
            let _ = std::fs::remove_file(&path);
            let listener = UnixListener::bind(&path).expect("bind fake socket");
            tokio::spawn(async move {
                let mut held = Vec::new();
                while let Ok((stream, _)) = listener.accept().await {
                    if !answer {
                        held.push(stream);
                        continue;
                    }
                    let (read, mut write) = stream.into_split();
                    let mut line = String::new();
                    if BufReader::new(read).read_line(&mut line).await.is_err() {
                        continue;
                    }
                    let request: serde_json::Value = serde_json::from_str(&line).expect("json");
                    let reply = serde_json::json!({
                        "id": request["id"],
                        "result": {"type": "pane_read", "read": {
                            "pane_id": "w1:p1", "text": "screen\r\n", "truncated": false, "revision": 0
                        }}
                    });
                    let _ = write.write_all(format!("{reply}\n").as_bytes()).await;
                }
            });
            path
        }

        #[tokio::test]
        async fn reconnect_tells_whether_the_session_still_runs() {
            let dead = fake_herdr("reconnect", false);
            let session = Session::start(
                Endpoint::Local {
                    socket_path: Some(dead.to_string_lossy().into_owned()),
                },
                false,
                SpaceSort::default(),
                |_| {},
            )
            .expect("start");
            assert!(session.reconnect(), "a running session reconnects");
            session.stop();
            assert!(!session.reconnect(), "a stopped session starts over");
            let _ = std::fs::remove_file(&dead);
        }

        #[tokio::test]
        async fn a_final_status_counts_as_stopped() {
            // The final status arrives before the driver drops its sender.
            let (tx, rx) = watch::channel(SyncState::default());
            assert!(!driver_stopped(&rx));
            tx.send_modify(|state| {
                state.status = SyncStatus::Failed {
                    error: "refused".into(),
                };
            });
            assert!(driver_stopped(&rx));
            tx.send_modify(|state| state.status = SyncStatus::Connecting);
            assert!(!driver_stopped(&rx));
            drop(tx);
            assert!(driver_stopped(&rx), "no driver any more");
        }

        #[tokio::test]
        async fn a_replaced_connection_ends_a_hanging_read() {
            let dead = fake_herdr("dead", false);
            let live = fake_herdr("live", true);
            let (state_tx, state) = watch::channel(SyncState {
                connection: Some(Arc::new(Connection::local(&dead))),
                ..Default::default()
            });
            let (_pacing_tx, pacing) = watch::channel(Pacing::default());
            let (_reading_tx, reading) = watch::channel(pane::Reading::default());
            let (stop_tx, stop) = watch::channel(false);
            let counts = Counts::default();
            let follower = tokio::spawn(follow_loop(
                state,
                "w1:p1".to_owned(),
                pacing,
                reading,
                stop,
                counts.clone(),
            ));

            tokio::time::sleep(Duration::from_millis(300)).await;
            assert_eq!(counts.contents.load(Ordering::SeqCst), 0);
            state_tx.send_modify(|state| {
                state.connection = Some(Arc::new(Connection::local(&live)));
            });
            let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
            while counts.contents.load(Ordering::SeqCst) == 0
                && tokio::time::Instant::now() < deadline
            {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            assert!(
                counts.contents.load(Ordering::SeqCst) > 0,
                "content from the new connection"
            );
            assert_eq!(
                counts.errors.load(Ordering::SeqCst),
                0,
                "no error for the old one"
            );

            stop_tx.send_replace(true);
            let _ = tokio::time::timeout(Duration::from_secs(5), follower).await;
            let _ = std::fs::remove_file(&dead);
            let _ = std::fs::remove_file(&live);
        }
    }
}
