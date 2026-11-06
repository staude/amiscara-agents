//! Keeps a [`SessionState`] in step with a live server.
//!
//! Per connection: subscribe to the global events first, then take
//! `session.snapshot`, so nothing that happens in between is missed. Agent
//! status needs one subscription entry per pane; that subscription is replaced
//! whenever the set of panes changes. Structural events are collected for a
//! short moment and answered with one fresh snapshot. When the connection
//! breaks, the driver reconnects with growing pauses. Errors only the user
//! can resolve (unknown or changed host key, refused login) end the driver
//! with a status that says so. On request the driver drops the connection
//! and connects again at once, keeping the last state (#264).
//!
//! Beside that it polls what herdr reports without an event: the branch per
//! space (`worktree.list`) and the program in each pane without an agent
//! (`pane.process_info`, #337).
//!
//! Only read-only methods are used: `session.snapshot`, `events.subscribe`,
//! `worktree.list` and `pane.process_info`.

use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use std::collections::BTreeMap;

use herdr_proto::{
    GLOBAL_SUBSCRIPTIONS, PaneProcessInfoResult, ProtoError, SnapshotResult, WorktreeListResult,
    parse_event,
};
use herdr_transport::{Connection, Subscription, TransportError};
use serde_json::{Value, json};
use tokio::sync::{Notify, mpsc, watch};
use tokio::task::JoinHandle;
use tokio::time::{Instant, sleep, sleep_until};

use crate::programs::{self, ProgramMatch};
use crate::{Applied, SessionState};

/// How long structural events are collected before one snapshot answers them.
const RESNAPSHOT_DELAY: Duration = Duration::from_millis(150);
const MAX_BACKOFF: Duration = Duration::from_secs(30);
/// Branches change by checkouts, which herdr reports with no event.
const BRANCH_REFRESH: Duration = Duration::from_secs(30);
/// A pane's program changes (`vim`, `npm run dev`) with no event either.
const PROGRAM_REFRESH: Duration = Duration::from_secs(5);
/// At most this many `pane.process_info` requests at once: over a
/// restricted key every request is an SSH session channel, and sshd allows
/// 10 per connection (`MaxSessions`), shared with everything else.
const PROGRAM_REQUESTS: usize = 3;

#[derive(Debug, Clone, PartialEq)]
pub enum SyncStatus {
    Connecting,
    Live,
    /// The last attempt failed; the driver waits and tries again.
    Retrying {
        attempt: u32,
        error: String,
    },
    /// The server's host key is not trusted yet. The driver has stopped;
    /// start a new one with `key` pinned once the user agrees.
    HostKeyUnknown {
        key: String,
        fingerprint: String,
    },
    /// The server presents a different key than the pinned one. Stopped.
    HostKeyChanged {
        key: String,
        fingerprint: String,
    },
    /// Login refused or the key unusable. Stopped.
    Failed {
        error: String,
    },
}

/// What observers see. `session` keeps the last known state while the driver
/// reconnects, so a UI can show it greyed out instead of going blank.
/// `connection` is the live connection while there is one, for work beside
/// the sync such as following a pane.
#[derive(Clone)]
pub struct SyncState {
    pub status: SyncStatus,
    pub session: Option<Arc<SessionState>>,
    pub connection: Option<Arc<Connection>>,
    /// Asks the driver for a fresh snapshot, for changes herdr announces
    /// without the data (an agent's new name). Shared by all clones.
    pub refresh: Arc<Notify>,
    /// Asks the driver to connect again at once. Shared by all clones.
    pub reconnect: Arc<Notify>,
}

impl SyncState {
    /// Takes a fresh snapshot soon; harmless while not connected.
    pub fn request_snapshot(&self) {
        self.refresh.notify_one();
    }

    /// Drops the current connection or connection attempt and connects
    /// again right away, without the pause between retries. `session` stays,
    /// so the first snapshot afterwards is compared with what was known
    /// before. Does nothing once the driver has stopped; see
    /// [`watch::Receiver::has_changed`] for telling.
    pub fn request_reconnect(&self) {
        self.reconnect.notify_one();
    }
}

