//! Transports to a herdr server socket.
//!
//! `Local` talks to the Unix socket directly (Unix only). `Ssh` keeps one SSH session and
//! opens a `direct-streamlocal@openssh.com` channel per request, which is the
//! same path `herdr --remote` uses. Nothing has to be installed on the server.

pub mod keys;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use herdr_proto::{ProtoError, Request};
use russh::client::{self, AuthResult, Handle};
use russh::keys::agent::client::AgentClient;
use russh::keys::{
    HashAlg, PrivateKey, PrivateKeyWithHashAlg, PublicKey, PublicKeyOrCertificate, known_hosts,
    load_secret_key,
};
use russh_sftp::client::SftpSession;
use russh_sftp::protocol::{FileAttributes, OpenFlags};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};

#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Ssh(#[from] russh::Error),
    #[error(transparent)]
    Proto(#[from] ProtoError),
    #[error("ssh key error: {0}")]
    Key(String),
    #[error("ssh authentication failed for {0}")]
    AuthFailed(String),
    #[error("connection closed before a response arrived")]
    Closed,
    /// The server presented a key nobody has trusted yet. Show the
    /// fingerprint, ask, and pin `key` on consent.
    #[error("unknown host key for {host}: {fingerprint}")]
    UnknownHostKey {
        host: String,
        key: String,
        fingerprint: String,
    },
    /// SFTP is not available: the key's forced command is not `sftp-server`,
    /// or the upload failed on the server.
    #[error("file upload failed: {0}")]
    Upload(String),
    /// Reading files failed: no SFTP (as for uploads), or the file or
    /// directory is missing or not readable.
    #[error("file access failed: {0}")]
    Files(String),
    /// The connection may not reach ports on the host: the key's line
    /// lacks the `amiscara-tcp` case (or sshd forbids TCP forwarding), or
    /// the connection is local.
    #[error("port forwarding failed: {0}")]
    Forward(String),
    /// The server presented a different key than the trusted one.
    #[error("host key for {host} changed, it is now {fingerprint}")]
    HostKeyChanged {
        host: String,
        key: String,
        fingerprint: String,
    },
    /// The SSH connection did not open a channel within
    /// [`CHANNEL_OPEN_TIMEOUT`]; it is asked to close, so the session
    /// reconnects.
    #[error("timed out opening a channel to herdr")]
    Timeout,
}

impl TransportError {
    /// Errors that a retry cannot fix without a decision by the user.
    pub fn needs_user(&self) -> bool {
        matches!(
            self,
            Self::UnknownHostKey { .. }
                | Self::HostKeyChanged { .. }
                | Self::AuthFailed(_)
                | Self::Key(_)
        )
    }
}

trait Stream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Stream for T {}

#[derive(Clone)]
pub enum Identity {
    /// Private key file in OpenSSH format, unencrypted.
    File(PathBuf),
    /// The SSH agent (`SSH_AUTH_SOCK`, on Windows the OpenSSH named pipe).
    Agent,
    /// A key held in memory, for example loaded from the Keychain.
    Key(Arc<PrivateKey>),
}

impl std::fmt::Debug for Identity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::File(path) => f.debug_tuple("File").field(path).finish(),
            Self::Agent => f.write_str("Agent"),
            Self::Key(_) => f.write_str("Key(..)"),
        }
    }
}

#[derive(Debug, Clone)]
pub enum HostKeyPolicy {
    /// An OpenSSH `known_hosts` file. With `accept_new`, unknown keys are
    /// recorded (trust on first use); changed keys are always refused.
    KnownHostsFile { path: PathBuf, accept_new: bool },
    /// Exactly this key, as an OpenSSH public key line. `None` trusts
    /// nothing yet, so the first contact ends in `UnknownHostKey`.
    Pinned(Option<String>),
}

#[derive(Debug, Clone)]
pub struct SshTarget {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub identity: Identity,
    pub host_key: HostKeyPolicy,
}

struct HostKeyCheck {
    host: String,
    port: u16,
    policy: HostKeyPolicy,
    /// Why a key was refused, read after the handshake failed.
    refusal: Arc<Mutex<Option<TransportError>>>,
}

impl HostKeyCheck {
    fn refuse(&self, error: TransportError) -> Result<bool, russh::Error> {
        if let Ok(mut refusal) = self.refusal.lock() {
            *refusal = Some(error);
        }
        Ok(false)
    }
}

impl client::Handler for HostKeyCheck {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_key: &PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        // Host certificates are not supported yet; only plain host keys.
        if server_key.certificate().is_some() {
            return Ok(false);
        }
        let server_public_key = server_key.public_key();
        let presented = || {
            (
                server_public_key.to_openssh().unwrap_or_default(),
                server_public_key.fingerprint(HashAlg::Sha256).to_string(),
            )
        };
        let unknown = || {
            let (key, fingerprint) = presented();
            TransportError::UnknownHostKey {
                host: self.host.clone(),
                key,
                fingerprint,
            }
        };
        let changed = || {
            let (key, fingerprint) = presented();
            TransportError::HostKeyChanged {
                host: self.host.clone(),
                key,
                fingerprint,
            }
        };
        match &self.policy {
            HostKeyPolicy::Pinned(None) => self.refuse(unknown()),
            HostKeyPolicy::Pinned(Some(line)) => match PublicKey::from_openssh(line) {
                Ok(pinned) if pinned.key_data() == server_public_key.key_data() => Ok(true),
                _ => self.refuse(changed()),
            },
            HostKeyPolicy::KnownHostsFile { path, accept_new } => {
                match known_hosts::check_known_hosts_path(
                    &self.host,
                    self.port,
                    &server_public_key,
                    path,
                ) {
                    Ok(true) => Ok(true),
                    Ok(false) if *accept_new => {
                        known_hosts::learn_known_hosts_path(
                            &self.host,
                            self.port,
                            &server_public_key,
                            path,
                        )
                        .map_err(|e| russh::Error::IO(std::io::Error::other(e.to_string())))?;
                        Ok(true)
                    }
                    Ok(false) => self.refuse(unknown()),
                    Err(russh::keys::Error::KeyChanged { .. }) => self.refuse(changed()),
                    Err(_) => self.refuse(unknown()),
                }
            }
        }
    }
}

