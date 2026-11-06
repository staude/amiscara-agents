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
//! A host may run herdr-core (#329) beside the herdr server, or instead of
//! it. Each connection first asks both (`ping`, `hello`); herdr-core's
//! terminals come from its own `events.subscribe`, which starts with all
//! terminals and then sends every change, with a heartbeat every 15 s. The
//! driver checks for a missing server every [`BRANCH_REFRESH`] and connects
//! again when one appears.
//!
//! Only read-only methods are used: `ping`, `session.snapshot`,
//! `events.subscribe`, `worktree.list`, `agent.get` and
//! `pane.process_info` on herdr; `hello`, `events.subscribe`,
//! `terminal.list` and `machine.exec` with `git rev-parse` on herdr-core.

use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use std::collections::BTreeMap;

use herdr_proto::hc::{HC_GENERATION, HelloResult, Notification, SubscribeResult, Terminal};
use herdr_proto::{
    AgentGetResult, AgentStatus, Event, GLOBAL_SUBSCRIPTIONS, PaneProcessInfoResult, ProtoError,
    SnapshotResult, WorktreeListResult, parse_event,
};
use herdr_transport::{Connection, HcSubscription, Subscription, TransportError};
use serde_json::{Value, json};
use tokio::sync::{Notify, mpsc, watch};
use tokio::task::JoinHandle;
use tokio::time::{Instant, sleep, sleep_until};

use crate::programs::{self, ProgramMatch};
use crate::{Applied, SessionState};

