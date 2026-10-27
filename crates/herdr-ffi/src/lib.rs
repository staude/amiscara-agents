//! Swift (and later Kotlin) face of the Amiscara Agents core, via UniFFI.
//!
//! The apps start one [`HostSession`] per host and get every state change
//! through a [`SessionObserver`]; an open pane is followed with
//! [`HostSession::follow_pane`]. Callbacks arrive on a background thread,
//! the app hops to its UI thread itself. Keys live in the app (Keychain) and
//! are handed over as OpenSSH text.

mod add_host;
mod convert;

use std::sync::{Arc, OnceLock};

use herdr_core::{actions, pane};
use herdr_session::SessionError;
use herdr_transport::{TransportError, keys};
use tokio::runtime::Runtime;

pub use add_host::{
    ADD_HOST_PREFIX, ADD_HOST_VERSION, AddHostLink, AddHostLinkError, decode_add_host_link,
    encode_add_host_link, public_key_fingerprint,
};
pub use convert::{
    AgentState, BoardItem, HostStatus, OpenRequest, PaneContent, PaneFrame, PaneItem, ScrollStep,
    SessionUpdate, SpaceSlot, SplitLayout, StyledLine, StyledSpan, TabItem, TermColor, TokenItem,
    TranscriptCursor, TranscriptEntry, TranscriptKind, TranscriptPage, WorkspaceItem,
};
pub use convert::{
    DiffFile, DiffFileStatus, DiffHunk, DiffLine, DiffLineKind, Directory, DirectoryEntry,
    EntryKind, FileContent, FilePreview, WorkingTreeDiff,
};
pub use herdr_session::UPLOAD_DIR;

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
    /// Files on the host could not be read: no SFTP for this key, or no
    /// Claude Code session for the pane.
    #[error("{0}")]
    Files(String),
    /// herdr collects a full-screen agent's history only while it is idle.
    #[error("{0}")]
    AgentWorking(String),
    /// The host does not forward its `localhost` for this key; renew the
    /// key's `authorized_keys` line with web forwarding (#247).
    #[error("{0}")]
    Forward(String),
}