enum Inner {
    #[cfg(unix)]
    Local(PathBuf),
    Ssh {
        handle: Handle<HostKeyCheck>,
        socket_path: String,
        /// Set once sshd refused a streamlocal channel: the key's line has no
        /// `port-forwarding` but a forced command that connects every
        /// session to `herdr.sock` (#132). Requests then go over a session
        /// channel running `herdr`.
        gated: std::sync::atomic::AtomicBool,
        /// The same for `direct-tcpip`: TCP then goes over a session channel
        /// running `amiscara-tcp <port>`, which the key's line answers with
        /// `nc localhost <port>` when it allows web forwarding.
        tcp_gated: std::sync::atomic::AtomicBool,
        /// Uploads running on this connection. While their data waits for
        /// the window, russh queues a channel open behind it, so
        /// [`CHANNEL_OPEN_TIMEOUT`] does not apply then. Port forwards are
        /// not counted: an idle one would switch the limit off for hours.
        transfers: AtomicUsize,
    },
}

/// Counts a transfer in `Inner::Ssh::transfers` while it lives.
struct Transfer<'a>(Option<&'a AtomicUsize>);

impl<'a> Transfer<'a> {
    fn start(inner: &'a Inner) -> Self {
        match inner {
            #[cfg(unix)]
            Inner::Local(_) => Self(None),
            Inner::Ssh { transfers, .. } => {
                transfers.fetch_add(1, Ordering::Relaxed);
                Self(Some(transfers))
            }
        }
    }
}

impl Drop for Transfer<'_> {
    fn drop(&mut self) {
        if let Some(transfers) = self.0 {
            transfers.fetch_sub(1, Ordering::Relaxed);
        }
    }
}

/// A connection to one herdr server.
pub struct Connection {
    inner: Inner,
    next_id: AtomicU64,
}

impl Connection {
    #[cfg(unix)]
    pub fn local(socket_path: impl Into<PathBuf>) -> Self {
        Self {
            inner: Inner::Local(socket_path.into()),
            next_id: AtomicU64::new(1),
        }
    }

    /// Default socket path for the current user on this machine.
    #[cfg(unix)]
    pub fn default_local_socket() -> Option<PathBuf> {
        dirs::home_dir().map(|home| home.join(".config/herdr/herdr.sock"))
    }

    pub async fn ssh(target: &SshTarget, socket_path: String) -> Result<Self, TransportError> {
        let config = Arc::new(client::Config {
            inactivity_timeout: None,
            keepalive_interval: Some(Duration::from_secs(15)),
            nodelay: true,
            ..Default::default()
        });
        let refusal = Arc::new(Mutex::new(None));
        let check = HostKeyCheck {
            host: target.host.clone(),
            port: target.port,
            policy: target.host_key.clone(),
            refusal: Arc::clone(&refusal),
        };
        let mut handle =
            match client::connect(config, (target.host.as_str(), target.port), check).await {
                Ok(handle) => handle,
                Err(err) => {
                    let refused = refusal.lock().ok().and_then(|mut r| r.take());
                    return Err(refused.unwrap_or(TransportError::Ssh(err)));
                }
            };

        let authenticated = match &target.identity {
            Identity::File(path) => authenticate_with_file(&mut handle, &target.user, path).await?,
            Identity::Agent => authenticate_with_agent(&mut handle, &target.user).await?,
            Identity::Key(key) => {
                authenticate_with_key(&mut handle, &target.user, Arc::clone(key)).await?
            }
        };
        if !authenticated {
            return Err(TransportError::AuthFailed(format!(
                "{}@{}",
                target.user, target.host
            )));
        }

        Ok(Self {
            inner: Inner::Ssh {
                handle,
                socket_path,
                gated: std::sync::atomic::AtomicBool::new(false),
                tcp_gated: std::sync::atomic::AtomicBool::new(false),
                transfers: AtomicUsize::new(0),
            },
            next_id: AtomicU64::new(1),
        })
    }

    async fn open(&self) -> Result<Box<dyn Stream>, TransportError> {
        match &self.inner {
            #[cfg(unix)]
            Inner::Local(path) => Ok(Box::new(tokio::net::UnixStream::connect(path).await?)),
            Inner::Ssh {
                handle,
                socket_path,
                gated,
                transfers,
                ..
            } => {
                let open = async {
                    if !gated.load(Ordering::Relaxed) {
                        match handle
                            .channel_open_direct_streamlocal(socket_path.clone())
                            .await
                        {
                            Ok(channel) => {
                                return Ok::<Box<dyn Stream>, TransportError>(Box::new(
                                    channel.into_stream(),
                                ));
                            }
                            // No port forwarding for this key: try the gate.
                            Err(russh::Error::ChannelOpenFailure(_)) => {
                                gated.store(true, Ordering::Relaxed)
                            }
                            Err(err) => return Err(err.into()),
                        }
                    }
                    let channel = handle.channel_open_session().await?;
                    channel.exec(true, "herdr").await?;
                    Ok(Box::new(channel.into_stream()))
                };
                if transfers.load(Ordering::Relaxed) > 0 {
                    return open.await;
                }
                match tokio::time::timeout(CHANNEL_OPEN_TIMEOUT, open).await {
                    Ok(result) => result,
                    // A link that died while the device slept answers nothing
                    // until the keepalives give up a minute later. Close it so
                    // the session reconnects instead of every read hanging (#258).
                    Err(_) => {
                        let _ = tokio::time::timeout(
                            Duration::from_secs(2),
                            handle.disconnect(
                                russh::Disconnect::ByApplication,
                                "channel open timed out",
                                "",
                            ),
                        )
                        .await;
                        Err(TransportError::Timeout)
                    }
                }
            }
        }
    }