/// How long structural events are collected before one snapshot answers them.
const RESNAPSHOT_DELAY: Duration = Duration::from_millis(150);
const MAX_BACKOFF: Duration = Duration::from_secs(30);
/// Branches change by checkouts, which herdr reports with no event. Also
/// how often a missing server is looked for.
const BRANCH_REFRESH: Duration = Duration::from_secs(30);
/// A pane's program changes (`vim`, `npm run dev`) with no event either.
const PROGRAM_REFRESH: Duration = Duration::from_secs(5);
/// At most this many `pane.process_info` requests at once: over a
/// restricted key every request is an SSH session channel, and sshd allows
/// 10 per connection (`MaxSessions`), shared with everything else.
const PROGRAM_REQUESTS: usize = 3;
/// How long `ping` and `hello` may take when looking for the servers.
/// As long as opening a channel may take over SSH.
const DETECT_TIMEOUT: Duration = Duration::from_secs(10);
/// herdr-core sends a heartbeat every 15 s; this long without anything the
/// stream counts as lost.
const HC_SILENCE: Duration = Duration::from_secs(45);
/// Branch refreshes (5 min) before herdr-core is asked again after its
/// subscription failed while herdr runs.
const HC_RETRY_TICKS: u32 = 10;

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
    /// Neither server answers; herdr's error, which says why.
    #[error("{0}")]
    NoBackend(String),
    #[error("another server started on the host")]
    BackendAppeared,
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
        // A server that started beside the other one: connect again at once.
        let Some(error) = outcome.filter(|error| !matches!(error, SyncError::BackendAppeared))
        else {
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
    let (herdr, hc_version) = detect(conn).await;
    let has_herdr = herdr.is_ok();
    if let (Err(error), None) = (herdr, &hc_version) {
        return Err(SyncError::NoBackend(error));
    }
    let mut global = None;
    let mut state = match &hc_version {
        Some(version) if !has_herdr => SessionState::without_herdr(version),
        _ => {
            let subscription = conn
                .subscribe_to(
                    GLOBAL_SUBSCRIPTIONS
                        .iter()
                        .map(|t| json!({ "type": t }))
                        .collect(),
                )
                .await?;
            global = Some(Forwarder::start(subscription));
            snapshot(conn).await?
        }
    };
    state.backends.hc = hc_version.clone();
    // A core that greets but cannot be followed does not take herdr down
    // with it: herdr goes on alone, and herdr-core is asked again after
    // [`HC_RETRY_TICKS`] branch refreshes.
    let mut hc_retry_ticks = 0;
    let mut hc = match hc_version {
        Some(_) => match HcFeed::subscribe(conn).await {
            Ok(feed) => Some(feed),
            Err(_) if has_herdr => {
                state.backends.hc = None;
                hc_retry_ticks = HC_RETRY_TICKS;
                None
            }
            Err(err) => return Err(err),
        },
        None => None,
    };
    if let Some(hc) = &hc {
        state.replace_hc(&hc.terminals);
    }
    state.branches = branches(conn, &state, true).await;
    if let Some(feed) = hc.as_mut() {
        feed.heard = Instant::now();
    }
    let mut panes = if has_herdr {
        PaneStatus::subscribe(conn, &state).await?
    } else {
        PaneStatus(None)
    };
    // Programs come from their own task, so neither the first `Live` nor
    // the events wait for them.
    let mut programs = ProgramPoller::start(Arc::clone(conn), &state);
    *attempt = 0;
    publish(tx, SyncStatus::Live, &state);

    let refresh = Arc::clone(&tx.borrow().refresh);
    let mut resnapshot_at: Option<Instant> = None;
    let mut hc_list_at: Option<Instant> = None;
    let mut branch_refresh =
        tokio::time::interval_at(Instant::now() + BRANCH_REFRESH, BRANCH_REFRESH);
    loop {
        let silence = hc.as_ref().map(|hc| hc.heard + HC_SILENCE);
        let item = tokio::select! {
            item = recv(&mut global) => item,
            item = panes.recv() => item,
            item = recv_hc(&mut hc) => {
                let value = item?;
                let Some(feed) = hc.as_mut() else { continue };
                feed.heard = Instant::now();
                match feed.notice(&parse_notification(&value)?) {
                    HcNotice::Changed => {
                        if state.replace_hc(&feed.terminals) == Applied::Updated {
                            publish(tx, SyncStatus::Live, &state);
                        }
                    }
                    HcNotice::Quiet => {}
                    HcNotice::NeedsList => {
                        hc_list_at.get_or_insert_with(|| Instant::now() + RESNAPSHOT_DELAY);
                    }
                }
                continue;
            }
            _ = branch_refresh.tick() => {
                if (!state.backends.herdr && ping(conn).await.is_ok())
                    || (state.backends.hc.is_none()
                        && retry_due(&mut hc_retry_ticks)
                        && hello(conn).await.is_some())
                {
                    return Err(SyncError::BackendAppeared);
                }
                let fresh = branches(conn, &state, true).await;
                // Waiting here is not the core going quiet.
                if let Some(feed) = hc.as_mut() {
                    feed.heard = Instant::now();
                }
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
                fresh.backends = state.backends.clone();
                if let Some(hc) = &hc {
                    fresh.replace_hc(&hc.terminals);
                }
                // herdr-core's branches stay until the next refresh.
                fresh.branches = branches(conn, &fresh, false).await;
                let kept: Vec<(String, String)> = state
                    .branches
                    .iter()
                    .filter(|(id, _)| crate::hc::is_hc(id) && fresh.workspace(id).is_some())
                    .map(|(id, branch)| (id.clone(), branch.clone()))
                    .collect();
                fresh.branches.extend(kept);
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
            () = wait_until(hc_list_at) => {
                hc_list_at = None;
                if let Some(feed) = hc.as_mut() {
                    // A stalled link must not hold up herdr's events; the
                    // heartbeat watch tells a dead core.
                    let Ok(list) =
                        tokio::time::timeout(DETECT_TIMEOUT, crate::hc::list(conn)).await
                    else {
                        hc_list_at = Some(Instant::now() + RESNAPSHOT_DELAY);
                        continue;
                    };
                    feed.terminals = list?;
                    if state.replace_hc(&feed.terminals) == Applied::Updated {
                        publish(tx, SyncStatus::Live, &state);
                    }
                }
                continue;
            }
            () = wait_until(silence) => return Err(SyncError::Closed),
            () = refresh.notified() => {
                if state.backends.herdr {
                    resnapshot_at.get_or_insert_with(|| Instant::now() + RESNAPSHOT_DELAY);
                } else {
                    hc_list_at.get_or_insert_with(|| Instant::now() + RESNAPSHOT_DELAY);
                }
                continue;
            }
            () = tx.closed() => return Err(SyncError::Unobserved),
        };
        let event = parse_event(item?)?;
        // Only the pane an event changes, not a copy of the whole state
        // for every output event.
        let before = event_pane(&event).and_then(|id| state.pane(id).cloned());
        match state.apply(&event) {
            Applied::Updated => {
                // A new finish: which one it is decides whether a client
                // has seen it (#335).
                if let Some(pane_id) = finish_to_fetch(before.as_ref(), &state, &event) {
                    let pane_id = pane_id.to_owned();
                    let seq = finish(conn, &pane_id).await;
                    state.set_completion_seq(&pane_id, seq);
                }
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

/// Counts down a pause in branch refreshes; true when it is over.
fn retry_due(ticks: &mut u32) -> bool {
    if *ticks == 0 {
        return true;
    }
    *ticks -= 1;
    false
}

fn parse_notification(value: &Value) -> Result<Notification, SyncError> {
    Ok(herdr_proto::hc::parse_notification(value)?)
}

/// Which servers answer: herdr (`ping`, also with an error, which only a
/// herdr server sends) and herdr-core (`hello`, with its version), each
/// within [`DETECT_TIMEOUT`].
async fn detect(conn: &Connection) -> (Result<(), String>, Option<String>) {
    tokio::join!(ping(conn), hello(conn))
}

/// `Ok` when a herdr server answers, else why not.
async fn ping(conn: &Connection) -> Result<(), String> {
    match tokio::time::timeout(DETECT_TIMEOUT, conn.request("ping", json!({}))).await {
        Ok(Ok(_) | Err(TransportError::Proto(ProtoError::Api { .. }))) => Ok(()),
        Ok(Err(err)) => Err(err.to_string()),
        Err(_) => Err(TransportError::Timeout.to_string()),
    }
}

async fn hello(conn: &Connection) -> Option<String> {
    let answer = tokio::time::timeout(
        DETECT_TIMEOUT,
        conn.hc_request("hello", json!({ "generation": HC_GENERATION })),
    )
    .await
    .ok()?
    .ok()?;
    // Another generation counts as no herdr-core.
    serde_json::from_value::<HelloResult>(answer)
        .ok()
        .filter(|hello| hello.generation == HC_GENERATION)
        .map(|hello| hello.version)
}

/// herdr-core's live terminals and the subscription that keeps them.
struct HcFeed {
    terminals: Vec<Terminal>,
    /// The last event's number; after a `missed` snapshot older ones are
    /// dropped.
    seq: u64,
    /// When the core last said anything, heartbeats included.
    heard: Instant,
    forwarder: Forwarder,
}

/// What a notification did to an [`HcFeed`].
enum HcNotice {
    Changed,
    Quiet,
    NeedsList,
}

impl HcFeed {
    async fn subscribe(conn: &Connection) -> Result<Self, SyncError> {
        let (snapshot, subscription) = conn.hc_subscribe(json!({})).await?;
        let snapshot: SubscribeResult = serde_json::from_value(snapshot)?;
        Ok(Self {
            terminals: live(snapshot.terminals),
            seq: snapshot.seq,
            heard: Instant::now(),
            forwarder: Forwarder::start_hc(subscription),
        })
    }

    fn notice(&mut self, notification: &Notification) -> HcNotice {
        match notification {
            Notification::Event {
                seq,
                terminal,
                kind,
                data,
            } => {
                if *seq != 0 && *seq <= self.seq {
                    return HcNotice::Quiet;
                }
                self.seq = (*seq).max(self.seq);
                match crate::hc::apply_event(&mut self.terminals, terminal, kind, data) {
                    crate::hc::EventOutcome::Applied => HcNotice::Changed,
                    crate::hc::EventOutcome::NeedsList => HcNotice::NeedsList,
                }
            }
            Notification::Missed { params } => {
                match serde_json::from_value::<SubscribeResult>(params.clone()) {
                    Ok(snapshot) if params.get("terminals").is_some() => {
                        self.terminals = live(snapshot.terminals);
                        self.seq = snapshot.seq;
                        HcNotice::Changed
                    }
                    _ => HcNotice::NeedsList,
                }
            }
            Notification::Heartbeat { .. } | Notification::Other => HcNotice::Quiet,
        }
    }
}

fn live(mut terminals: Vec<Terminal>) -> Vec<Terminal> {
    terminals.retain(Terminal::is_live);
    terminals
}

async fn recv(forwarder: &mut Option<Forwarder>) -> Result<Value, SyncError> {
    match forwarder {
        Some(forwarder) => forwarder.recv().await,
        None => std::future::pending().await,
    }
}

async fn recv_hc(feed: &mut Option<HcFeed>) -> Result<Value, SyncError> {
    match feed {
        Some(feed) => feed.forwarder.recv().await,
        None => std::future::pending().await,
    }
}

/// Branch per workspace, resolved like herdr's sidebar: the working
/// directory of the space's focused pane decides, not the directory the
/// space was created for. The branch comes from the `worktree.list` entry
/// whose path contains that directory. One call lists all worktrees of a
/// repository; spaces outside git get no branch.
async fn branches(
    conn: &Connection,
    state: &SessionState,
    with_hc: bool,
) -> BTreeMap<String, String> {
    let mut worktrees: Vec<(String, String)> = Vec::new(); // (path, branch)
    let mut found = BTreeMap::new();
    // herdr-core's spaces: `git` in the directory, once per directory.
    let mut hc_dirs: BTreeMap<(Option<String>, String), Option<String>> = BTreeMap::new();
    for workspace in &state.workspaces {
        let Some(cwd) = space_directory(state, &workspace.workspace_id) else {
            continue;
        };
        if crate::hc::is_hc(&workspace.workspace_id) {
            if !with_hc {
                continue;
            }
            let machine = crate::hc::machine_of(&workspace.workspace_id).map(str::to_owned);
            let key = (machine, cwd);
            let branch = match hc_dirs.get(&key) {
                Some(branch) => branch.clone(),
                None => {
                    let branch = crate::hc::branch(conn, &key.1, key.0.as_deref()).await;
                    hc_dirs.insert(key, branch.clone());
                    branch
                }
            };
            if let Some(branch) = branch {
                found.insert(workspace.workspace_id.clone(), branch);
            }
            continue;
        }
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
        // herdr-core's panes are no herdr panes.
        .filter(|pane| pane.agent.is_none() && !crate::hc::is_hc(&pane.pane_id))
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

/// The pane whose finish number to fetch after `event` took `before` to
/// `after`: a done agent without a known number that just became done or
/// got a new seen mark, which the number decides. herdr may announce a
/// change of status with `pane.updated` as well as with
/// `pane.agent_status_changed`, in either order.
fn finish_to_fetch<'a>(
    before: Option<&herdr_proto::PaneInfo>,
    after: &SessionState,
    event: &'a Event,
) -> Option<&'a str> {
    let pane_id = event_pane(event)?;
    let pane = after.pane(pane_id)?;
    if pane.agent_status != AgentStatus::Done || after.completion_seqs.contains_key(pane_id) {
        return None;
    }
    let mark = |pane: &herdr_proto::PaneInfo| pane.tokens.get(crate::SEEN_TOKEN).cloned();
    before
        .is_none_or(|old| old.agent_status != AgentStatus::Done || mark(old) != mark(pane))
        .then_some(pane_id)
}

/// The pane whose status or tokens an event may change.
fn event_pane(event: &Event) -> Option<&str> {
    match event {
        Event::PaneAgentStatusChanged { pane_id, .. } => Some(pane_id),
        Event::PaneUpdated { pane } => Some(&pane.pane_id),
        _ => None,
    }
}

/// The `completion_seq` of the finish the agent in `pane_id` is in, from
/// `agent.get`; `None` on an error or when herdr does not count finishes.
async fn finish(conn: &Connection, pane_id: &str) -> Option<u64> {
    let value = conn
        .request("agent.get", json!({ "target": pane_id }))
        .await
        .ok()?;
    let got = serde_json::from_value::<AgentGetResult>(value).ok()?;
    crate::state::finish_seq(&got.agent)
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

    /// The same for herdr-core's notifications.
    fn start_hc(mut subscription: HcSubscription) -> Self {
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
        let subscriptions: Vec<Value> = state
            .panes
            .iter()
            .filter(|pane| !crate::hc::is_hc(&pane.pane_id))
            .map(|pane| json!({ "type": "pane.agent_status_changed", "pane_id": pane.pane_id }))
            .collect();
        if subscriptions.is_empty() {
            return Ok(Self(None));
        }
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
    use serde_json::json;

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
        let path = std::env::temp_dir().join(format!(
            "herdr-client-reconnect-{}.sock",
            std::process::id()
        ));
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

    // A herdr-core stand-in on a Unix socket, without a herdr server: one
    // terminal in the snapshot, then a status change on the subscription.
    #[cfg(unix)]
    #[tokio::test]
    async fn a_host_with_only_herdr_core_shows_its_terminals() {
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
        use tokio::net::UnixListener;

        let dir = std::env::temp_dir();
        let hc_path = dir.join(format!("herdr-client-hc-{}.sock", std::process::id()));
        let herdr_path = dir.join(format!("herdr-client-no-herdr-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&hc_path);
        let listener = UnixListener::bind(&hc_path).expect("bind fake hc");
        let terminal = json!({
            "address": "t1", "cwd": "/x", "state": "live", "created_ms": 1, "argv": ["claude"],
            "labels": {"herdr.space": "sp1", "herdr.tab": "tb1", "where": "Kino / 1"},
            "status": {"app": "claude-code", "state": "working"}
        });
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let terminal = terminal.clone();
                tokio::spawn(async move {
                    let (read, mut write) = stream.into_split();
                    let mut lines = BufReader::new(read).lines();
                    while let Ok(Some(line)) = lines.next_line().await {
                        let request: Value = serde_json::from_str(&line).expect("json");
                        let result = match request["method"].as_str() {
                            Some("hello") => json!({"generation": 1, "version": "0.1.18",
                                "core": {"id": "c", "name": "work"}, "framed": false,
                                "methods": [], "features": []}),
                            Some("events.subscribe") => {
                                json!({"seq": 5, "terminals": [terminal]})
                            }
                            Some("terminal.list") => json!({"terminals": [terminal]}),
                            Some("machine.exec") => json!({"code": 1, "stdout": "", "stderr": "",
                                "truncated": false, "timed_out": false, "ms": 1}),
                            _ => json!({}),
                        };
                        let reply =
                            json!({"jsonrpc": "2.0", "id": request["id"], "result": result});
                        if write
                            .write_all(format!("{reply}\n").as_bytes())
                            .await
                            .is_err()
                        {
                            return;
                        }
                        if request["method"] == "events.subscribe" {
                            let event = json!({"jsonrpc": "2.0", "method": "event", "params": {
                                "seq": 6, "terminal": "t1", "type": "status",
                                "data": {"status": {"app": "claude-code", "state": "blocked"}}}});
                            let _ = write.write_all(format!("{event}\n").as_bytes()).await;
                        }
                    }
                });
            }
        });

        let rx = spawn({
            let (herdr_path, hc_path) = (herdr_path.clone(), hc_path.clone());
            move || {
                let conn = Connection::local_with_hc(&herdr_path, Some(hc_path.clone()));
                async move { Ok(conn) }
            }
        });
        let mut watcher = rx.clone();
        let state = tokio::time::timeout(
            Duration::from_secs(10),
            watcher.wait_for(|state| {
                state.session.as_ref().is_some_and(|session| {
                    session
                        .pane("hc:t1")
                        .is_some_and(|pane| pane.agent_status == herdr_proto::AgentStatus::Blocked)
                })
            }),
        )
        .await
        .expect("blocked within 10 s")
        .expect("driver runs")
        .clone();
        assert_eq!(state.status, SyncStatus::Live);
        let session = state.session.expect("session");
        assert!(!session.backends.herdr);
        assert_eq!(session.backends.hc.as_deref(), Some("0.1.18"));
        assert_eq!(session.version, "herdr-core 0.1.18");
        assert_eq!(session.workspaces[0].label, "Kino");
        assert_eq!(
            session.pane("hc:t1").and_then(|pane| pane.agent.clone()),
            Some("claude".to_owned())
        );
        let _ = std::fs::remove_file(&hc_path);
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

    fn fetch_state(status: &str, seen: Option<&str>) -> SessionState {
        let tokens = seen.map_or_else(|| json!({}), |mark| json!({ crate::SEEN_TOKEN: mark }));
        let snapshot = json!({
            "version": "0.9.5", "protocol": 22,
            "workspaces": [{"workspace_id": "w1", "number": 1, "label": "web"}],
            "tabs": [{"tab_id": "w1:t1", "workspace_id": "w1", "number": 1, "label": "1"}],
            "panes": [{"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
                       "agent": "claude", "agent_status": status, "tokens": tokens}]
        });
        SessionState::from_snapshot(serde_json::from_value(snapshot).expect("snapshot"))
    }

    fn status_event(status: &str) -> Event {
        parse_event(json!({
            "event": "pane.agent_status_changed",
            "data": {"pane_id": "w1:p1", "workspace_id": "w1", "agent_status": status}
        }))
        .expect("event")
    }

    fn pane_event(state: &SessionState) -> Event {
        Event::PaneUpdated {
            pane: state.pane("w1:p1").cloned().expect("pane"),
        }
    }

    /// What the driver does: apply, then ask which finish to fetch.
    fn fetch_after(before: &SessionState, event: &Event) -> Option<String> {
        let mut after = before.clone();
        after.apply(event);
        finish_to_fetch(before.pane("w1:p1"), &after, event).map(str::to_owned)
    }

    #[test]
    fn a_change_to_done_fetches_its_finish_by_either_event() {
        let working = fetch_state("working", None);
        assert_eq!(
            fetch_after(&working, &status_event("done")).as_deref(),
            Some("w1:p1")
        );
        let done = fetch_state("done", None);
        assert_eq!(
            fetch_after(&working, &pane_event(&done)).as_deref(),
            Some("w1:p1")
        );
        // The second announcement of the same change fetches nothing more.
        assert_eq!(fetch_after(&done, &status_event("done")), None);
        assert_eq!(fetch_after(&working, &status_event("idle")), None);
    }

    #[test]
    fn a_new_mark_fetches_a_missed_finish_but_a_known_one_is_kept() {
        let done = fetch_state("done", None);
        let marked = fetch_state("done", Some("7"));
        assert_eq!(
            fetch_after(&done, &pane_event(&marked)).as_deref(),
            Some("w1:p1")
        );
        let mut known = done.clone();
        known.set_completion_seq("w1:p1", Some(7));
        assert_eq!(fetch_after(&known, &pane_event(&marked)), None);
        // Same mark, nothing to decide.
        let mut retitled = marked.clone();
        if let Some(pane) = retitled.panes.first_mut() {
            pane.title = Some("other".into());
        }
        assert_eq!(fetch_after(&marked, &pane_event(&retitled)), None);
    }

    #[test]
    fn backoff_grows_and_caps() {
        let secs: Vec<u64> = (1..=8).map(|a| backoff(a).as_secs()).collect();
        assert_eq!(secs, [1, 2, 4, 8, 16, 30, 30, 30]);
    }
}