impl From<SessionError> for FfiError {
    fn from(err: SessionError) -> Self {
        match err {
            SessionError::Key(message) => Self::Key(message),
            SessionError::Unsupported(message) => Self::Unsupported(message),
            SessionError::NotConnected(message) => Self::NotConnected(message),
            SessionError::AgentBlocked(message) => Self::AgentBlocked(message),
            SessionError::Rejected(message) => Self::Rejected(message),
            SessionError::Upload(message) => Self::Upload(message),
            // Links come through `AddHostLinkError`; nothing else refuses one.
            SessionError::InvalidLink(err) => Self::Rejected(err.to_string()),
            SessionError::Files(message) => Self::Files(message),
            SessionError::AgentWorking(message) => Self::AgentWorking(message),
            SessionError::Forward(message) => Self::Forward(message),
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

impl From<Endpoint> for herdr_session::Endpoint {
    fn from(endpoint: Endpoint) -> Self {
        match endpoint {
            Endpoint::Local { socket_path } => Self::Local { socket_path },
            Endpoint::Ssh {
                host,
                port,
                user,
                private_key_openssh,
                pinned_host_key,
                socket_path,
            } => Self::Ssh {
                host,
                port,
                user,
                identity: herdr_session::SshIdentity::Key(private_key_openssh),
                pinned_host_key,
                socket_path,
            },
        }
    }
}

/// How the sidebar orders spaces (see `herdr_core::spaces::SpaceSort`).
#[derive(Debug, Clone, uniffi::Enum)]
pub enum SpaceSort {
    Herdr,
    NameAscending,
    NameDescending,
    /// Workspace IDs in the user's order; spaces not listed follow.
    Manual {
        order: Vec<String>,
    },
}

impl From<SpaceSort> for herdr_session::SpaceSort {
    fn from(sort: SpaceSort) -> Self {
        match sort {
            SpaceSort::Herdr => Self::Herdr,
            SpaceSort::NameAscending => Self::NameAscending,
            SpaceSort::NameDescending => Self::NameDescending,
            SpaceSort::Manual { order } => Self::Manual(order),
        }
    }
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

/// The `authorized_keys` line for a client key (#132): no forwarding at all
/// (`restrict`), and a forced command that connects every session to the
/// herdr socket. With `allow_sftp`, an SFTP request runs `sftp-server`
/// instead (uploads, history), which can read and write all files of the
/// user; without it SFTP is refused. With `allow_web`, the app can reach
/// ports on the host's `localhost` (#247). The apps reach herdr through a
/// session running `herdr` once sshd refuses their streamlocal channel.
///
/// `socket_path`: the host's `herdr.sock` when it is not the default
/// `$HOME/.config/herdr/herdr.sock`; absolute, without quotes or `$`.
///
/// Lines from before used `restrict,port-forwarding` for streamlocal, which
/// also allowed TCP forwarding (`permitopen` cannot narrow it, it refuses
/// streamlocal too); they keep working.
#[uniffi::export]
pub fn authorized_keys_line(
    public_openssh: String,
    allow_sftp: bool,
    allow_web: bool,
    socket_path: Option<String>,
) -> Result<String, FfiError> {
    Ok(herdr_session::authorized_keys_line(
        &public_openssh,
        allow_sftp,
        allow_web,
        socket_path.as_deref(),
    )?)
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

/// Default `herdr.sock` path for a user on a macOS host.
#[uniffi::export]
pub fn default_remote_socket(user: String) -> String {
    format!("/Users/{user}/.config/herdr/herdr.sock")
}

/// A named herdr session on a host (#213).
#[derive(Debug, Clone, uniffi::Record)]
pub struct HerdrSession {
    pub name: String,
    /// Whether its server runs right now.
    pub running: bool,
}

impl From<herdr_session::HerdrSessionEntry> for HerdrSession {
    fn from(entry: herdr_session::HerdrSessionEntry) -> Self {
        Self {
            name: entry.name,
            running: entry.running,
        }
    }
}

/// The socket of herdr session `name` next to `default_socket` (or next to
/// another session's socket); an empty name is the default session.
#[uniffi::export]
pub fn session_socket_path(default_socket: String, name: String) -> Result<String, FfiError> {
    Ok(herdr_session::session_socket_path(&default_socket, &name)?)
}

/// The session name in `…/sessions/<name>/herdr.sock`, `None` otherwise.
#[uniffi::export]
pub fn session_name_of_socket(socket_path: String) -> Option<String> {
    herdr_session::session_name_of_socket(&socket_path)
}

/// Whether `name` can name a herdr session.
#[uniffi::export]
pub fn is_valid_session_name(name: String) -> bool {
    herdr_session::is_valid_session_name(&name)
}

/// The named herdr sessions on this machine, running or stopped. Empty on
/// systems without a local socket.
#[uniffi::export]
pub fn local_herdr_sessions() -> Result<Vec<HerdrSession>, FfiError> {
    #[cfg(unix)]
    {
        let sessions = runtime().block_on(herdr_session::local_herdr_sessions())?;
        Ok(sessions.into_iter().map(HerdrSession::from).collect())
    }
    #[cfg(not(unix))]
    Ok(Vec::new())
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
    session: herdr_session::Session,
}

#[uniffi::export]
impl HostSession {
    /// Connects in the background and reports to `observer` from then on.
    /// `group_spaces_by_name` is the host's setting for the "Bereich/Name"
    /// convention, `space_sort` its order of spaces, `None` for herdr's (see
    /// `herdr_core::spaces`).
    #[uniffi::constructor(default(group_spaces_by_name = true, space_sort = None))]
    pub fn start(
        endpoint: Endpoint,
        observer: Box<dyn SessionObserver>,
        group_spaces_by_name: bool,
        space_sort: Option<SpaceSort>,
    ) -> Result<Arc<Self>, FfiError> {
        let _entered = runtime().enter();
        let session = herdr_session::Session::start(
            endpoint.into(),
            group_spaces_by_name,
            space_sort.map(Into::into).unwrap_or_default(),
            move |update| {
                observer.on_update(update);
            },
        )?;
        Ok(Arc::new(Self { session }))
    }

    /// Switches grouping by "Bereich/Name" on or off; the observer gets a
    /// rebuilt update right away, without reconnecting.
    pub fn set_group_spaces_by_name(&self, on: bool) {
        self.session.set_group_spaces_by_name(on);
    }

    /// Changes the order of spaces; the observer gets a rebuilt update
    /// right away, without reconnecting.
    pub fn set_space_sort(&self, sort: SpaceSort) {
        self.session.set_space_sort(sort.into());
    }

    /// Ends the session and closes the connection. Pane followers stop too.
    pub fn stop(&self) {
        self.session.stop();
    }

    /// The address to open for a page an agent asked for (#247): a page on
    /// the host's `localhost` is forwarded through the connection to a port
    /// on this device, other URLs come back unchanged. Fails with `Forward`
    /// when the key's line does not allow it. Blocks for a moment; call it
    /// off the main thread.
    pub fn open_url(&self, url: String) -> Result<String, FfiError> {
        Ok(runtime().block_on(self.session.open_url(&url))?)
    }

    /// Takes an open request back on the host, so other devices stop
    /// offering it. Blocks for one round trip.
    pub fn dismiss_open_request(
        &self,
        pane_id: String,
        request_id: String,
    ) -> Result<(), FfiError> {
        Ok(runtime().block_on(self.session.dismiss_open_request(&pane_id, &request_id))?)
    }

    /// Sends a prompt to the agent in a pane, followed by Enter. Blocks for
    /// one round trip; call it off the main thread.
    pub fn send_prompt(&self, pane_id: String, text: String) -> Result<(), FfiError> {
        Ok(runtime().block_on(self.session.send_prompt(&pane_id, &text))?)
    }

    /// The last `max_lines` lines with text of a pane's visible screen,
    /// without styles, e.g. for the Watch (#156). Read only. Blocks for one
    /// round trip; call it off the main thread.
    pub fn screen_excerpt(&self, pane_id: String, max_lines: u32) -> Result<String, FfiError> {
        Ok(runtime().block_on(self.session.screen_excerpt(&pane_id, max_lines))?)
    }

    /// Sends logical keys (`enter`, `esc`, `1`, `ctrl+c`, ...) to a pane.
    /// Blocks for one round trip; call it off the main thread.
    pub fn send_keys(&self, pane_id: String, keys: Vec<String>) -> Result<(), FfiError> {
        Ok(runtime().block_on(self.session.send_keys(&pane_id, &keys))?)
    }

    /// Types text into a pane without Enter. Blocks for one round trip.
    pub fn send_text(&self, pane_id: String, text: String) -> Result<(), FfiError> {
        Ok(runtime().block_on(self.session.send_text(&pane_id, &text))?)
    }

    /// Creates a space with a shell in `cwd` (absolute path) and returns
    /// its first pane. Not focused in herdr's own client.
    pub fn create_workspace(
        &self,
        label: Option<String>,
        cwd: String,
    ) -> Result<Created, FfiError> {
        Ok(runtime()
            .block_on(self.session.create_workspace(label.as_deref(), &cwd))?
            .into())
    }

    /// Creates a tab in a space and returns its first pane.
    pub fn create_tab(
        &self,
        workspace_id: String,
        cwd: Option<String>,
    ) -> Result<Created, FfiError> {
        Ok(runtime()
            .block_on(self.session.create_tab(&workspace_id, cwd.as_deref()))?
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
        Ok(runtime()
            .block_on(
                self.session
                    .create_worktree(&workspace_id, &worktree.into()),
            )?
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
        Ok(runtime().block_on(self.session.start_agent(&pane_id, &kind, name.as_deref()))?)
    }

    /// Agent kinds the server can start, the usual ones first. Never fails:
    /// without an answer it returns the kinds herdr 0.9 knows.
    pub fn agent_kinds(&self) -> Vec<String> {
        runtime().block_on(self.session.agent_kinds())
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
        Ok(runtime().block_on(self.session.claude_history(&pane_id, before))?)
    }

    /// What changed in the working directory of a pane (#228): `git diff`
    /// against `HEAD` plus untracked files, read only. Runs a small script
    /// in a short-lived, unfocused tab and reads its output through SFTP,
    /// so it needs file access like uploads. Blocks for a moment; call it
    /// off the main thread.
    pub fn working_tree_diff(&self, pane_id: String) -> Result<WorkingTreeDiff, FfiError> {
        Ok(runtime().block_on(self.session.working_tree_diff(&pane_id))?)
    }

    /// The directory at the absolute `path` on the host, empty for the home
    /// directory (#259). Read only; paths outside the home directory fail.
    /// Needs file access like uploads. Blocks; call it off the main thread.
    pub fn list_directory(&self, path: String) -> Result<Directory, FfiError> {
        Ok(runtime().block_on(self.session.list_directory(&path))?)
    }

    /// The working directory of a pane for the file browser (#259), the
    /// home directory when none is known or it lies outside the home.
    /// Blocks; call it off the main thread.
    pub fn open_pane_directory(&self, pane_id: String) -> Result<Directory, FfiError> {
        Ok(runtime().block_on(self.session.open_pane_directory(&pane_id))?)
    }

    /// The file at the absolute `path` on the host to show (#259): text up
    /// to 1 MB, an image up to 10 MB, otherwise only size and name. Blocks;
    /// call it off the main thread.
    pub fn file_preview(&self, path: String) -> Result<FilePreview, FfiError> {
        Ok(runtime().block_on(self.session.file_preview(&path))?)
    }

    /// The transcript of a full-screen agent such as Claude Code as plain
    /// text, which herdr collects by scrolling the idle agent's view on the
    /// host; fails with `AgentWorking` otherwise. Blocks for a moment; call
    /// it off the main thread.
    pub fn agent_history(&self, pane_id: String) -> Result<PaneContent, FfiError> {
        Ok(runtime().block_on(self.session.agent_history(&pane_id))?)
    }

    /// Scrolls the view of a full-screen agent, also on the host; end with
    /// `ScrollStep::Bottom`. Blocks for one round trip.
    pub fn scroll_agent(&self, pane_id: String, step: ScrollStep) -> Result<(), FfiError> {
        Ok(runtime().block_on(self.session.scroll_agent(&pane_id, step))?)
    }

    /// Renames a space. Blocks for one round trip.
    pub fn rename_workspace(&self, workspace_id: String, label: String) -> Result<(), FfiError> {
        Ok(runtime().block_on(self.session.rename_workspace(&workspace_id, &label))?)
    }

    /// Renames a tab. Blocks for one round trip.
    pub fn rename_tab(&self, tab_id: String, label: String) -> Result<(), FfiError> {
        Ok(runtime().block_on(self.session.rename_tab(&tab_id, &label))?)
    }

    /// Closes a tab and what runs in it. Blocks for one round trip.
    pub fn close_tab(&self, tab_id: String) -> Result<(), FfiError> {
        Ok(runtime().block_on(self.session.close_tab(&tab_id))?)
    }

    /// Closes a space with all its tabs; `with_worktrees` also closes the
    /// linked worktree spaces of a repository's space, which herdr requires
    /// when there are any. Blocks for one round trip.
    pub fn close_workspace(
        &self,
        workspace_id: String,
        with_worktrees: bool,
    ) -> Result<(), FfiError> {
        Ok(runtime().block_on(self.session.close_workspace(&workspace_id, with_worktrees))?)
    }

    /// Names the agent in a pane; `None` or an empty name removes the name.
    /// herdr does not announce names with an event, so a fresh snapshot
    /// follows. Blocks for one round trip.
    pub fn rename_agent(&self, pane_id: String, name: Option<String>) -> Result<(), FfiError> {
        Ok(runtime().block_on(self.session.rename_agent(&pane_id, name.as_deref()))?)
    }

    /// Lets another device of the user (an Apple TV, #127) in: adds the
    /// restricted line for `public_openssh` (no shell, no files, only the
    /// herdr socket) with `comment` to `~/.ssh/authorized_keys` on the host.
    /// Returns false when the key was there already. Needs SFTP.
    pub fn authorize_device_key(
        &self,
        public_openssh: String,
        comment: String,
    ) -> Result<bool, FfiError> {
        Ok(runtime().block_on(self.session.authorize_device_key(&public_openssh, &comment))?)
    }

    /// The named herdr sessions on the host, running or stopped. Over SSH
    /// this needs SFTP. Blocks; call it off the main thread.
    pub fn herdr_sessions(&self) -> Result<Vec<HerdrSession>, FfiError> {
        let sessions = runtime().block_on(self.session.herdr_sessions())?;
        Ok(sessions.into_iter().map(HerdrSession::from).collect())
    }

    /// Uploads any file to `~/.amiscara-agents/uploads` under its own name,
    /// made unique and safe (`file-<time>-<name>`), and returns the absolute
    /// path. The name helps the agent tell what the file is.
    pub fn upload_named_file(&self, data: Vec<u8>, file_name: String) -> Result<String, FfiError> {
        Ok(runtime().block_on(self.session.upload_named_file(&data, &file_name))?)
    }

    /// Uploads a file (e.g. an image for a prompt) to `~/.amiscara-agents/uploads`
    /// on the host under a fresh name and returns its absolute path. Blocks
    /// until the upload is done; call it off the main thread.
    pub fn upload_file(&self, data: Vec<u8>, file_extension: String) -> Result<String, FfiError> {
        Ok(runtime().block_on(self.session.upload_file(&data, &file_extension))?)
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
        Arc::new(PaneFollow {
            follow: self.session.follow_pane(pane_id, live, Sink(observer)),
        })
    }
}

/// Hands what a follower reads to the app's observer.
struct Sink(Box<dyn PaneObserver>);

impl herdr_session::PaneSink for Sink {
    fn on_content(&self, content: PaneContent) {
        self.0.on_content(content);
    }

    fn on_error(&self, message: String) {
        self.0.on_error(message);
    }
}

/// Handle for [`HostSession::follow_pane`].
#[derive(uniffi::Object)]
pub struct PaneFollow {
    follow: herdr_session::PaneFollow,
}

#[uniffi::export]
impl PaneFollow {
    /// Ends following once a request in flight has finished; no content is
    /// reported after this.
    pub fn stop(&self) {
        self.follow.stop();
    }

    /// Switches between the fast pace of the selected pane and the slow one
    /// of a pane beside it. Switching reads the pane once right away.
    pub fn set_live(&self, live: bool) {
        self.follow.set_live(live);
    }

    /// Shows the last `lines` rows including scrollback instead of only the
    /// visible screen; 0 goes back to the screen. Capped at
    /// [`max_history_lines`]. Content with the new value follows at once.
    pub fn set_history_lines(&self, lines: u32) {
        self.follow.set_history_lines(lines);
    }

    /// Joins the rows the terminal wrapped at the pane width into whole
    /// lines, for a view that wraps them at its own width (#191). Content
    /// with the new value follows at once.
    pub fn set_unwrap(&self, unwrap: bool) {
        self.follow.set_unwrap(unwrap);
    }
}

fn key_error(err: TransportError) -> FfiError {
    FfiError::Key(err.to_string())
}

fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        #[cfg(target_os = "android")]
        log_panics_to_logcat();
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("herdr-core")
            .enable_all()
            .build()
            .unwrap_or_else(|err| panic!("cannot start the tokio runtime: {err}"))
    })
}

/// Android drops stderr, so a panic in a background task (which ends that
/// task quietly) would leave no trace. Writes panics to logcat, tag
/// `herdr-ffi`, before the default handling.
#[cfg(target_os = "android")]
fn log_panics_to_logcat() {
    android_logger::init_once(
        android_logger::Config::default()
            .with_tag("herdr-ffi")
            .with_max_level(log::LevelFilter::Warn),
    );
    let default = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        log::error!("{info}");
        default(info);
    }));
}