    /// A channel to `localhost:<port>` on the host. Over the gate the
    /// key's line first answers with [`TCP_GATE_READY`]; without it (an
    /// older line, or a shell without `amiscara-tcp`) this fails within
    /// [`TCP_GATE_TIMEOUT`] instead of handing out a stream to `herdr.sock`.
    async fn open_tcp(&self, port: u16) -> Result<BufReader<Box<dyn Stream>>, TransportError> {
        // A `match`, since on Windows `Ssh` is the only variant.
        let (handle, tcp_gated) = match &self.inner {
            #[cfg(unix)]
            Inner::Local(_) => {
                return Err(TransportError::Forward(
                    "a local connection has nothing to forward".into(),
                ));
            }
            Inner::Ssh {
                handle, tcp_gated, ..
            } => (handle, tcp_gated),
        };
        if !tcp_gated.load(Ordering::Relaxed) {
            match handle
                .channel_open_direct_tcpip("localhost", u32::from(port), "127.0.0.1", 0)
                .await
            {
                Ok(channel) => {
                    let stream: Box<dyn Stream> = Box::new(channel.into_stream());
                    return Ok(BufReader::new(stream));
                }
                // `restrict` in the key's line: try the gate.
                Err(russh::Error::ChannelOpenFailure(
                    russh::ChannelOpenFailure::AdministrativelyProhibited,
                )) => tcp_gated.store(true, Ordering::Relaxed),
                Err(russh::Error::ChannelOpenFailure(russh::ChannelOpenFailure::ConnectFailed)) => {
                    return Err(TransportError::Io(std::io::Error::new(
                        std::io::ErrorKind::ConnectionRefused,
                        format!("nothing answers on localhost:{port} on the host"),
                    )));
                }
                Err(err) => return Err(err.into()),
            }
        }
        let channel = handle.channel_open_session().await?;
        channel.exec(true, format!("amiscara-tcp {port}")).await?;
        let stream: Box<dyn Stream> = Box::new(channel.into_stream());
        let mut reader = BufReader::new(stream);
        let refused = || {
            TransportError::Forward(
                "the host does not forward localhost for this key; renew its authorized_keys line"
                    .into(),
            )
        };
        let mut line = String::new();
        match tokio::time::timeout(TCP_GATE_TIMEOUT, reader.read_line(&mut line)).await {
            Ok(Ok(_)) if line.trim_end() == TCP_GATE_READY => Ok(reader),
            Ok(Ok(_)) if line.trim_end() == TCP_GATE_CLOSED => {
                Err(TransportError::Io(std::io::Error::new(
                    std::io::ErrorKind::ConnectionRefused,
                    format!("nothing answers on localhost:{port} on the host"),
                )))
            }
            Ok(Err(err)) => Err(err.into()),
            _ => Err(refused()),
        }
    }

    /// Whether TCP goes through the `amiscara-tcp` gate, so every tunnel
    /// takes an SSH session channel; known after the first attempt.
    pub fn tcp_gated(&self) -> bool {
        match &self.inner {
            #[cfg(unix)]
            Inner::Local(_) => false,
            Inner::Ssh { tcp_gated, .. } => tcp_gated.load(Ordering::Relaxed),
        }
    }

    /// Checks that `localhost:<port>` on the host can be reached, with one
    /// short connection to it.
    pub async fn check_tcp(&self, port: u16) -> Result<(), TransportError> {
        let mut stream = self.open_tcp(port).await?;
        let _ = stream.shutdown().await;
        Ok(())
    }

    /// Connects `local` with `localhost:<port>` on the host until either
    /// side closes. Over SSH a `direct-tcpip` channel, for keys with the
    /// restricted line the `amiscara-tcp` gate.
    pub async fn forward_tcp(
        &self,
        port: u16,
        mut local: tokio::net::TcpStream,
    ) -> Result<(), TransportError> {
        let mut remote = self.open_tcp(port).await?;
        tokio::io::copy_bidirectional(&mut local, &mut remote).await?;
        Ok(())
    }

    /// Opens the channel for one future request ahead of time.
    pub async fn open_channel(&self) -> Result<Channel, TransportError> {
        Ok(Channel(self.open().await?))
    }

