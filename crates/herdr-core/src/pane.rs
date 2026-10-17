//! Live content of one pane.
//!
//! herdr 0.9 offers no cheap way to notice new output: `pane_output_changed`
//! is in the schema but never sent, `PaneInfo.revision` counts metadata
//! (title, status) rather than content, and `pane.read` always reports
//! revision 0. So an open pane is polled with `pane.read` and compared on
//! the client. Only changed text is parsed and published. The interval stays
//! short while the pane is busy and doubles while it is quiet.

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
    let mut last_text: Option<String> = None;
    let mut interval = pacing.busy;
    loop {
        let read = read_raw(conn, pane_id).await?.read;
        if last_text.as_deref() == Some(read.text.as_str()) {
            interval = (interval * 2).min(pacing.quiet);
        } else {
            interval = pacing.busy;
            tx.send_replace(Some(Arc::new(PaneScreen {
                pane_id: read.pane_id,
                screen: Screen::parse(&read.text),
                truncated: read.truncated,
            })));
            last_text = Some(read.text);
        }
        tokio::select! {
            () = sleep(interval) => {}
            () = tx.closed() => return Ok(()),
        }
    }
}
