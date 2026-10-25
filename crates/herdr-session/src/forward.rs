//! Pages on the host's `localhost` for the client's browser (#247): one
//! listener on this machine's loopback per host port, each connection
//! tunnelled through the session's current SSH connection.

use std::collections::HashMap;
use std::io;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, TcpListener as StdListener, TcpStream};
use std::sync::Mutex;
use std::time::Duration;

use herdr_core::sync::SyncState;
use tokio::net::TcpListener;
use tokio::runtime::Handle;
use tokio::sync::watch;
use tokio::task::{JoinHandle, JoinSet};

/// The port of a URL that points at the host itself (`localhost`,
/// `127.0.0.1`, `[::1]`), the scheme's default when it names none.
pub(crate) fn local_port(url: &str) -> Option<u16> {
    let authority = Authority::of(url)?;
    let host = authority.host.to_ascii_lowercase();
    matches!(host.as_str(), "localhost" | "127.0.0.1" | "[::1]").then_some(authority.port)
}

/// `url` with `port` instead of its own. The host name stays: dev servers
/// such as Vite check the `Host` header.
pub(crate) fn with_port(url: &str, port: u16) -> Option<String> {
    let authority = Authority::of(url)?;
    Some(format!(
        "{}:{port}{}",
        &url[..authority.host_end],
        &url[authority.end..]
    ))
}

/// Host and port of a URL, with where they end in it.
struct Authority<'a> {
    host: &'a str,
    port: u16,
    /// Byte index after the host name.
    host_end: usize,
    /// Byte index after the port, where the path starts.
    end: usize,
}

impl<'a> Authority<'a> {
    fn of(url: &'a str) -> Option<Self> {
        let (scheme, rest) = url.split_once("://")?;
        let default_port = match scheme.to_ascii_lowercase().as_str() {
            "http" => 80,
            "https" => 443,
            _ => return None,
        };
        let start = scheme.len() + 3;
        let end = start + rest.find(['/', '?', '#']).unwrap_or(rest.len());
        // Browsers read `\` like `/` in web URLs; such an address is not
        // taken apart here.
        if url[start..end].contains('\\') {
            return None;
        }
        let host_start = start + url[start..end].rfind('@').map_or(0, |at| at + 1);
        let host_port = &url[host_start..end];
        let host_len = if host_port.starts_with('[') {
            host_port.find(']')? + 1
        } else {
            host_port.find(':').unwrap_or(host_port.len())
        };
        let host_end = host_start + host_len;
        let port = match &url[host_end..end] {
            "" | ":" => default_port,
            port => port.strip_prefix(':')?.parse().ok()?,
        };
        (host_len > 0).then(|| Self {
            host: &url[host_start..host_end],
            port,
            host_end,
            end,
        })
    }
}

/// The listeners of one session, by host port. They end with the session.
#[derive(Default)]
pub(crate) struct Forwards {
    listeners: Mutex<HashMap<u16, Forward>>,
}

struct Forward {
    local_port: u16,
    task: JoinHandle<()>,
}

impl Forwards {
    /// The local port that reaches `host_port` on the host, listening from
    /// now on: the same number when it is free here, otherwise any.
    pub(crate) fn ensure(
        &self,
        host_port: u16,
        state: watch::Receiver<SyncState>,
        runtime: &Handle,
    ) -> io::Result<u16> {
        let mut listeners = self
            .listeners
            .lock()
            .map_err(|_| io::Error::other("forward listeners poisoned"))?;
        if let Some(forward) = listeners.get(&host_port)
            && !forward.task.is_finished()
        {
            return Ok(forward.local_port);
        }
        let sockets = bind_loopback(host_port).or_else(|_| bind_loopback(0))?;
        let local_port = sockets[0].local_addr()?.port();
        let listeners_here = {
            let _entered = runtime.enter();
            sockets
                .into_iter()
                .map(|socket| {
                    socket.set_nonblocking(true)?;
                    TcpListener::from_std(socket)
                })
                .collect::<io::Result<Vec<_>>>()?
        };
        let task = runtime.spawn(async move {
            let mut accepts = JoinSet::new();
            for listener in listeners_here {
                accepts.spawn(accept(listener, host_port, state.clone()));
            }
            // Dropping the set when aborted closes listeners and tunnels.
            while accepts.join_next().await.is_some() {}
        });
        listeners.insert(host_port, Forward { local_port, task });
        Ok(local_port)
    }