    async fn send_on(
        &self,
        channel: Channel,
        method: &str,
        params: Value,
    ) -> Result<BufReader<Box<dyn Stream>>, TransportError> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed).to_string();
        let line = Request {
            id: &id,
            method,
            params,
        }
        .to_line()?;
        let mut stream = channel.0;
        stream.write_all(&line).await?;
        stream.flush().await?;
        Ok(BufReader::new(stream))
    }

    async fn send(
        &self,
        method: &str,
        params: Value,
    ) -> Result<BufReader<Box<dyn Stream>>, TransportError> {
        let channel = self.open_channel().await?;
        self.send_on(channel, method, params).await
    }

    /// Sends one request and returns its `result` payload.
    pub async fn request(&self, method: &str, params: Value) -> Result<Value, TransportError> {
        let channel = self.open_channel().await?;
        self.request_on(channel, method, params).await
    }

    /// Sends one request on a channel from [`Connection::open_channel`].
    pub async fn request_on(
        &self,
        channel: Channel,
        method: &str,
        params: Value,
    ) -> Result<Value, TransportError> {
        let mut reader = self.send_on(channel, method, params).await?;
        let line = read_line(&mut reader)
            .await?
            .ok_or(TransportError::Closed)?;
        Ok(herdr_proto::parse_response(&line)?)
    }

    /// Opens an event subscription. The acknowledgement is checked before
    /// the subscription is returned.
    pub async fn subscribe(&self, types: &[&str]) -> Result<Subscription, TransportError> {
        let subscriptions: Vec<Value> = types
            .iter()
            .map(|t| serde_json::json!({ "type": t }))
            .collect();
        self.subscribe_to(subscriptions).await
    }

    /// Uploads a file into `dir` below the login's home directory (created
    /// if missing) and returns its absolute path on the server. Over SSH this
    /// uses SFTP on the same session, which needs a key whose forced command
    /// is `sftp-server`; locally it writes the file directly. Uploads can be
    /// private screenshots: every directory of `dir` gets mode 0700 and the
    /// file 0600, also when they existed before.
    pub async fn upload(
        &self,
        dir: &str,
        file_name: &str,
        data: &[u8],
    ) -> Result<String, TransportError> {
        if file_name.is_empty() || file_name.contains('/') || file_name.starts_with('.') {
            return Err(TransportError::Upload(format!(
                "invalid file name {file_name:?}"
            )));
        }
        match &self.inner {
            #[cfg(unix)]
            Inner::Local(_) => {
                use std::os::unix::fs::PermissionsExt;
                use tokio::io::AsyncWriteExt;

                let home = dirs::home_dir()
                    .ok_or_else(|| TransportError::Upload("no home directory".into()))?;
                let mut path = home;
                for part in dir.split('/').filter(|part| !part.is_empty()) {
                    path.push(part);
                    tokio::fs::DirBuilder::new()
                        .mode(0o700)
                        .recursive(true)
                        .create(&path)
                        .await?;
                    tokio::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
                        .await?;
                }
                path.push(file_name);
                let mut file = tokio::fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(&path)
                    .await?;
                file.write_all(data).await?;
                file.flush().await?;
                Ok(path.to_string_lossy().into_owned())
            }
            Inner::Ssh { handle, .. } => {
                let _transfer = Transfer::start(&self.inner);
                sftp_upload(handle, dir, file_name, data).await
            }
        }
    }

    /// Adds `line` to `~/.ssh/authorized_keys` unless a line already holds
    /// `key_blob` (the base64 part of the key); returns whether it was added.
    /// The previous file is kept as `authorized_keys.bak-amiscara`, the new
    /// one gets mode 0600 (`.ssh` 0700). Over SSH this needs SFTP.
    pub async fn add_authorized_key(
        &self,
        line: &str,
        key_blob: &str,
    ) -> Result<bool, TransportError> {
        if line.contains('\n') || key_blob.is_empty() || !line.contains(key_blob) {
            return Err(TransportError::Upload(
                "invalid authorized_keys line".into(),
            ));
        }
        match &self.inner {
            #[cfg(unix)]
            Inner::Local(_) => {
                use std::os::unix::fs::PermissionsExt;

                let dir = local_home_path(".ssh")?;
                tokio::fs::DirBuilder::new()
                    .mode(0o700)
                    .recursive(true)
                    .create(&dir)
                    .await?;
                let path = dir.join("authorized_keys");
                let current = match tokio::fs::read_to_string(&path).await {
                    Ok(text) => text,
                    Err(err) if err.kind() == std::io::ErrorKind::NotFound => String::new(),
                    Err(err) => return Err(err.into()),
                };
                let Some(next) = with_authorized_key(&current, line, key_blob) else {
                    return Ok(false);
                };
                let backup = dir.join("authorized_keys.bak-amiscara");
                tokio::fs::write(&backup, &current).await?;
                tokio::fs::set_permissions(&backup, std::fs::Permissions::from_mode(0o600)).await?;
                tokio::fs::write(&path, next).await?;
                tokio::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).await?;
                Ok(true)
            }
            Inner::Ssh { handle, .. } => sftp_add_authorized_key(handle, line, key_blob).await,
        }
    }

    /// Files in `dir` below the login's home directory, without
    /// subdirectories. Over SSH this needs SFTP like [`Connection::upload`].
    pub async fn list_files(&self, dir: &str) -> Result<Vec<RemoteFile>, TransportError> {
        match &self.inner {
            #[cfg(unix)]
            Inner::Local(_) => {
                let path = local_home_path(dir)?;
                let mut entries = tokio::fs::read_dir(&path)
                    .await
                    .map_err(|err| TransportError::Files(format!("{}: {err}", path.display())))?;
                let mut files = Vec::new();
                while let Some(entry) = entries.next_entry().await? {
                    let meta = entry.metadata().await?;
                    if !meta.is_file() {
                        continue;
                    }
                    files.push(RemoteFile {
                        name: entry.file_name().to_string_lossy().into_owned(),
                        size: meta.len(),
                        modified: meta
                            .modified()
                            .ok()
                            .and_then(|at| at.duration_since(std::time::UNIX_EPOCH).ok())
                            .map_or(0, |at| at.as_secs()),
                    });
                }
                Ok(files)
            }
            Inner::Ssh { handle, .. } => sftp_list(handle, dir).await,
        }
    }

    /// The named herdr sessions of the login (#213): the directories in
    /// `~/.config/herdr/sessions`, each running when its `herdr.sock`
    /// exists. Locally a socket only counts when it accepts a connection,
    /// so a stale file from a crashed server reads as stopped. Over SSH this
    /// needs SFTP like [`Connection::upload`]. No directory means none.
    pub async fn herdr_sessions(&self) -> Result<Vec<HerdrSessionEntry>, TransportError> {
        match &self.inner {
            #[cfg(unix)]
            Inner::Local(_) => local_herdr_sessions().await,
            Inner::Ssh { handle, .. } => Ok(tidy_sessions(sftp_herdr_sessions(handle).await?)),
        }
    }

    /// Up to `len` bytes of the file `path` (below the home directory) from
    /// `offset`; fewer at its end.
    pub async fn read_file_range(
        &self,
        path: &str,
        offset: u64,
        len: u64,
    ) -> Result<Vec<u8>, TransportError> {
        use tokio::io::{AsyncReadExt, AsyncSeekExt};

        match &self.inner {
            #[cfg(unix)]
            Inner::Local(_) => {
                let path = local_home_path(path)?;
                let mut file = tokio::fs::File::open(&path)
                    .await
                    .map_err(|err| TransportError::Files(format!("{}: {err}", path.display())))?;
                file.seek(std::io::SeekFrom::Start(offset)).await?;
                let mut data = Vec::new();
                file.take(len).read_to_end(&mut data).await?;
                Ok(data)
            }
            Inner::Ssh { handle, .. } => {
                let sftp = sftp_session(handle, TransportError::Files).await?;
                let failed =
                    |err: russh_sftp::client::error::Error| TransportError::Files(err.to_string());
                let home = sftp.canonicalize(".").await.map_err(failed)?;
                let target = format!(
                    "{}/{}",
                    home.trim_end_matches('/'),
                    path.trim_start_matches('/')
                );
                let mut file = sftp
                    .open_with_flags(target.as_str(), OpenFlags::READ)
                    .await
                    .map_err(failed)?;
                file.seek(std::io::SeekFrom::Start(offset)).await?;
                let mut data = Vec::new();
                (&mut file).take(len).read_to_end(&mut data).await?;
                drop(file);
                sftp.close().await.map_err(failed)?;
                Ok(data)
            }
        }
    }

    /// The directory at the absolute `path` with its subdirectories and
    /// files (#259); empty for the home directory. The real path (links
    /// resolved) has to lie below the real home directory, otherwise
    /// [`TransportError::Files`] ends with [`OUTSIDE_HOME`]. Links in the
    /// directory count as what they point to; broken ones as
    /// [`EntryKind::Other`]. Over SSH this needs SFTP like
    /// [`Connection::upload`].
    pub async fn list_dir(&self, path: &str) -> Result<DirListing, TransportError> {
        match &self.inner {
            #[cfg(unix)]
            Inner::Local(_) => {
                let (home, target) = local_real_path(path).await?;
                let mut read = tokio::fs::read_dir(&target)
                    .await
                    .map_err(|err| TransportError::Files(format!("{target}: {err}")))?;
                let mut entries = Vec::new();
                while let Some(entry) = read
                    .next_entry()
                    .await
                    .map_err(|err| TransportError::Files(format!("{target}: {err}")))?
                {
                    // Follows a link; a broken one falls back to the link.
                    let meta = match tokio::fs::metadata(entry.path()).await {
                        Ok(meta) => Some(meta),
                        Err(_) => entry.metadata().await.ok(),
                    };
                    let kind = match &meta {
                        Some(meta) if meta.is_dir() => EntryKind::Dir,
                        Some(meta) if meta.is_file() => EntryKind::File,
                        _ => EntryKind::Other,
                    };
                    entries.push(DirEntry {
                        name: entry.file_name().to_string_lossy().into_owned(),
                        kind,
                        size: meta.as_ref().map_or(0, std::fs::Metadata::len),
                        modified: meta.as_ref().map_or(0, local_modified),
                    });
                }
                Ok(DirListing {
                    home,
                    path: target,
                    entries,
                })
            }
            Inner::Ssh { handle, .. } => sftp_list_dir(handle, path).await,
        }
    }

    /// The start of the file at the absolute `path` (#259): `len` gets its
    /// size and returns how many bytes to read from its beginning. Same
    /// rules for the path as [`Connection::list_dir`]; only regular files.
    pub async fn read_file_head(
        &self,
        path: &str,
        len: impl FnOnce(u64) -> u64,
    ) -> Result<FileHead, TransportError> {
        use tokio::io::AsyncReadExt;

        match &self.inner {
            #[cfg(unix)]
            Inner::Local(_) => {
                let (_, target) = local_real_path(path).await?;
                let meta = tokio::fs::metadata(&target)
                    .await
                    .map_err(|err| TransportError::Files(format!("{target}: {err}")))?;
                if !meta.is_file() {
                    return Err(TransportError::Files(format!("{target} is not a file")));
                }
                let file = tokio::fs::File::open(&target)
                    .await
                    .map_err(|err| TransportError::Files(format!("{target}: {err}")))?;
                let mut data = Vec::new();
                file.take(len(meta.len()))
                    .read_to_end(&mut data)
                    .await
                    .map_err(|err| TransportError::Files(format!("{target}: {err}")))?;
                Ok(FileHead {
                    path: target,
                    size: meta.len(),
                    modified: local_modified(&meta),
                    data,
                })
            }
            Inner::Ssh { handle, .. } => {
                let sftp = sftp_session(handle, TransportError::Files).await?;
                let failed =
                    |err: russh_sftp::client::error::Error| TransportError::Files(err.to_string());
                let (_, target) = sftp_real_path(&sftp, path).await?;
                let meta = sftp
                    .metadata(target.as_str())
                    .await
                    .map_err(|err| TransportError::Files(format!("{target}: {err}")))?;
                if !meta.file_type().is_file() {
                    return Err(TransportError::Files(format!("{target} is not a file")));
                }
                let size = meta.size.unwrap_or(0);
                let mut file = sftp
                    .open_with_flags(target.as_str(), OpenFlags::READ)
                    .await
                    .map_err(|err| TransportError::Files(format!("{target}: {err}")))?;
                let mut data = Vec::new();
                (&mut file)
                    .take(len(size))
                    .read_to_end(&mut data)
                    .await
                    .map_err(|err| TransportError::Files(format!("{target}: {err}")))?;
                drop(file);
                sftp.close().await.map_err(failed)?;
                Ok(FileHead {
                    path: target,
                    size,
                    modified: meta.mtime.map_or(0, u64::from),
                    data,
                })
            }
        }
    }

    /// Deletes the file `path` below the home directory; a missing file is
    /// no error. Over SSH this needs SFTP like [`Connection::upload`].
    pub async fn remove_file(&self, path: &str) -> Result<(), TransportError> {
        match &self.inner {
            #[cfg(unix)]
            Inner::Local(_) => {
                let path = local_home_path(path)?;
                match tokio::fs::remove_file(&path).await {
                    Err(err) if err.kind() != std::io::ErrorKind::NotFound => {
                        Err(TransportError::Files(format!("{}: {err}", path.display())))
                    }
                    _ => Ok(()),
                }
            }
            Inner::Ssh { handle, .. } => {
                let sftp = sftp_session(handle, TransportError::Files).await?;
                let failed =
                    |err: russh_sftp::client::error::Error| TransportError::Files(err.to_string());
                let home = sftp.canonicalize(".").await.map_err(failed)?;
                let target = format!(
                    "{}/{}",
                    home.trim_end_matches('/'),
                    path.trim_start_matches('/')
                );
                if sftp.try_exists(target.as_str()).await.map_err(failed)? {
                    sftp.remove_file(target.as_str()).await.map_err(failed)?;
                }
                sftp.close().await.map_err(failed)?;
                Ok(())
            }
        }
    }

    /// Like [`Connection::subscribe`], with full subscription objects such as
    /// `{"type": "pane.agent_status_changed", "pane_id": "w1:p1"}`.
    pub async fn subscribe_to(
        &self,
        subscriptions: Vec<Value>,
    ) -> Result<Subscription, TransportError> {
        let mut reader = self
            .send(
                "events.subscribe",
                serde_json::json!({ "subscriptions": subscriptions }),
            )
            .await?;
        let ack = read_line(&mut reader)
            .await?
            .ok_or(TransportError::Closed)?;
        herdr_proto::parse_response(&ack)?;
        Ok(Subscription { reader })
    }
}

