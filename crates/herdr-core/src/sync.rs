//! Keeps a [`SessionState`] in step with a live server.
//!
//! Per connection: subscribe to the global events first, then take
//! `session.snapshot`, so nothing that happens in between is missed. Agent
//! status needs one subscription entry per pane; that subscription is replaced
//! whenever the set of panes changes. Structural events are collected for a
//! short moment and answered with one fresh snapshot. When the connection
//! breaks, the driver reconnects with growing pauses.
//!
//! Only read-only methods are used: `session.snapshot` and `events.subscribe`.

use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use herdr_proto::{GLOBAL_SUBSCRIPTIONS, ProtoError, SnapshotResult, parse_event};
use herdr_transport::{Connection, Subscription, TransportError};
use serde_json::{Value, json};
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;
use tokio::time::{Instant, sleep, sleep_until};

use crate::{Applied, SessionState};

/// How long structural events are collected before one snapshot answers them.
const RESNAPSHOT_DELAY: Duration = Duration::from_millis(150);
const MAX_BACKOFF: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, PartialEq)]
pub enum SyncStatus {
    Connecting,
    Live,
    /// The last attempt failed; the driver waits and tries again.
    Retrying {
        attempt: u32,
        error: String,
    },
}

/// What observers see. `session` keeps the last known state while the driver
/// reconnects, so a UI can show it greyed out instead of going blank.
#[derive(Debug, Clone)]
pub struct SyncState {
    pub status: SyncStatus,
    pub session: Option<Arc<SessionState>>,
}

impl Default for SyncState {
    fn default() -> Self {
        Self {
            status: SyncStatus::Connecting,
            session: None,
        }
    }
}