impl std::fmt::Debug for SyncState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SyncState")
            .field("status", &self.status)
            .field("session", &self.session)
            .field("connected", &self.connection.is_some())
            .finish()
    }
}

impl Default for SyncState {
    fn default() -> Self {
        Self {
            status: SyncStatus::Connecting,
            session: None,
            connection: None,
            refresh: Arc::new(Notify::new()),
            reconnect: Arc::new(Notify::new()),
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
    let reconnect = Arc::clone(&tx.borrow().reconnect);
    let mut attempt = 0u32;
    loop {
        // A requested reconnect cancels the attempt, even a connect that
        // hangs on a link that died while the device slept.
        let connecting = connect();
        let outcome = tokio::select! {
            error = async {
                match connecting.await {
                    Ok(conn) => {
                        let conn = Arc::new(conn);
                        tx.send_modify(|state| state.connection = Some(Arc::clone(&conn)));
                        follow(&conn, &tx, &mut attempt).await
                    }
                    Err(err) => SyncError::from(err),
                }
            } => Some(error),
            () = reconnect.notified() => None,
        };
        let Some(error) = outcome else {
            attempt = 0;
            restart(&tx);
            continue;
        };
        if matches!(error, SyncError::Unobserved) || tx.is_closed() {
            return;
        }
        if let Some(status) = stop_status(&error) {
            tx.send_modify(|state| {
                state.status = status;
                state.connection = None;
            });
            return;
        }
        attempt = attempt.saturating_add(1);
        tx.send_modify(|state| {
            state.status = SyncStatus::Retrying {
                attempt,
                error: error.to_string(),
            };
            state.connection = None;
        });
        tokio::select! {
            () = sleep(backoff(attempt)) => {}
            () = reconnect.notified() => {
                attempt = 0;
                restart(&tx);
            }
            () = tx.closed() => return,
        }
    }
}

/// Marks a reconnect on request: connecting again, the state kept.
fn restart(tx: &watch::Sender<SyncState>) {
    tx.send_modify(|state| {
        state.status = SyncStatus::Connecting;
        state.connection = None;
    });
}

/// The final status for errors a retry cannot fix.
fn stop_status(error: &SyncError) -> Option<SyncStatus> {
    let SyncError::Transport(err) = error else {
        return None;
    };
    match err {
        TransportError::UnknownHostKey {
            key, fingerprint, ..
        } => Some(SyncStatus::HostKeyUnknown {
            key: key.clone(),
            fingerprint: fingerprint.clone(),
        }),
        TransportError::HostKeyChanged {
            key, fingerprint, ..
        } => Some(SyncStatus::HostKeyChanged {
            key: key.clone(),
            fingerprint: fingerprint.clone(),
        }),
        err if err.needs_user() => Some(SyncStatus::Failed {
            error: err.to_string(),
        }),
        _ => None,
    }
}

/// Follows one connection until it fails. Always returns the reason.
async fn follow(
    conn: &Arc<Connection>,
    tx: &watch::Sender<SyncState>,
    attempt: &mut u32,
) -> SyncError {
    match follow_inner(conn, tx, attempt).await {
        Ok(never) => match never {},
        Err(err) => err,
    }
}

enum Never {}

async fn follow_inner(
    conn: &Arc<Connection>,
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
    state.branches = branches(conn, &state).await;
    let mut panes = PaneStatus::subscribe(conn, &state).await?;
    // Programs come from their own task, so neither the first `Live` nor
    // the events wait for them.
    let mut programs = ProgramPoller::start(Arc::clone(conn), &state);
    *attempt = 0;
    publish(tx, SyncStatus::Live, &state);

    let refresh = Arc::clone(&tx.borrow().refresh);
    let mut resnapshot_at: Option<Instant> = None;
    let mut branch_refresh =
        tokio::time::interval_at(Instant::now() + BRANCH_REFRESH, BRANCH_REFRESH);
    loop {
        let item = tokio::select! {
            item = global.recv() => item,
            item = panes.recv() => item,
            _ = branch_refresh.tick() => {
                let fresh = branches(conn, &state).await;
                if fresh != state.branches {
                    state.branches = fresh;
                    publish(tx, SyncStatus::Live, &state);
                }
                continue;
            }
            Some(found) = programs.rx.recv() => {
                let fresh = merge_programs(&state, found);
                if fresh != state.programs {
                    state.programs = fresh;
                    publish(tx, SyncStatus::Live, &state);
                }
                continue;
            }
            () = wait_until(resnapshot_at) => {
                resnapshot_at = None;
                let mut fresh = snapshot(conn).await?;
                fresh.branches = branches(conn, &fresh).await;
                // Carried like the branches; the poller refreshes them.
                fresh.programs = state.programs.clone();
                fresh.programs = merge_programs(&fresh, Vec::new());
                if fresh.pane_ids() != state.pane_ids() {
                    panes = PaneStatus::subscribe(conn, &fresh).await?;
                }
                programs.follow(&fresh);
                if fresh != state {
                    state = fresh;
                    publish(tx, SyncStatus::Live, &state);
                }
                continue;
            }
            () = refresh.notified() => {
                resnapshot_at.get_or_insert_with(|| Instant::now() + RESNAPSHOT_DELAY);
                continue;
            }
            () = tx.closed() => return Err(SyncError::Unobserved),
        };
        match state.apply(&parse_event(item?)?) {
            Applied::Updated => {
                // An agent that started or ended changes which panes the
                // poller asks (#337).
                programs.follow(&state);
                publish(tx, SyncStatus::Live, &state);
            }
            Applied::Unchanged => {}
            Applied::NeedsSnapshot => {
                resnapshot_at.get_or_insert_with(|| Instant::now() + RESNAPSHOT_DELAY);
            }
        }
    }
}

/// Branch per workspace, resolved like herdr's sidebar: the working
/// directory of the space's focused pane decides, not the directory the
/// space was created for. The branch comes from the `worktree.list` entry
/// whose path contains that directory. One call lists all worktrees of a
/// repository; spaces outside git get no branch.
async fn branches(conn: &Connection, state: &SessionState) -> BTreeMap<String, String> {
    let mut worktrees: Vec<(String, String)> = Vec::new(); // (path, branch)
    let mut found = BTreeMap::new();
    for workspace in &state.workspaces {
        let Some(cwd) = space_directory(state, &workspace.workspace_id) else {
            continue;
        };
        if let Some(branch) = branch_for(&worktrees, &cwd) {
            found.insert(workspace.workspace_id.clone(), branch);
            continue;
        }
        let Ok(value) = conn
            .request(
                "worktree.list",
                json!({ "workspace_id": workspace.workspace_id }),
            )
            .await
        else {
            continue;
        };
        let Ok(list) = serde_json::from_value::<WorktreeListResult>(value) else {
            continue;
        };
        worktrees.extend(
            list.worktrees
                .into_iter()
                .filter_map(|entry| entry.branch.map(|branch| (entry.path, branch))),
        );
        if let Some(branch) = branch_for(&worktrees, &cwd) {
            found.insert(workspace.workspace_id.clone(), branch);
        }
    }
    found
}

/// One pane's answer from the [`ProgramPoller`]: `Err` when the request
/// failed, so the last known program stays.
type ProgramAnswer = (String, Result<Option<ProgramMatch>, ()>);

/// Panes that get a `pane.process_info` request. Agent panes need none:
/// herdr names the agent, and their foreground group also holds the
/// agent's MCP servers.
fn program_panes(state: &SessionState) -> Vec<String> {
    state
        .panes
        .iter()
        .filter(|pane| pane.agent.is_none())
        .map(|pane| pane.pane_id.clone())
        .collect()
}

/// The programs after one round: answered panes take the answer, failed
/// ones keep their last program, panes that are gone or now run an agent
/// drop out.
fn merge_programs(
    state: &SessionState,
    answers: Vec<ProgramAnswer>,
) -> BTreeMap<String, ProgramMatch> {
    let mut programs = state.programs.clone();
    for (pane_id, answer) in answers {
        match answer {
            Ok(Some(program)) => {
                programs.insert(pane_id, program);
            }
            Ok(None) => {
                programs.remove(&pane_id);
            }
            Err(()) => {}
        }
    }
    let wanted = program_panes(state);
    programs.retain(|pane_id, _| wanted.contains(pane_id));
    programs
}

/// Asks every [`PROGRAM_REFRESH`] what runs in the panes without an agent,
/// on its own task, at most [`PROGRAM_REQUESTS`] at once. The transport's
/// own timeouts apply, so a dead link is still noticed. Dropping the
/// poller stops the task.
struct ProgramPoller {
    rx: mpsc::Receiver<Vec<ProgramAnswer>>,
    panes: watch::Sender<Vec<String>>,
    task: JoinHandle<()>,
}

impl ProgramPoller {
    fn start(conn: Arc<Connection>, state: &SessionState) -> Self {
        let (tx, rx) = mpsc::channel(1);
        let (panes, mut wanted) = watch::channel(program_panes(state));
        let task = tokio::spawn(async move {
            loop {
                let ids = wanted.borrow_and_update().clone();
                if tx.send(query_programs(&conn, ids).await).await.is_err() {
                    return;
                }
                // The next round after the pause, or at once for new panes.
                tokio::select! {
                    () = sleep(PROGRAM_REFRESH) => {}
                    changed = wanted.changed() => if changed.is_err() { return },
                }
            }
        });
        Self { rx, panes, task }
    }

    /// Takes the panes of the current state; a changed set is asked at once.
    fn follow(&self, state: &SessionState) {
        follow_panes(&self.panes, state);
    }
}

impl Drop for ProgramPoller {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Hands the panes without an agent to the poller; `true` if they changed,
/// which starts a round at once.
fn follow_panes(panes: &watch::Sender<Vec<String>>, state: &SessionState) -> bool {
    panes.send_if_modified(|panes| {
        let fresh = program_panes(state);
        let changed = *panes != fresh;
        *panes = fresh;
        changed
    })
}

async fn query_programs(conn: &Arc<Connection>, pane_ids: Vec<String>) -> Vec<ProgramAnswer> {
    let mut answers = Vec::with_capacity(pane_ids.len());
    for chunk in pane_ids.chunks(PROGRAM_REQUESTS) {
        let mut requests = tokio::task::JoinSet::new();
        for pane_id in chunk {
            let conn = Arc::clone(conn);
            let pane_id = pane_id.clone();
            requests.spawn(async move {
                let answer = conn
                    .request("pane.process_info", json!({ "pane_id": pane_id }))
                    .await
                    .ok()
                    .and_then(|value| serde_json::from_value::<PaneProcessInfoResult>(value).ok())
                    .map(|result| programs::for_processes(&result.process_info))
                    .ok_or(());
                (pane_id, answer)
            });
        }
        while let Some(done) = requests.join_next().await {
            if let Ok(answer) = done {
                answers.push(answer);
            }
        }
    }
    answers
}

/// The directory that stands for a space: its focused pane in the active
/// tab, else the first pane of the active tab, else any pane of the space.
fn space_directory(state: &SessionState, workspace_id: &str) -> Option<String> {
    let active_tab = state
        .workspace(workspace_id)
        .map(|ws| ws.active_tab_id.as_str())
        .unwrap_or_default();
    let panes: Vec<_> = state
        .panes
        .iter()
        .filter(|pane| pane.workspace_id == workspace_id)
        .collect();
    let pane = panes
        .iter()
        .find(|pane| pane.tab_id == active_tab && pane.focused)
        .or_else(|| panes.iter().find(|pane| pane.tab_id == active_tab))
        .or_else(|| panes.first())?;
    pane.foreground_cwd.clone().or_else(|| pane.cwd.clone())
}

/// Branch of the innermost worktree containing `dir`.
fn branch_for(worktrees: &[(String, String)], dir: &str) -> Option<String> {
    worktrees
        .iter()
        .filter(|(path, _)| {
            let path = path.trim_end_matches('/');
            dir == path || dir.starts_with(&format!("{path}/"))
        })
        .max_by_key(|(path, _)| path.len())
        .map(|(_, branch)| branch.clone())
}

async fn snapshot(conn: &Connection) -> Result<SessionState, SyncError> {
    let result: SnapshotResult =
        serde_json::from_value(conn.request("session.snapshot", json!({})).await?)?;
    Ok(SessionState::from_snapshot(result.snapshot))
}

fn publish(tx: &watch::Sender<SyncState>, status: SyncStatus, state: &SessionState) {
    tx.send_modify(|current| {
        current.status = status;
        current.session = Some(Arc::new(state.clone()));
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
    fn branch_comes_from_the_innermost_worktree() {
        let worktrees = vec![
            ("/dev/enon".to_owned(), "production".to_owned()),
            ("/dev/enon/.worktrees/docs".to_owned(), "docs".to_owned()),
            ("/dev/enon-2375".to_owned(), "feature/2375".to_owned()),
        ];
        assert_eq!(
            branch_for(&worktrees, "/dev/enon").as_deref(),
            Some("production")
        );
        assert_eq!(
            branch_for(&worktrees, "/dev/enon/src").as_deref(),
            Some("production")
        );
        assert_eq!(
            branch_for(&worktrees, "/dev/enon/.worktrees/docs/a").as_deref(),
            Some("docs")
        );
        // A sibling directory with the same prefix is not inside the repo.
        assert_eq!(
            branch_for(&worktrees, "/dev/enon-2375").as_deref(),
            Some("feature/2375")
        );
        assert_eq!(branch_for(&worktrees, "/dev/other"), None);
    }

    // The fake server listens on a Unix socket, which `Connection::local` needs.
    #[cfg(unix)]
    #[tokio::test]
    async fn a_requested_reconnect_starts_over_at_once() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use tokio::net::UnixListener;

        // Takes connections and never answers, like a link that died while
        // the device slept.
        let path =
            std::env::temp_dir().join(format!("herdr-core-reconnect-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).expect("bind fake socket");
        tokio::spawn(async move {
            let mut held = Vec::new();
            while let Ok((stream, _)) = listener.accept().await {
                held.push(stream);
            }
        });

        let calls = Arc::new(AtomicUsize::new(0));
        let rx = spawn({
            let calls = Arc::clone(&calls);
            let path = path.clone();
            move || {
                // The second attempt hangs, so the state in between stays
                // visible.
                let first = calls.fetch_add(1, Ordering::SeqCst) == 0;
                let conn = Connection::local(&path);
                async move {
                    if !first {
                        std::future::pending::<()>().await;
                    }
                    Ok(conn)
                }
            }
        });
        let wait_for_calls = |n: usize| {
            let calls = Arc::clone(&calls);
            async move {
                let deadline = Instant::now() + Duration::from_secs(1);
                while calls.load(Ordering::SeqCst) < n && Instant::now() < deadline {
                    sleep(Duration::from_millis(5)).await;
                }
                calls.load(Ordering::SeqCst)
            }
        };
        assert_eq!(wait_for_calls(1).await, 1);
        let mut watcher = rx.clone();
        watcher
            .wait_for(|state| state.connection.is_some())
            .await
            .expect("driver runs");

        rx.borrow().request_reconnect();
        let state = watcher
            .wait_for(|state| state.connection.is_none())
            .await
            .expect("driver runs")
            .clone();
        assert_eq!(state.status, SyncStatus::Connecting);
        assert_eq!(wait_for_calls(2).await, 2, "second attempt within 1 s");
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn a_requested_reconnect_cuts_the_pause_short() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        // The first attempt fails and the driver waits a second; the second
        // attempt hangs, so its state stays visible.
        let calls = Arc::new(AtomicUsize::new(0));
        let rx = spawn({
            let calls = Arc::clone(&calls);
            move || {
                let first = calls.fetch_add(1, Ordering::SeqCst) == 0;
                async move {
                    if !first {
                        std::future::pending::<()>().await;
                    }
                    Err(TransportError::Closed)
                }
            }
        });
        let mut watcher = rx.clone();
        watcher
            .wait_for(|state| matches!(state.status, SyncStatus::Retrying { .. }))
            .await
            .expect("driver runs");
        let asked = Instant::now();
        rx.borrow().request_reconnect();
        watcher
            .wait_for(|state| state.status == SyncStatus::Connecting)
            .await
            .expect("driver runs");
        while calls.load(Ordering::SeqCst) < 2 && asked.elapsed() < Duration::from_secs(2) {
            sleep(Duration::from_millis(5)).await;
        }
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert!(
            asked.elapsed() < backoff(1) / 2,
            "second attempt without the pause"
        );
    }

    #[test]
    fn a_failed_program_request_keeps_the_last_program() {
        let snapshot: herdr_proto::SessionSnapshot = serde_json::from_value(json!({
            "version": "0.9.5", "protocol": 22, "workspaces": [], "tabs": [],
            "panes": [
                {"pane_id": "p1", "workspace_id": "w1", "tab_id": "t1"},
                {"pane_id": "p2", "workspace_id": "w1", "tab_id": "t1"},
                {"pane_id": "p3", "workspace_id": "w1", "tab_id": "t1", "agent": "claude"}
            ]
        }))
        .expect("snapshot");
        let mut state = SessionState::from_snapshot(snapshot);
        let vim = ProgramMatch::Unknown("vim-ish".into());
        state.programs.insert("p1".into(), vim.clone());
        state.programs.insert("p2".into(), vim.clone());
        state.programs.insert("p3".into(), vim.clone());
        state.programs.insert("gone".into(), vim.clone());
        let merged = merge_programs(
            &state,
            vec![("p1".into(), Err(())), ("p2".into(), Ok(None))],
        );
        // p1 failed and keeps vim; p2 has no process; p3 runs an agent now;
        // the closed pane is gone.
        assert_eq!(
            merged.into_iter().collect::<Vec<_>>(),
            vec![("p1".to_owned(), vim)]
        );
    }

    #[test]
    fn an_agent_that_ends_by_event_gets_its_pane_asked() {
        let snapshot: herdr_proto::SessionSnapshot = serde_json::from_value(json!({
            "version": "0.9.5", "protocol": 22, "workspaces": [], "tabs": [],
            "panes": [
                {"pane_id": "p1", "workspace_id": "w1", "tab_id": "t1"},
                {"pane_id": "p2", "workspace_id": "w1", "tab_id": "t1", "agent": "claude"}
            ]
        }))
        .expect("snapshot");
        let mut state = SessionState::from_snapshot(snapshot);
        let (panes, mut wanted) = watch::channel(program_panes(&state));
        assert_eq!(*wanted.borrow_and_update(), ["p1"]);
        assert!(!follow_panes(&panes, &state), "nothing changed yet");

        // Claude exits: herdr reports the pane without an agent.
        let event = parse_event(json!({
            "event": "pane.agent_detected",
            "data": {"type": "pane_agent_detected", "pane_id": "p2", "agent": null}
        }))
        .expect("event");
        assert_eq!(state.apply(&event), Applied::Updated);
        assert!(follow_panes(&panes, &state));
        assert!(wanted.has_changed().expect("open"));
        assert_eq!(*wanted.borrow_and_update(), ["p1", "p2"]);

        // And back: an agent starts, the pane drops out.
        let event = parse_event(json!({
            "event": "pane.agent_detected",
            "data": {"type": "pane_agent_detected", "pane_id": "p2", "agent": "codex"}
        }))
        .expect("event");
        assert_eq!(state.apply(&event), Applied::Updated);
        assert!(follow_panes(&panes, &state));
        assert_eq!(*wanted.borrow_and_update(), ["p1"]);
    }

    #[test]
    fn backoff_grows_and_caps() {
        let secs: Vec<u64> = (1..=8).map(|a| backoff(a).as_secs()).collect();
        assert_eq!(secs, [1, 2, 4, 8, 16, 30, 30, 30]);
    }
}
