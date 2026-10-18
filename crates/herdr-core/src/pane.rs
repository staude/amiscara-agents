//! Live content of one pane.
//!
//! herdr 0.9 offers no cheap way to notice new output: `pane_output_changed`
//! is in the schema but never sent, `PaneInfo.revision` counts metadata
//! (title, status) rather than content, and `pane.read` always reports
//! revision 0. So an open pane is polled with `pane.read` and compared on
//! the client. Only changed text is parsed and published. The interval stays
//! short while the pane is busy and doubles while it is quiet.
//!
//! Every read costs a round trip, over SSH up to 100 ms of server time. When
//! several panes of a split tab are on screen, only the one the user works in
//! needs the fast pace; the others follow with [`Pacing::background`] and can
//! be switched over without restarting through [`follow_paced`].

use std::sync::Arc;
use std::time::Duration;

use herdr_proto::PaneReadResult;
use herdr_transport::{Connection, TransportError};
use serde_json::json;
use tokio::sync::watch;
use tokio::time::sleep;

use crate::terminal::Screen;

#[derive(Debug, Clone, PartialEq)]
pub struct PaneScreen {
    pub pane_id: String,
    pub screen: Screen,
    pub truncated: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum PaneError {
    #[error(transparent)]
    Transport(#[from] TransportError),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

/// Poll pacing for [`follow`].
#[derive(Debug, Clone, Copy)]
pub struct Pacing {
    /// Interval right after a change.
    pub busy: Duration,
    /// Longest interval while nothing changes.
    pub quiet: Duration,
}

impl Default for Pacing {
    fn default() -> Self {
        Self {
            busy: Duration::from_millis(150),
            quiet: Duration::from_secs(1),
        }
    }
}

impl Pacing {
    /// For a pane on screen next to the selected one: current within a few
    /// seconds at a fraction of the reads.
    pub fn background() -> Self {
        Self {
            busy: Duration::from_secs(1),
            quiet: Duration::from_secs(4),
        }
    }
}

async fn read_raw(conn: &Connection, pane_id: &str) -> Result<PaneReadResult, PaneError> {
    let params = json!({
        "pane_id": pane_id,
        "source": "visible",
        "format": "ansi",
        "strip_ansi": false,
    });
    Ok(serde_json::from_value(
        conn.request("pane.read", params).await?,
    )?)
}

/// Reads the visible screen of a pane once.
pub async fn read_screen(conn: &Connection, pane_id: &str) -> Result<PaneScreen, PaneError> {
    let result = read_raw(conn, pane_id).await?;
    Ok(PaneScreen {
        pane_id: result.read.pane_id,
        screen: Screen::parse(&result.read.text),
        truncated: result.read.truncated,
    })
}

/// Publishes the pane's screen into `tx` and keeps it current. Returns on the
/// first error (for example a closed pane or a lost connection) or when
/// nobody watches any more. Reconnecting is up to the caller, which usually
/// also runs the session sync and knows whether the pane still exists.
pub async fn follow(
    conn: &Connection,
    pane_id: &str,
    pacing: Pacing,
    tx: &watch::Sender<Option<Arc<PaneScreen>>>,
) -> Result<(), PaneError> {
    let (_fixed, pacing) = watch::channel(pacing);
    follow_paced(conn, pane_id, pacing, tx).await
}

/// Like [`follow`], with a pace that can change while following. A new pace
/// reads the pane right away, so a pane that becomes the selected one is
/// current at once. A dropped pacing sender keeps the last pace.
pub async fn follow_paced(
    conn: &Connection,
    pane_id: &str,
    mut pacing: watch::Receiver<Pacing>,
    tx: &watch::Sender<Option<Arc<PaneScreen>>>,
) -> Result<(), PaneError> {
    let mut last_text: Option<String> = None;
    let mut interval = Duration::ZERO;
    let mut pacing_open = true;
    loop {
        let read = read_raw(conn, pane_id).await?.read;
        let pace = *pacing.borrow_and_update();
        if last_text.as_deref() == Some(read.text.as_str()) {
            interval = (interval * 2).clamp(pace.busy, pace.quiet);
        } else {
            interval = pace.busy;
            tx.send_replace(Some(Arc::new(PaneScreen {
                pane_id: read.pane_id,
                screen: Screen::parse(&read.text),
                truncated: read.truncated,
            })));
            last_text = Some(read.text);
        }
        let pace_changed = async {
            if pacing_open {
                pacing.changed().await.is_ok()
            } else {
                std::future::pending().await
            }
        };
        tokio::select! {
            () = sleep(interval) => {}
            open = pace_changed => {
                pacing_open = open;
                interval = Duration::ZERO;
            }
            () = tx.closed() => return Ok(()),
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::UnixListener;
    use tokio::time::{Instant, timeout};

    /// A herdr stand-in that answers every `pane.read` with the same screen.
    fn fake_server(path: &std::path::Path, reads: Arc<AtomicUsize>) {
        let listener = UnixListener::bind(path).unwrap_or_else(|err| panic!("bind: {err}"));
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let reads = reads.clone();
                tokio::spawn(async move {
                    let (read, mut write) = stream.into_split();
                    let mut line = String::new();
                    if BufReader::new(read).read_line(&mut line).await.is_err() {
                        return;
                    }
                    reads.fetch_add(1, Ordering::SeqCst);
                    let reply = json!({"id": "1", "result": {"type": "pane_read", "read": {
                        "pane_id": "w1:p1", "text": "$ ", "revision": 0, "truncated": false
                    }}});
                    let _ = write.write_all(format!("{reply}\n").as_bytes()).await;
                });
            }
        });
    }

    #[tokio::test]
    async fn a_new_pace_reads_at_once() {
        let dir = std::env::temp_dir().join(format!("herdr-core-pace-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let socket = dir.join("herdr.sock");
        let _ = std::fs::remove_file(&socket);
        let reads = Arc::new(AtomicUsize::new(0));
        fake_server(&socket, reads.clone());
        let conn = Connection::local(socket.clone());

        let slow = Pacing {
            busy: Duration::from_secs(30),
            quiet: Duration::from_secs(30),
        };
        let (pace_tx, pace_rx) = watch::channel(slow);
        let (tx, mut rx) = watch::channel(None);
        let follower = tokio::spawn(async move {
            let _ = follow_paced(&conn, "w1:p1", pace_rx, &tx).await;
        });

        let first = timeout(Duration::from_secs(5), rx.changed()).await;
        assert!(matches!(first, Ok(Ok(()))), "first screen");
        assert_eq!(reads.load(Ordering::SeqCst), 1);

        let switched = Instant::now();
        pace_tx.send_replace(Pacing::default());
        let deadline = Instant::now() + Duration::from_secs(5);
        while reads.load(Ordering::SeqCst) < 2 && Instant::now() < deadline {
            sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(
            reads.load(Ordering::SeqCst),
            2,
            "second read after the switch"
        );
        assert!(switched.elapsed() < Duration::from_secs(5));

        follower.abort();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
