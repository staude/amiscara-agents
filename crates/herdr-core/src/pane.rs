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
//!
//! With history requested, the content comes from `source: "recent"`, which
//! returns the last N rows of scrollback and screen together. Such a read can
//! be a hundred times the size of the visible screen, so the cheap visible
//! read still detects changes and the large one follows at most once per
//! [`Pacing::history`].

use std::sync::Arc;
use std::time::Duration;

use herdr_proto::PaneReadResult;
use herdr_transport::{Connection, TransportError};
use serde_json::json;
use tokio::sync::watch;
use tokio::time::{Instant, sleep};

use crate::terminal::Screen;

/// herdr caps `lines` of a recent read at 1000 (`read_terminal_snapshot`).
pub const MAX_HISTORY_LINES: u32 = 1000;

#[derive(Debug, Clone, PartialEq)]
pub struct PaneScreen {
    pub pane_id: String,
    pub screen: Screen,
    /// For history: herdr has more rows than were asked for.
    pub truncated: bool,
    /// Rows asked for from the recent history, 0 for the visible screen.
    pub history_lines: u32,
}

#[derive(Debug, thiserror::Error)]
pub enum PaneError {
    #[error(transparent)]
    Transport(#[from] TransportError),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

/// Poll pacing for [`follow`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pacing {
    /// Interval right after a change.
    pub busy: Duration,
    /// Longest interval while nothing changes.
    pub quiet: Duration,
    /// Shortest gap between two history reads.
    pub history: Duration,
}

impl Default for Pacing {
    fn default() -> Self {
        Self {
            busy: Duration::from_millis(150),
            quiet: Duration::from_secs(1),
            history: Duration::from_secs(1),
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
            history: Duration::from_secs(4),
        }
    }
}

/// Reads the visible screen (`history_lines == 0`) or the last
/// `history_lines` rows including scrollback. Always ANSI: a recent read in
/// `text` format makes herdr scroll a full-screen app (an agent TUI) to
/// harvest its history, which would disturb whoever works in that pane.
async fn read_raw(
    conn: &Connection,
    pane_id: &str,
    history_lines: u32,
) -> Result<PaneReadResult, PaneError> {
    let mut params = json!({
        "pane_id": pane_id,
        "source": "visible",
        "format": "ansi",
        "strip_ansi": false,
    });
    if history_lines > 0 {
        params["source"] = json!("recent");
        params["lines"] = json!(history_lines.min(MAX_HISTORY_LINES));
    }
    Ok(serde_json::from_value(
        conn.request("pane.read", params).await?,
    )?)
}

fn pane_screen(result: PaneReadResult, history_lines: u32) -> PaneScreen {
    PaneScreen {
        pane_id: result.read.pane_id,
        screen: Screen::parse(&result.read.text),
        truncated: result.read.truncated,
        history_lines,
    }
}

/// Reads the visible screen of a pane once.
pub async fn read_screen(conn: &Connection, pane_id: &str) -> Result<PaneScreen, PaneError> {
    Ok(pane_screen(read_raw(conn, pane_id, 0).await?, 0))
}

/// Publishes the pane's visible screen into `tx` and keeps it current.
/// Returns on the first error (for example a closed pane or a lost
/// connection) or when nobody watches any more. Reconnecting is up to the
/// caller, which usually also runs the session sync and knows whether the
/// pane still exists.
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
    pacing: watch::Receiver<Pacing>,
    tx: &watch::Sender<Option<Arc<PaneScreen>>>,
) -> Result<(), PaneError> {
    let (_none, history) = watch::channel(0);
    follow_with_history(conn, pane_id, pacing, history, tx).await
}

/// Like [`follow_paced`], but publishes the last `*history` rows including
/// scrollback whenever that value is above 0. A new value takes effect at
/// once; a dropped history sender keeps the last value.
pub async fn follow_with_history(
    conn: &Connection,
    pane_id: &str,
    mut pacing: watch::Receiver<Pacing>,
    mut history: watch::Receiver<u32>,
    tx: &watch::Sender<Option<Arc<PaneScreen>>>,
) -> Result<(), PaneError> {
    let mut pacing_open = true;
    let mut history_open = true;
    let mut last_visible: Option<String> = None;
    let mut last_lines: Option<u32> = None;
    // The screen changed since the last publish, but the history read is
    // still held back by `pace.history`.
    let mut pending = false;
    let mut last_history_read: Option<Instant> = None;
    let mut interval = Duration::ZERO;
    loop {
        let pace = *pacing.borrow_and_update();
        let lines = (*history.borrow_and_update()).min(MAX_HISTORY_LINES);
        let mode_changed = last_lines != Some(lines);
        let visible = read_raw(conn, pane_id, 0).await?;
        if mode_changed || last_visible.as_deref() != Some(visible.read.text.as_str()) {
            interval = pace.busy;
            pending = true;
        } else {
            interval = (interval * 2).clamp(pace.busy, pace.quiet);
        }
        last_lines = Some(lines);
        let mut wait = interval;
        if pending && lines == 0 {
            last_visible = Some(visible.read.text.clone());
            tx.send_replace(Some(Arc::new(pane_screen(visible, 0))));
            pending = false;
        } else if pending {
            last_visible = Some(visible.read.text);
            let due = last_history_read.map(|at| at + pace.history);
            match due {
                Some(due) if !mode_changed && due > Instant::now() => {
                    wait = wait.min(due.saturating_duration_since(Instant::now()));
                }
                _ => {
                    let recent = read_raw(conn, pane_id, lines).await?;
                    last_history_read = Some(Instant::now());
                    tx.send_replace(Some(Arc::new(pane_screen(recent, lines))));
                    pending = false;
                }
            }
        }
        let pace_changed = async {
            if pacing_open {
                pacing.changed().await.is_ok()
            } else {
                std::future::pending().await
            }
        };
        tokio::select! {
            () = sleep(wait) => {}
            open = pace_changed => {
                pacing_open = open;
                interval = Duration::ZERO;
            }
            changed = history.changed(), if history_open => {
                if changed.is_err() {
                    history_open = false;
                }
            }
            () = tx.closed() => return Ok(()),
        }
    }
}