/// An open channel to the server socket, good for exactly one request.
pub struct Channel(Box<dyn Stream>);

/// A running event stream. [`Subscription::next`] is not cancel-safe: a
/// cancelled call can lose a partly read line, so read it from its own task
/// rather than inside `select!`.
pub struct Subscription {
    reader: BufReader<Box<dyn Stream>>,
}

impl Subscription {
    /// Next event, or `None` when the server closed the stream.
    pub async fn next(&mut self) -> Result<Option<Value>, TransportError> {
        match read_line(&mut self.reader).await? {
            Some(line) => Ok(Some(serde_json::from_str(&line).map_err(ProtoError::from)?)),
            None => Ok(None),
        }
    }
}

/// What the `amiscara-tcp` case of a key's line prints before it connects.
pub const TCP_GATE_READY: &str = "amiscara-tcp";
/// What it prints instead when nothing listens on the port.
pub const TCP_GATE_CLOSED: &str = "amiscara-tcp-closed";
/// How long the gate may take to answer.
const TCP_GATE_TIMEOUT: Duration = Duration::from_secs(5);
/// How long opening a channel for a herdr request may take over SSH.
/// Uploads, port forwards and the requests themselves have no such limit,
/// and none applies while an upload runs.
const CHANNEL_OPEN_TIMEOUT: Duration = Duration::from_secs(10);

/// Where herdr keeps its named sessions, below the home directory.
pub const HERDR_SESSIONS_DIR: &str = ".config/herdr/sessions";

