//! Transports to a herdr server socket.
//!
//! `Local` talks to the Unix socket directly (Unix only). `Ssh` keeps one SSH session and
//! opens a `direct-streamlocal@openssh.com` channel per request, which is the
//! same path `herdr --remote` uses. Nothing has to be installed on the server.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use herdr_proto::{ProtoError, Request};
use russh::client::{self, AuthResult, Handle};
use russh::keys::agent::client::AgentClient;
use russh::keys::{PrivateKeyWithHashAlg, PublicKeyOrCertificate, known_hosts, load_secret_key};
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
}

trait Stream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Stream for T {}

#[derive(Debug, Clone)]
pub struct SshTarget {
    pub host: String,
    pub port: u16,
    pub user: String,
    /// Private key file. Without one the SSH agent (`SSH_AUTH_SOCK`) is used.
    pub identity: Option<PathBuf>,
    pub known_hosts: PathBuf,
    /// Record an unknown host key instead of rejecting it (trust on first use).
    pub accept_new_host_key: bool,
}

struct HostKeyCheck {
    host: String,
    port: u16,
    known_hosts: PathBuf,
    accept_new: bool,
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
        let server_public_key = &server_key.public_key();
        match known_hosts::check_known_hosts_path(
            &self.host,
            self.port,
            server_public_key,
            &self.known_hosts,
        ) {
            Ok(true) => Ok(true),
            Ok(false) if self.accept_new => {
                known_hosts::learn_known_hosts_path(
                    &self.host,
                    self.port,
                    server_public_key,
                    &self.known_hosts,
                )
                .map_err(|e| russh::Error::IO(std::io::Error::other(e.to_string())))?;
                Ok(true)
            }
            // Unknown key without consent, or a changed key: refuse.
            Ok(false) | Err(_) => Ok(false),
        }
    }
}

enum Inner {
    #[cfg(unix)]
    Local(PathBuf),
    Ssh {
        handle: Handle<HostKeyCheck>,
        socket_path: String,
    },
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
        let check = HostKeyCheck {
            host: target.host.clone(),
            port: target.port,
            known_hosts: target.known_hosts.clone(),
            accept_new: target.accept_new_host_key,
        };
        let mut handle =
            client::connect(config, (target.host.as_str(), target.port), check).await?;

        let authenticated = match &target.identity {
            Some(path) => authenticate_with_file(&mut handle, &target.user, path).await?,
            None => authenticate_with_agent(&mut handle, &target.user).await?,
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
            } => {
                let channel = handle
                    .channel_open_direct_streamlocal(socket_path.clone())
                    .await?;
                Ok(Box::new(channel.into_stream()))
            }
        }
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
    let hash = handle.best_supported_rsa_hash().await?.flatten();
    let result = handle
        .authenticate_publickey(user, PrivateKeyWithHashAlg::new(Arc::new(key), hash))
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
