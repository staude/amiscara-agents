//! Swift (and later Kotlin) face of the herdr-remote core, via UniFFI.
//!
//! The apps start one [`HostSession`] per host and get every state change
//! through a [`SessionObserver`]; an open pane is followed with
//! [`HostSession::follow_pane`]. Callbacks arrive on a background thread,
//! the app hops to its UI thread itself. Keys live in the app (Keychain) and
//! are handed over as OpenSSH text.

mod convert;

use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use herdr_core::pane::{self, Pacing};
use herdr_core::sync::{self, SyncState};
use herdr_transport::{Connection, HostKeyPolicy, Identity, SshTarget, TransportError, keys};
use tokio::runtime::Runtime;
use tokio::sync::watch;
use tokio::task::JoinHandle;

pub use convert::{
    AgentState, BoardItem, HostStatus, PaneContent, PaneItem, SessionUpdate, StyledLine,
    StyledSpan, TabItem, TermColor, WorkspaceItem,
};

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum FfiError {
    #[error("{0}")]
    Key(String),
    #[error("{0}")]
    Unsupported(String),
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

/// The `authorized_keys` line for a client key: no shell, no commands, no
/// PTY, no agent or X11 forwarding.
///
/// `port-forwarding` is needed for the streamlocal channel to `herdr.sock`,
/// but it also allows TCP forwarding through the server. `permitopen` cannot
/// narrow that: sshd applies it to streamlocal as well and then refuses the
/// socket (tested with OpenSSH 10.3). Closing TCP forwarding needs
/// `AllowTcpForwarding no` in `sshd_config`, which affects every login.
#[uniffi::export]
pub fn authorized_keys_line(public_openssh: String) -> Result<String, FfiError> {
    let key = keys::parse_public(public_openssh.trim()).map_err(key_error)?;
    let line = key
        .to_openssh()
        .map_err(|err| FfiError::Key(err.to_string()))?;
    Ok(format!(
        "restrict,port-forwarding,command=\"/usr/bin/false\" {line}"
    ))
}

/// Default `herdr.sock` path for a user on a macOS host.
#[uniffi::export]
pub fn default_remote_socket(user: String) -> String {
    format!("/Users/{user}/.config/herdr/herdr.sock")
}

#[uniffi::export]
pub fn supported_protocol() -> u32 {
    herdr_proto::SUPPORTED_PROTOCOL
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
    forward: JoinHandle<()>,
}

#[uniffi::export]
impl HostSession {
    /// Connects in the background and reports to `observer` from then on.
    #[uniffi::constructor]
    pub fn start(
        endpoint: Endpoint,
        observer: Box<dyn SessionObserver>,
    ) -> Result<Arc<Self>, FfiError> {
        let connector = Connector::new(endpoint)?;
        let runtime = runtime();
        let _entered = runtime.enter();
        let rx = sync::spawn(move || {
            let connector = connector.clone();
            async move { connector.connect().await }
        });
        let mut updates = rx.clone();
        let forward = runtime.spawn(async move {
            loop {
                let update = convert::session_update(&updates.borrow_and_update());
                observer.on_update(update);
                if updates.changed().await.is_err() {
                    return;
                }
            }
        });
        Ok(Arc::new(Self {
            state: Mutex::new(Some(rx)),
            forward,
        }))
    }

    /// Ends the session and closes the connection. Pane followers stop too.
    pub fn stop(&self) {
        self.forward.abort();
        if let Ok(mut state) = self.state.lock() {
            state.take();
        }
    }

    /// Follows the visible screen of a pane until the returned handle is
    /// stopped or dropped.
    pub fn follow_pane(&self, pane_id: String, observer: Box<dyn PaneObserver>) -> Arc<PaneFollow> {
        let state = self.state.lock().ok().and_then(|state| state.clone());
        let task = runtime().spawn(async move {
            let Some(mut state) = state else {
                return;
            };
            loop {
                let connection = state.borrow_and_update().connection.clone();
                if let Some(conn) = connection
                    && let Err(message) = follow_once(&conn, &pane_id, observer.as_ref()).await
                {
                    observer.on_error(message);
                }
                // Wait for a new connection, or retry after a pause on the same one.
                tokio::select! {
                    changed = state.changed() => if changed.is_err() { return },
                    () = tokio::time::sleep(Duration::from_secs(2)) => {}
                }
            }
        });
        Arc::new(PaneFollow { task })
    }
}

impl Drop for HostSession {
    fn drop(&mut self) {
        self.forward.abort();
    }
}

async fn follow_once(
    conn: &Connection,
    pane_id: &str,
    observer: &dyn PaneObserver,
) -> Result<(), String> {
    let (tx, mut rx) = watch::channel(None);
    let follow = pane::follow(conn, pane_id, Pacing::default(), &tx);
    let forward = async {
        while rx.changed().await.is_ok() {
            let screen = rx.borrow_and_update().clone();
            if let Some(screen) = screen {
                observer.on_content(convert::pane_content(&screen));
            }
        }
    };
    tokio::select! {
        result = follow => result.map_err(|err| err.to_string()),
        () = forward => Ok(()),
    }
}

/// Handle for [`HostSession::follow_pane`].
#[derive(uniffi::Object)]
pub struct PaneFollow {
    task: JoinHandle<()>,
}

#[uniffi::export]
impl PaneFollow {
    pub fn stop(&self) {
        self.task.abort();
    }
}

impl Drop for PaneFollow {
    fn drop(&mut self) {
        self.task.abort();
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