/// A named herdr session from [`Connection::herdr_sessions`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HerdrSessionEntry {
    pub name: String,
    /// Whether its server runs, i.e. its socket is there.
    pub running: bool,
}

/// A file from [`Connection::list_files`].
#[derive(Debug, Clone)]
pub struct RemoteFile {
    pub name: String,
    pub size: u64,
    /// Seconds since 1970, 0 if unknown.
    pub modified: u64,
}

/// How the message of [`TransportError::Files`] ends when a path of
/// [`Connection::list_dir`] or [`Connection::read_file_head`] leads out of
/// the home directory.
pub const OUTSIDE_HOME: &str = "is outside the home directory";

/// A directory from [`Connection::list_dir`]; paths are real and absolute.
#[derive(Debug, Clone)]
pub struct DirListing {
    pub home: String,
    pub path: String,
    /// In the order the server lists them.
    pub entries: Vec<DirEntry>,
}

/// An entry of a [`DirListing`].
#[derive(Debug, Clone)]
pub struct DirEntry {
    pub name: String,
    pub kind: EntryKind,
    pub size: u64,
    /// Seconds since 1970, 0 if unknown.
    pub modified: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryKind {
    File,
    Dir,
    /// A broken link, a socket, a device and the like.
    Other,
}

/// The start of a file from [`Connection::read_file_head`].
#[derive(Debug, Clone)]
pub struct FileHead {
    /// The real, absolute path.
    pub path: String,
    /// The whole file's size.
    pub size: u64,
    /// Seconds since 1970, 0 if unknown.
    pub modified: u64,
    pub data: Vec<u8>,
}

/// Whether the absolute `path` is `home` or lies below it, compared per
/// component. Both are real paths; `..` counts as outside.
fn inside_home(home: &str, path: &str) -> bool {
    let mut parts = path.split('/').filter(|part| !part.is_empty());
    if path.split('/').any(|part| part == "..") {
        return false;
    }
    home.split('/')
        .filter(|part| !part.is_empty())
        .all(|part| parts.next() == Some(part))
}

/// `dir` and `name` joined with one `/`.
fn join_path(dir: &str, name: &str) -> String {
    format!("{}/{name}", dir.trim_end_matches('/'))
}

/// The real home directory and the real `path` (the home when empty),
/// checked to lie below it.
#[cfg(unix)]
async fn local_real_path(path: &str) -> Result<(String, String), TransportError> {
    let home = dirs::home_dir().ok_or_else(|| TransportError::Files("no home directory".into()))?;
    real_path_below(&home, path).await
}

/// [`local_real_path`] with `home` given, for tests.
#[cfg(unix)]
async fn real_path_below(home: &Path, path: &str) -> Result<(String, String), TransportError> {
    let home = tokio::fs::canonicalize(home)
        .await
        .map_err(|err| TransportError::Files(format!("{}: {err}", home.display())))?
        .to_string_lossy()
        .into_owned();
    let target = if path.is_empty() {
        home.clone()
    } else {
        tokio::fs::canonicalize(path)
            .await
            .map_err(|err| TransportError::Files(format!("{path}: {err}")))?
            .to_string_lossy()
            .into_owned()
    };
    if !inside_home(&home, &target) {
        return Err(TransportError::Files(format!("{path} {OUTSIDE_HOME}")));
    }
    Ok((home, target))
}

#[cfg(unix)]
fn local_modified(meta: &std::fs::Metadata) -> u64 {
    meta.modified()
        .ok()
        .and_then(|at| at.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |at| at.as_secs())
}

/// Like [`local_real_path`], on the server.
async fn sftp_real_path(
    sftp: &SftpSession,
    path: &str,
) -> Result<(String, String), TransportError> {
    let home = sftp
        .canonicalize(".")
        .await
        .map_err(|err| TransportError::Files(err.to_string()))?;
    let target = if path.is_empty() {
        home.clone()
    } else {
        sftp.canonicalize(path)
            .await
            .map_err(|err| TransportError::Files(format!("{path}: {err}")))?
    };
    if !inside_home(&home, &target) {
        return Err(TransportError::Files(format!("{path} {OUTSIDE_HOME}")));
    }
    Ok((home, target))
}

async fn sftp_list_dir(
    handle: &Handle<HostKeyCheck>,
    path: &str,
) -> Result<DirListing, TransportError> {
    let sftp = sftp_session(handle, TransportError::Files).await?;
    let failed = |err: russh_sftp::client::error::Error| TransportError::Files(err.to_string());
    let (home, target) = sftp_real_path(&sftp, path).await?;
    let read = sftp
        .read_dir(target.as_str())
        .await
        .map_err(|err| TransportError::Files(format!("{target}: {err}")))?;
    let mut entries = Vec::new();
    for entry in read {
        let name = entry.file_name();
        if name == "." || name == ".." {
            continue;
        }
        // `sftp-server` lists with lstat: a link needs a stat of its own.
        let mut meta = Some(entry.metadata());
        if entry.file_type().is_symlink() {
            meta = sftp.metadata(join_path(&target, &name)).await.ok();
        }
        let kind = match &meta {
            Some(meta) if meta.file_type().is_dir() => EntryKind::Dir,
            Some(meta) if meta.file_type().is_file() => EntryKind::File,
            _ => EntryKind::Other,
        };
        entries.push(DirEntry {
            name,
            kind,
            size: meta.as_ref().and_then(|meta| meta.size).unwrap_or(0),
            modified: meta
                .as_ref()
                .and_then(|meta| meta.mtime)
                .map_or(0, u64::from),
        });
    }
    sftp.close().await.map_err(failed)?;
    Ok(DirListing {
        home,
        path: target,
        entries,
    })
}

/// `path` below the local home directory.
#[cfg(unix)]
fn local_home_path(path: &str) -> Result<std::path::PathBuf, TransportError> {
    let home = dirs::home_dir().ok_or_else(|| TransportError::Files("no home directory".into()))?;
    Ok(home.join(path.trim_start_matches('/')))
}

/// An SFTP session on its own channel. `error` wraps the failure: only a key
/// whose forced command is `sftp-server` gets one.
async fn sftp_session(
    handle: &Handle<HostKeyCheck>,
    error: fn(String) -> TransportError,
) -> Result<SftpSession, TransportError> {
    let channel = handle.channel_open_session().await?;
    channel.request_subsystem(true, "sftp").await?;
    SftpSession::new(channel.into_stream()).await.map_err(|err| {
        error(format!(
            "SFTP not available ({err}); the key line needs command=\"/usr/libexec/sftp-server\""
        ))
    })
}

async fn sftp_list(
    handle: &Handle<HostKeyCheck>,
    dir: &str,
) -> Result<Vec<RemoteFile>, TransportError> {
    let sftp = sftp_session(handle, TransportError::Files).await?;
    let failed = |err: russh_sftp::client::error::Error| TransportError::Files(err.to_string());
    let home = sftp.canonicalize(".").await.map_err(failed)?;
    let target = format!(
        "{}/{}",
        home.trim_end_matches('/'),
        dir.trim_start_matches('/')
    );
    let files = sftp
        .read_dir(target.as_str())
        .await
        .map_err(|err| TransportError::Files(format!("{target}: {err}")))?
        .filter(|entry| entry.file_type().is_file())
        .map(|entry| {
            let meta = entry.metadata();
            RemoteFile {
                name: entry.file_name(),
                size: meta.size.unwrap_or(0),
                modified: meta.mtime.map_or(0, u64::from),
            }
        })
        .collect();
    sftp.close().await.map_err(failed)?;
    Ok(files)
}

/// [`Connection::herdr_sessions`] on this machine, without a connection.
#[cfg(unix)]
pub async fn local_herdr_sessions() -> Result<Vec<HerdrSessionEntry>, TransportError> {
    let path = local_home_path(HERDR_SESSIONS_DIR)?;
    let mut entries = match tokio::fs::read_dir(&path).await {
        Ok(entries) => entries,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(err) => return Err(TransportError::Files(format!("{}: {err}", path.display()))),
    };
    let mut sessions = Vec::new();
    while let Some(entry) = entries.next_entry().await? {
        if !entry.file_type().await?.is_dir() {
            continue;
        }
        let socket = entry.path().join("herdr.sock");
        sessions.push(HerdrSessionEntry {
            name: entry.file_name().to_string_lossy().into_owned(),
            running: tokio::net::UnixStream::connect(&socket).await.is_ok(),
        });
    }
    Ok(tidy_sessions(sessions))
}

/// Sorted by name, without hidden directories.
fn tidy_sessions(mut sessions: Vec<HerdrSessionEntry>) -> Vec<HerdrSessionEntry> {
    sessions.retain(|session| !session.name.starts_with('.'));
    sessions.sort_by(|a, b| a.name.cmp(&b.name));
    sessions
}

async fn sftp_herdr_sessions(
    handle: &Handle<HostKeyCheck>,
) -> Result<Vec<HerdrSessionEntry>, TransportError> {
    let sftp = sftp_session(handle, TransportError::Files).await?;
    let failed = |err: russh_sftp::client::error::Error| TransportError::Files(err.to_string());
    let home = sftp.canonicalize(".").await.map_err(failed)?;
    let base = format!("{}/{HERDR_SESSIONS_DIR}", home.trim_end_matches('/'));
    let names: Vec<String> = match sftp.read_dir(base.as_str()).await {
        Ok(entries) => entries
            .filter(|entry| entry.file_type().is_dir())
            .map(|entry| entry.file_name())
            .filter(|name| name != "." && name != "..")
            .collect(),
        // Most likely missing: no named session was ever started.
        Err(_) => Vec::new(),
    };
    let mut sessions = Vec::with_capacity(names.len());
    for name in names {
        // Socket files have no type of their own in SFTP version 3; any
        // entry under that name means a running server.
        let running = sftp
            .symlink_metadata(format!("{base}/{name}/herdr.sock"))
            .await
            .is_ok();
        sessions.push(HerdrSessionEntry { name, running });
    }
    sftp.close().await.map_err(failed)?;
    Ok(sessions)
}

/// `current` with `line` appended, or `None` when the key is there already.
fn with_authorized_key(current: &str, line: &str, key_blob: &str) -> Option<String> {
    if current
        .lines()
        .any(|existing| existing.split_whitespace().any(|field| field == key_blob))
    {
        return None;
    }
    let mut next = current.to_owned();
    if !next.is_empty() && !next.ends_with('\n') {
        next.push('\n');
    }
    next.push_str(line);
    next.push('\n');
    Some(next)
}

async fn sftp_add_authorized_key(
    handle: &Handle<HostKeyCheck>,
    line: &str,
    key_blob: &str,
) -> Result<bool, TransportError> {
    let sftp = sftp_session(handle, TransportError::Upload).await?;
    let failed = |err: russh_sftp::client::error::Error| TransportError::Upload(err.to_string());
    let mode = |bits: u32| FileAttributes {
        permissions: Some(bits),
        ..FileAttributes::empty()
    };
    let home = sftp.canonicalize(".").await.map_err(failed)?;
    let dir = format!("{}/.ssh", home.trim_end_matches('/'));
    if !sftp.try_exists(dir.as_str()).await.map_err(failed)? {
        sftp.create_dir(dir.as_str()).await.map_err(failed)?;
        sftp.set_metadata(dir.as_str(), mode(0o700))
            .await
            .map_err(failed)?;
    }
    let path = format!("{dir}/authorized_keys");
    let current = if sftp.try_exists(path.as_str()).await.map_err(failed)? {
        String::from_utf8(sftp.read(path.as_str()).await.map_err(failed)?)
            .map_err(|_| TransportError::Upload("authorized_keys is not text".into()))?
    } else {
        String::new()
    };
    let Some(next) = with_authorized_key(&current, line, key_blob) else {
        sftp.close().await.map_err(failed)?;
        return Ok(false);
    };
    for (target, content) in [
        (format!("{dir}/authorized_keys.bak-amiscara"), current),
        (path, next),
    ] {
        let mut file = sftp
            .open_with_flags_and_attributes(
                target.as_str(),
                OpenFlags::CREATE | OpenFlags::TRUNCATE | OpenFlags::WRITE,
                mode(0o600),
            )
            .await
            .map_err(failed)?;
        file.write_all(content.as_bytes()).await?;
        file.shutdown().await?;
        sftp.set_metadata(target.as_str(), mode(0o600))
            .await
            .map_err(failed)?;
    }
    sftp.close().await.map_err(failed)?;
    Ok(true)
}

async fn sftp_upload(
    handle: &Handle<HostKeyCheck>,
    dir: &str,
    file_name: &str,
    data: &[u8],
) -> Result<String, TransportError> {
    let sftp = sftp_session(handle, TransportError::Upload).await?;
    let failed = |err: russh_sftp::client::error::Error| TransportError::Upload(err.to_string());

    let mode = |bits: u32| FileAttributes {
        permissions: Some(bits),
        ..FileAttributes::empty()
    };
    let mut path = sftp.canonicalize(".").await.map_err(failed)?;
    for part in dir.split('/').filter(|part| !part.is_empty()) {
        path = format!("{}/{part}", path.trim_end_matches('/'));
        if !sftp.try_exists(path.as_str()).await.map_err(failed)? {
            sftp.create_dir(path.as_str()).await.map_err(failed)?;
        }
        sftp.set_metadata(path.as_str(), mode(0o700))
            .await
            .map_err(failed)?;
    }
    let target = format!("{path}/{file_name}");
    let mut file = sftp
        .open_with_flags_and_attributes(
            target.as_str(),
            OpenFlags::CREATE | OpenFlags::EXCLUDE | OpenFlags::WRITE,
            mode(0o600),
        )
        .await
        .map_err(failed)?;
    file.write_all(data).await?;
    file.shutdown().await?;
    // Some servers apply the umask to the create attributes; set it again.
    sftp.set_metadata(target.as_str(), mode(0o600))
        .await
        .map_err(failed)?;
    sftp.close().await.map_err(failed)?;
    Ok(target)
}

async fn read_line(
    reader: &mut BufReader<Box<dyn Stream>>,
) -> Result<Option<String>, TransportError> {
    let mut line = String::new();
    loop {
        line.clear();
        if reader.read_line(&mut line).await? == 0 {
            return Ok(None);
        }
        if !line.trim().is_empty() {
            return Ok(Some(line));
        }
    }
}

async fn authenticate_with_file(
    handle: &mut Handle<HostKeyCheck>,
    user: &str,
    path: &Path,
) -> Result<bool, TransportError> {
    let key = load_secret_key(path, None).map_err(|e| TransportError::Key(e.to_string()))?;
    authenticate_with_key(handle, user, Arc::new(key)).await
}

async fn authenticate_with_key(
    handle: &mut Handle<HostKeyCheck>,
    user: &str,
    key: Arc<PrivateKey>,
) -> Result<bool, TransportError> {
    let hash = handle.best_supported_rsa_hash().await?.flatten();
    let result = handle
        .authenticate_publickey(user, PrivateKeyWithHashAlg::new(key, hash))
        .await?;
    Ok(matches!(result, AuthResult::Success))
}

async fn authenticate_with_agent(
    handle: &mut Handle<HostKeyCheck>,
    user: &str,
) -> Result<bool, TransportError> {
    #[cfg(unix)]
    let agent = AgentClient::connect_env().await;
    // Windows OpenSSH runs its agent on a fixed named pipe.
    #[cfg(windows)]
    let agent = AgentClient::connect_named_pipe(r"\\.\pipe\openssh-ssh-agent").await;
    let mut agent = agent.map_err(|e| TransportError::Key(e.to_string()))?;
    let identities = agent
        .request_identities()
        .await
        .map_err(|e| TransportError::Key(e.to_string()))?;
    let hash = handle.best_supported_rsa_hash().await?.flatten();
    for identity in identities {
        let key = identity.public_key().into_owned();
        let result = handle
            .authenticate_publickey_with(user, key, hash, &mut agent)
            .await
            .map_err(|e| TransportError::Key(e.to_string()))?;
        if matches!(result, AuthResult::Success) {
            return Ok(true);
        }
    }
    Ok(false)
}

#[cfg(test)]
mod authorized_keys_tests {
    use super::with_authorized_key;

