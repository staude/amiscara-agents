//! Looking back in a full-screen agent such as Claude Code (#187).
//!
//! A full-screen program draws on the terminal's alternate screen, so herdr
//! keeps no scrollback for it and a recent `pane.read` returns only the
//! screen. Two ways around that, both of which move the agent's view in
//! herdr's own client on the host too:
//!
//! - [`read_history`]: `agent.read` makes herdr scroll the idle agent with
//!   wheel events, collect the pages and scroll it back down.
//! - [`scroll`]: page keys sent to the agent, which scrolls its own view;
//!   works while it works, and the followed screen shows the result.

use herdr_proto::{PaneReadResult, ProtoError};
use herdr_transport::{Connection, TransportError};
use serde_json::json;

use crate::actions::{self, ActionError};
use crate::pane::{MAX_HISTORY_LINES, PaneError, PaneScreen};
use crate::terminal::Screen;

#[derive(Debug, thiserror::Error)]
pub enum HistoryError {
    /// herdr collects the history only from an idle agent.
    #[error("the agent is working")]
    AgentWorking,
    #[error(transparent)]
    Pane(#[from] PaneError),
}

impl From<TransportError> for HistoryError {
    fn from(err: TransportError) -> Self {
        match err {
            TransportError::Proto(ProtoError::Api { code, .. }) if code == "agent_not_idle" => {
                Self::AgentWorking
            }
            other => Self::Pane(other.into()),
        }
    }
}

/// How close [`read_history`] gets to the start of a short history.
const PRECISION: u32 = 25;

/// Reads up to [`MAX_HISTORY_LINES`] rows of the agent's transcript in the
/// pane, the screen included. Plain text without colors: herdr collects the
/// history only for text reads. Takes a moment, since herdr scrolls through
/// the agent page by page.
///
/// herdr 0.9.5 falls back to the bare screen when the history is shorter
/// than the rows asked for (the last page at the top does not line up), so
/// after such a read the request narrows down until one comes back whole,
/// which loses at most [`PRECISION`] rows at the top.
pub async fn read_history(conn: &Connection, pane_id: &str) -> Result<PaneScreen, HistoryError> {
    let mut asked = MAX_HISTORY_LINES;
    let mut best = read_agent(conn, pane_id, asked).await?;
    if complete(&best, asked) {
        return Ok(best);
    }
    // `best` is the screen now; a whole read lies between it and `asked`.
    let mut low = u32::try_from(best.screen.lines.len()).unwrap_or(u32::MAX);
    let mut high = asked;
    while high.saturating_sub(low) > PRECISION {
        asked = low + (high - low) / 2;
        let read = read_agent(conn, pane_id, asked).await?;
        if complete(&read, asked) {
            low = asked;
            best = read;
        } else {
            high = asked;
        }
    }
    Ok(best)
}

async fn read_agent(
    conn: &Connection,
    pane_id: &str,
    lines: u32,
) -> Result<PaneScreen, HistoryError> {
    let params = json!({
        "target": pane_id,
        "source": "recent",
        "lines": lines,
        "format": "text",
    });
    let result: PaneReadResult = serde_json::from_value(conn.request("agent.read", params).await?)
        .map_err(PaneError::from)?;
    let screen = Screen::parse(&result.read.text);
    let rows = u32::try_from(screen.lines.len()).unwrap_or(u32::MAX);
    Ok(PaneScreen {
        pane_id: result.read.pane_id,
        screen,
        // herdr reports a whole read as truncated even when it reached the
        // top; only a full request can have more above it.
        truncated: result.read.truncated && lines == MAX_HISTORY_LINES,
        history_lines: rows,
    })
}

/// Whether herdr returned the rows asked for rather than the bare screen.
fn complete(read: &PaneScreen, asked: u32) -> bool {
    read.history_lines >= asked
}

/// A step through a full-screen agent's own view.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scroll {
    /// Half a screen up (Claude Code's Page Up).
    PageUp,
    PageDown,
    /// Back to the newest output, which the agent then follows again.
    Bottom,
}

impl Scroll {
    /// Raw terminal input: herdr's `pane.send_keys` has no page keys.
    fn input(self) -> &'static str {
        match self {
            Self::PageUp => "\x1b[5~",
            Self::PageDown => "\x1b[6~",
            Self::Bottom => "\x1b[1;5F",
        }
    }
}

/// Scrolls the agent's view in the pane; meant for full-screen agents,
/// where these keys move the transcript. Writes to the pane.
pub async fn scroll(conn: &Connection, pane_id: &str, step: Scroll) -> Result<(), ActionError> {
    actions::send_text(conn, pane_id, step.input()).await
}

// The fake server listens on a Unix socket, which `Connection::local` needs.
#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::UnixListener;

    /// Rows on the agent's screen and in its whole transcript.
    const SCREEN: u32 = 40;

    /// A herdr stand-in for `agent.read` that behaves like 0.9.5: a request
    /// beyond the transcript gets the bare screen. `None` answers
    /// `agent_not_idle`. Records the `lines` of each request.
    fn fake_herdr(name: &str, transcript: Option<u32>) -> (PathBuf, Arc<Mutex<Vec<u32>>>) {
        let path =
            std::env::temp_dir().join(format!("herdr-full-{name}-{}.sock", std::process::id()));
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
                let lines =
                    u32::try_from(request["params"]["lines"].as_u64().unwrap_or(0)).expect("lines");
                log.lock().expect("lock").push(lines);
                let reply = match transcript {
                    None => json!({
                        "id": request["id"],
                        "error": {"code": "agent_not_idle", "message": "working"}
                    }),
                    Some(total) => {
                        let rows = if lines <= total { lines } else { SCREEN };
                        let first = if lines <= total {
                            total - lines
                        } else {
                            total - SCREEN
                        };
                        let text: String = (first..first + rows)
                            .map(|n| format!("row {n}\n"))
                            .collect();
                        json!({
                            "id": request["id"],
                            "result": {"type": "pane_read", "read": {
                                "pane_id": "w1:p1", "text": text, "truncated": true
                            }}
                        })
                    }
                };
                let _ = write.write_all(format!("{reply}\n").as_bytes()).await;
            }
        });
        (path, seen)
    }

    #[tokio::test]
    async fn a_long_history_takes_one_read() {
        let (path, seen) = fake_herdr("long", Some(3000));
        let read = read_history(&Connection::local(&path), "w1:p1")
            .await
            .expect("history");
        assert_eq!(read.history_lines, MAX_HISTORY_LINES);
        assert!(read.truncated);
        assert_eq!(*seen.lock().expect("lock"), [MAX_HISTORY_LINES]);
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn a_short_history_narrows_down_to_nearly_all_of_it() {
        let (path, seen) = fake_herdr("short", Some(136));
        let read = read_history(&Connection::local(&path), "w1:p1")
            .await
            .expect("history");
        assert!(
            (136 - PRECISION..=136).contains(&read.history_lines),
            "{} rows",
            read.history_lines
        );
        assert!(!read.truncated);
        assert_eq!(
            read.screen.text_lines().last().map(String::as_str),
            Some("row 135")
        );
        assert!(seen.lock().expect("lock").len() <= 8);
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn a_working_agent_is_reported() {
        let (path, _) = fake_herdr("working", None);
        let result = read_history(&Connection::local(&path), "w1:p1").await;
        assert!(
            matches!(result, Err(HistoryError::AgentWorking)),
            "{result:?}"
        );
        let _ = std::fs::remove_file(&path);
    }
}