// The fake server listens on a Unix socket, which `Connection::local` needs.
#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::Mutex;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::UnixListener;
    use tokio::time::timeout;

    /// Source and `lines` of each `pane.read` the fake server saw.
    type Requests = Arc<Mutex<Vec<(String, Option<u64>)>>>;

    /// A herdr stand-in that answers `pane.read` and records each request's
    /// source and line count.
    fn fake_herdr(name: &str) -> (PathBuf, Requests) {
        let path =
            std::env::temp_dir().join(format!("herdr-core-{name}-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).expect("bind fake socket");
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = Arc::clone(&seen);
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let (read, mut write) = stream.into_split();
                let mut line = String::new();
                if BufReader::new(read).read_line(&mut line).await.is_err() {
                    continue;
                }
                let request: serde_json::Value = serde_json::from_str(&line).expect("json");
                let params = &request["params"];
                let source = params["source"].as_str().unwrap_or_default().to_owned();
                let lines = params["lines"].as_u64();
                log.lock().expect("lock").push((source.clone(), lines));
                let (text, truncated) = if source == "recent" {
                    ("old 1\r\nold 2\r\nscreen\r\n", true)
                } else {
                    ("screen\r\n", false)
                };
                let reply = json!({
                    "id": request["id"],
                    "result": {"type": "pane_read", "read": {
                        "pane_id": "w1:p1", "text": text, "truncated": truncated, "revision": 0
                    }}
                });
                let _ = write.write_all(format!("{reply}\n").as_bytes()).await;
            }
        });
        (path, seen)
    }

    fn reads(seen: &Requests) -> usize {
        seen.lock().expect("lock").len()
    }

    #[tokio::test]
    async fn a_new_pace_reads_at_once() {
        let (path, seen) = fake_herdr("pace");
        let conn = Connection::local(&path);
        let slow = Pacing {
            busy: Duration::from_secs(30),
            quiet: Duration::from_secs(30),
            history: Duration::from_secs(30),
        };
        let (pace_tx, pace_rx) = watch::channel(slow);
        let (tx, mut rx) = watch::channel(None);
        let follower = tokio::spawn(async move {
            let _ = follow_paced(&conn, "w1:p1", pace_rx, &tx).await;
        });

        let first = timeout(Duration::from_secs(5), rx.changed()).await;
        assert!(matches!(first, Ok(Ok(()))), "first screen");
        assert_eq!(reads(&seen), 1);

        let switched = Instant::now();
        pace_tx.send_replace(Pacing::default());
        let deadline = Instant::now() + Duration::from_secs(5);
        while reads(&seen) < 2 && Instant::now() < deadline {
            sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(reads(&seen), 2, "second read after the switch");
        assert!(switched.elapsed() < Duration::from_secs(5));

        follower.abort();
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn history_switches_to_recent_reads_and_back() {
        let (path, seen) = fake_herdr("history");
        let conn = Connection::local(&path);
        let pacing = Pacing {
            busy: Duration::from_millis(5),
            quiet: Duration::from_millis(10),
            history: Duration::from_millis(5),
        };
        let (_pace_tx, pace_rx) = watch::channel(pacing);
        let (history_tx, history) = watch::channel(0);
        let (tx, mut rx) = watch::channel(None);
        let follow = follow_with_history(&conn, "w1:p1", pace_rx, history, &tx);
        let check = async {
            rx.changed().await.expect("first screen");
            let first = rx.borrow_and_update().clone().expect("screen");
            assert_eq!(first.history_lines, 0);
            assert_eq!(first.screen.text_lines(), ["screen"]);

            history_tx.send_replace(5000);
            rx.changed().await.expect("history");
            let more = rx.borrow_and_update().clone().expect("screen");
            assert_eq!(more.history_lines, MAX_HISTORY_LINES);
            assert!(more.truncated);
            assert_eq!(more.screen.text_lines(), ["old 1", "old 2", "screen"]);

            history_tx.send_replace(0);
            rx.changed().await.expect("visible again");
            let back = rx.borrow_and_update().clone().expect("screen");
            assert_eq!(back.history_lines, 0);
        };
        tokio::select! {
            result = follow => panic!("follow ended: {result:?}"),
            () = check => {}
        }
        let _ = std::fs::remove_file(&path);
        let seen = seen.lock().expect("lock");
        assert!(seen.contains(&("recent".to_owned(), Some(u64::from(MAX_HISTORY_LINES)))));
        assert!(
            seen.iter()
                .all(|(source, _)| source == "visible" || source == "recent")
        );
    }
}