    #[test]
    fn appends_once() {
        let line = "restrict ssh-ed25519 AAAAkey tv";
        assert_eq!(
            with_authorized_key("", line, "AAAAkey").as_deref(),
            Some("restrict ssh-ed25519 AAAAkey tv\n")
        );
        assert_eq!(
            with_authorized_key("ssh-ed25519 AAAAother a", line, "AAAAkey").as_deref(),
            Some("ssh-ed25519 AAAAother a\nrestrict ssh-ed25519 AAAAkey tv\n")
        );
        assert_eq!(
            with_authorized_key("x ssh-ed25519 AAAAkey old\n", line, "AAAAkey"),
            None
        );
        // A blob that is only part of another key does not count.
        assert!(with_authorized_key("ssh-ed25519 AAAAkeyLONGER a\n", line, "AAAAkey").is_some());
    }
}

#[cfg(test)]
mod browse_tests {
    use super::inside_home;
    #[cfg(unix)]
    use super::{OUTSIDE_HOME, TransportError, real_path_below};

    /// A link out of the home directory is refused on its real path, a
    /// link inside stays allowed.
    #[cfg(unix)]
    #[test]
    fn links_out_of_home_are_refused() {
        let base = std::env::temp_dir().join(format!("amiscara-browse-{}", std::process::id()));
        let home = base.join("home");
        let outside = base.join("outside");
        std::fs::create_dir_all(home.join("src")).expect("home");
        std::fs::create_dir_all(&outside).expect("outside");
        std::os::unix::fs::symlink(&outside, home.join("out")).expect("link out");
        std::os::unix::fs::symlink(home.join("src"), home.join("in")).expect("link in");
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        let resolve = |path: std::path::PathBuf| {
            runtime.block_on(real_path_below(&home, &path.to_string_lossy()))
        };

        let (real_home, inside) = resolve(home.join("in")).expect("link inside");
        assert!(inside.ends_with("/home/src"), "{inside}");
        assert!(inside.starts_with(&real_home));
        for path in [home.join("out"), home.join("src/../../outside")] {
            match resolve(path.clone()) {
                Err(TransportError::Files(message)) => {
                    assert!(message.ends_with(OUTSIDE_HOME), "{message}");
                }
                other => panic!("{} was not refused: {other:?}", path.display()),
            }
        }
        let (_, empty) = runtime
            .block_on(real_path_below(&home, ""))
            .expect("home itself");
        assert_eq!(empty, real_home);
        std::fs::remove_dir_all(&base).expect("clean up");
    }

    #[test]
    fn home_bounds_paths_per_component() {
        assert!(inside_home("/home/a", "/home/a"));
        assert!(inside_home("/home/a", "/home/a/"));
        assert!(inside_home("/home/a", "/home/a/src/x"));
        assert!(!inside_home("/home/a", "/home/ab"));
        assert!(!inside_home("/home/a", "/home"));
        assert!(!inside_home("/home/a", "/etc"));
        assert!(!inside_home("/home/a", "/home/a/../b"));
    }
}