#[derive(Debug, thiserror::Error)]
enum SyncError {
    #[error(transparent)]
    Transport(#[from] TransportError),
    #[error(transparent)]
    Proto(#[from] ProtoError),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error("server closed the event stream")]
    Closed,
    #[error("nobody is watching any more")]
    Unobserved,
}

/// Spawns the driver. It runs until every receiver is dropped.
pub fn spawn<F, Fut>(connect: F) -> watch::Receiver<SyncState>
where
    F: Fn() -> Fut + Send + 'static,
    Fut: Future<Output = Result<Connection, TransportError>> + Send + 'static,
{
    let (tx, rx) = watch::channel(SyncState::default());
    tokio::spawn(run(connect, tx));
    rx
}

/// The driver loop behind [`spawn`], for callers that manage their own task.
pub async fn run<F, Fut>(connect: F, tx: watch::Sender<SyncState>)
where
    F: Fn() -> Fut,
    Fut: Future<Output = Result<Connection, TransportError>>,
{
    let mut attempt = 0u32;
    loop {
        let error = match connect().await {
            Ok(conn) => follow(&conn, &tx, &mut attempt).await,
            Err(err) => SyncError::from(err),
        };
        if matches!(error, SyncError::Unobserved) || tx.is_closed() {
            return;
        }
        attempt = attempt.saturating_add(1);
        tx.send_modify(|state| {
            state.status = SyncStatus::Retrying {
                attempt,
                error: error.to_string(),
            }
        });
        tokio::select! {
            () = sleep(backoff(attempt)) => {}
            () = tx.closed() => return,
        }
    }
}

/// Follows one connection until it fails. Always returns the reason.
async fn follow(conn: &Connection, tx: &watch::Sender<SyncState>, attempt: &mut u32) -> SyncError {
    match follow_inner(conn, tx, attempt).await {
        Ok(never) => match never {},
        Err(err) => err,
    }
}

enum Never {}

async fn follow_inner(
    conn: &Connection,
    tx: &watch::Sender<SyncState>,
    attempt: &mut u32,
) -> Result<Never, SyncError> {
    let global = conn
        .subscribe_to(
            GLOBAL_SUBSCRIPTIONS
                .iter()
                .map(|t| json!({ "type": t }))
                .collect(),
        )
        .await?;
    let mut global = Forwarder::start(global);

    let mut state = snapshot(conn).await?;
    let mut panes = PaneStatus::subscribe(conn, &state).await?;
    *attempt = 0;
    publish(tx, SyncStatus::Live, &state);

    let mut resnapshot_at: Option<Instant> = None;
    loop {
        let item = tokio::select! {
            item = global.recv() => item,
            item = panes.recv() => item,
            () = wait_until(resnapshot_at) => {
                resnapshot_at = None;
                let fresh = snapshot(conn).await?;
                if fresh.pane_ids() != state.pane_ids() {
                    panes = PaneStatus::subscribe(conn, &fresh).await?;
                }
                if fresh != state {
                    state = fresh;
                    publish(tx, SyncStatus::Live, &state);
                }
                continue;
            }
            () = tx.closed() => return Err(SyncError::Unobserved),
        };
        match state.apply(&parse_event(item?)?) {
            Applied::Updated => publish(tx, SyncStatus::Live, &state),
            Applied::Unchanged => {}
            Applied::NeedsSnapshot => {
                resnapshot_at.get_or_insert_with(|| Instant::now() + RESNAPSHOT_DELAY);
            }
        }
    }
}

async fn snapshot(conn: &Connection) -> Result<SessionState, SyncError> {
    let result: SnapshotResult =
        serde_json::from_value(conn.request("session.snapshot", json!({})).await?)?;
    Ok(SessionState::from_snapshot(result.snapshot))
}

fn publish(tx: &watch::Sender<SyncState>, status: SyncStatus, state: &SessionState) {
    tx.send_replace(SyncState {
        status,
        session: Some(Arc::new(state.clone())),
    });
}

async fn wait_until(deadline: Option<Instant>) {
    match deadline {
        Some(deadline) => sleep_until(deadline).await,
        None => std::future::pending().await,
    }
}

fn backoff(attempt: u32) -> Duration {
    let secs = 1u64 << attempt.saturating_sub(1).min(5);
    Duration::from_secs(secs).min(MAX_BACKOFF)
}

/// Reads one subscription on its own task, because [`Subscription::next`] is
/// not cancel-safe. Dropping the forwarder stops the task and closes the stream.
struct Forwarder {
    rx: mpsc::Receiver<Result<Value, SyncError>>,
    task: JoinHandle<()>,
}

impl Forwarder {
    fn start(mut subscription: Subscription) -> Self {
        let (tx, rx) = mpsc::channel(64);
        let task = tokio::spawn(async move {
            loop {
                let item = match subscription.next().await {
                    Ok(Some(value)) => Ok(value),
                    Ok(None) => Err(SyncError::Closed),
                    Err(err) => Err(err.into()),
                };
                let last = item.is_err();
                if tx.send(item).await.is_err() || last {
                    return;
                }
            }
        });
        Self { rx, task }
    }

    async fn recv(&mut self) -> Result<Value, SyncError> {
        self.rx.recv().await.unwrap_or(Err(SyncError::Closed))
    }
}

impl Drop for Forwarder {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// The per-pane `pane.agent_status_changed` subscription. Without panes there
/// is nothing to subscribe and it simply never yields.
struct PaneStatus(Option<Forwarder>);

impl PaneStatus {
    async fn subscribe(conn: &Connection, state: &SessionState) -> Result<Self, SyncError> {
        if state.panes.is_empty() {
            return Ok(Self(None));
        }
        let subscriptions = state
            .panes
            .iter()
            .map(|pane| json!({ "type": "pane.agent_status_changed", "pane_id": pane.pane_id }))
            .collect();
        let subscription = conn.subscribe_to(subscriptions).await?;
        Ok(Self(Some(Forwarder::start(subscription))))
    }

    async fn recv(&mut self) -> Result<Value, SyncError> {
        match &mut self.0 {
            Some(forwarder) => forwarder.recv().await,
            None => std::future::pending().await,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_grows_and_caps() {
        let secs: Vec<u64> = (1..=8).map(|a| backoff(a).as_secs()).collect();
        assert_eq!(secs, [1, 2, 4, 8, 16, 30, 30, 30]);
    }
}