    /// Closes all listeners and their tunnels.
    pub(crate) fn stop(&self) {
        if let Ok(mut listeners) = self.listeners.lock() {
            for (_, forward) in listeners.drain() {
                forward.task.abort();
            }
        }
    }
}

impl Drop for Forwards {
    fn drop(&mut self) {
        self.stop();
    }
}

/// `127.0.0.1:<port>` and, where the system has it, `[::1]` on the same
/// port, since the browser may try either for `localhost`. When something
/// on this machine holds the port on `::1` already, the browser could end
/// up there, so the port counts as taken. On macOS and Windows a bind can
/// succeed next to a server listening on all addresses and take over its
/// loopback traffic, so a port that answers counts as taken too.
fn bind_loopback(port: u16) -> io::Result<Vec<StdListener>> {
    if port != 0 && answers(port) {
        return Err(io::Error::from(io::ErrorKind::AddrInUse));
    }
    let v4 = StdListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, port)))?;
    let port = v4.local_addr()?.port();
    match StdListener::bind(SocketAddr::from((Ipv6Addr::LOCALHOST, port))) {
        Ok(v6) => Ok(vec![v4, v6]),
        Err(err) if err.kind() == io::ErrorKind::AddrInUse => Err(err),
        // No IPv6 loopback here.
        Err(_) => Ok(vec![v4]),
    }
}

/// Whether something on this machine accepts connections on `port`.
fn answers(port: u16) -> bool {
    [
        SocketAddr::from((Ipv4Addr::LOCALHOST, port)),
        SocketAddr::from((Ipv6Addr::LOCALHOST, port)),
    ]
    .iter()
    .any(|addr| TcpStream::connect_timeout(addr, Duration::from_millis(200)).is_ok())
}

async fn accept(listener: TcpListener, host_port: u16, state: watch::Receiver<SyncState>) {
    let mut tunnels = JoinSet::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let Ok((stream, _)) = accepted else {
                    // E.g. out of file descriptors; try again shortly.
                    tokio::time::sleep(Duration::from_millis(200)).await;
                    continue;
                };
                // The connection of this moment: after a reconnect the
                // listener keeps working with the new one.
                let connection = state.borrow().connection.clone();
                if let Some(conn) = connection {
                    tunnels.spawn(async move {
                        let _ = conn.forward_tcp(host_port, stream).await;
                    });
                }
            }
            Some(_) = tunnels.join_next(), if !tunnels.is_empty() => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{local_port, with_port};

    #[test]
    fn local_addresses_and_their_ports() {
        assert_eq!(local_port("http://localhost:5173/"), Some(5173));
        assert_eq!(local_port("http://LOCALHOST"), Some(80));
        assert_eq!(local_port("https://127.0.0.1/x"), Some(443));
        assert_eq!(local_port("http://[::1]:3000?a=b"), Some(3000));
        assert_eq!(local_port("http://user:pw@localhost:8080/"), Some(8080));
        assert_eq!(local_port("http://localhost:/"), Some(80));
        for other in [
            "https://example.com/",
            "http://localhost.example.com:5173/",
            "http://example.com/?next=http://localhost:5173",
            "http://localhost:99999/",
            "http://localhost:x/",
            "http://evil.example\\@localhost:5173/",
            "ftp://localhost/",
            "localhost:5173",
        ] {
            assert_eq!(local_port(other), None, "{other}");
        }
    }

    #[test]
    fn only_the_port_changes() {
        assert_eq!(
            with_port("http://localhost:5173/mockup?x=1#top", 50123).as_deref(),
            Some("http://localhost:50123/mockup?x=1#top")
        );
        assert_eq!(
            with_port("http://127.0.0.1", 8000).as_deref(),
            Some("http://127.0.0.1:8000")
        );
        assert_eq!(
            with_port("http://[::1]:3000/a", 3001).as_deref(),
            Some("http://[::1]:3001/a")
        );
        assert_eq!(
            with_port("http://u@localhost:1/", 2).as_deref(),
            Some("http://u@localhost:2/")
        );
    }
    #[test]
    fn a_port_in_use_here_is_not_taken_over() {
        let server = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = server.local_addr().expect("addr").port();
        assert!(super::answers(port));
        assert!(super::bind_loopback(port).is_err());
        drop(server);
        assert!(super::bind_loopback(0).is_ok());
    }
}
