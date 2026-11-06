//! Writing calls: input for panes and agents, new spaces, tabs and
//! worktrees, renames, closing tabs and spaces, agents started in a pane.
//!
//! Keys use herdr's logical names: `enter`, `esc`, `tab`, `backspace`,
//! `up`, `down`, `left`, `right`, single characters such as `1`, and
//! combinations such as `ctrl+c`. herdr validates all keys before it writes
//! anything.
//!
//! herdr-core's panes (ids starting `hc:`, #329) take prompts and keys
//! (`terminal.send`, `terminal.keys`, which know the same key names). Its
//! `terminal.keys` refuses characters such as umlauts, so text without
//! Enter is not offered there, and neither is anything that changes spaces,
//! tabs or agents, which herdr desktop keeps to itself:
//! [`ActionError::Unsupported`].

use herdr_proto::{PaneInfo, ProtoError};
use herdr_transport::{Connection, TransportError};
use serde_json::json;

#[derive(Debug, thiserror::Error)]
pub enum ActionError {
    /// `agent.prompt` refuses while the agent waits at an approval or
    /// question dialog. Answer that first (see [`send_keys`]).
    #[error("the agent is waiting for an answer")]
    AgentBlocked,
    /// herdr refused the call, e.g. unknown pane or invalid key.
    #[error("herdr refused ({code}): {message}")]
    Rejected { code: String, message: String },
    /// The server cannot do this, e.g. herdr-core with spaces and tabs.
    #[error("{0}")]
    Unsupported(String),
    #[error(transparent)]
    Transport(TransportError),
}

impl From<TransportError> for ActionError {
    fn from(err: TransportError) -> Self {
        match err {
            TransportError::Proto(ProtoError::Api { code, .. }) if code == "agent_blocked" => {
                Self::AgentBlocked
            }
            TransportError::Proto(ProtoError::Api { code, message }) => {
                Self::Rejected { code, message }
            }
            TransportError::Proto(ProtoError::Rpc { kind, .. }) if kind == "blocked" => {
                Self::AgentBlocked
            }
            TransportError::Proto(ProtoError::Rpc { kind, message }) => Self::Rejected {
                code: kind,
                message,
            },
            other => Self::Transport(other),
        }
    }
}

/// [`ActionError::Unsupported`] for a herdr-core space, tab or pane.
fn herdr_only(id: &str) -> Result<(), ActionError> {
    if crate::hc::is_hc(id) {
        return Err(ActionError::Unsupported(crate::hc::NOT_AVAILABLE.into()));
    }
    Ok(())
}

/// Sends a prompt to the agent in a pane, followed by Enter. Returns once
/// herdr has written it; whether the agent starts a turn shows up in its
/// status. herdr-core pastes it once nobody has typed for about 3 s, also
/// into a waiting dialog.
pub async fn send_prompt(conn: &Connection, pane_id: &str, text: &str) -> Result<(), ActionError> {
    if let Some(address) = crate::hc::address(pane_id) {
        conn.hc_request(
            "terminal.send",
            json!({ "terminal": address, "text": text, "force": true }),
        )
        .await?;
        return Ok(());
    }
    conn.request("agent.prompt", json!({ "target": pane_id, "text": text }))
        .await?;
    Ok(())
}

/// Sends logical keys to a pane, e.g. `["enter"]` to accept a dialog.
pub async fn send_keys(
    conn: &Connection,
    pane_id: &str,
    keys: &[String],
) -> Result<(), ActionError> {
    if let Some(address) = crate::hc::address(pane_id) {
        conn.hc_request(
            "terminal.keys",
            json!({ "terminal": address, "keys": keys }),
        )
        .await?;
        return Ok(());
    }
    conn.request(
        "pane.send_keys",
        json!({ "pane_id": pane_id, "keys": keys }),
    )
    .await?;
    Ok(())
}

/// Types text into a pane without pressing Enter.
pub async fn send_text(conn: &Connection, pane_id: &str, text: &str) -> Result<(), ActionError> {
    herdr_only(pane_id)?;
    conn.request(
        "pane.send_text",
        json!({ "pane_id": pane_id, "text": text }),
    )
    .await?;
    Ok(())
}

/// Where a new space or tab starts: its first pane.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Created {
    pub workspace_id: String,
    pub tab_id: String,
    pub pane_id: String,
}

#[derive(serde::Deserialize)]
struct CreatedReply {
    root_pane: PaneInfo,
}

impl From<CreatedReply> for Created {
    fn from(reply: CreatedReply) -> Self {
        Self {
            workspace_id: reply.root_pane.workspace_id,
            tab_id: reply.root_pane.tab_id,
            pane_id: reply.root_pane.pane_id,
        }
    }
}

/// Creates a space with a shell in `cwd`. Pass an absolute path: herdr does
/// not expand `~`, falls back to the home directory for paths that do not
/// exist and to its own working directory when `cwd` is missing. The
/// space is not focused, so a desktop client keeps its view.
pub async fn create_workspace(
    conn: &Connection,
    label: Option<&str>,
    cwd: &str,
) -> Result<Created, ActionError> {
    let mut params = json!({ "cwd": cwd, "focus": false });
    if let Some(label) = label.filter(|label| !label.trim().is_empty()) {
        params["label"] = json!(label.trim());
    }
    let reply: CreatedReply =
        serde_json::from_value(conn.request("workspace.create", params).await?).map_err(|err| {
            ActionError::Rejected {
                code: "malformed_reply".into(),
                message: err.to_string(),
            }
        })?;
    Ok(reply.into())
}

/// Creates a tab in a space, unfocused. Without `cwd` herdr picks the
/// directory itself.
pub async fn create_tab(
    conn: &Connection,
    workspace_id: &str,
    cwd: Option<&str>,
) -> Result<Created, ActionError> {
    herdr_only(workspace_id)?;
    let mut params = json!({ "workspace_id": workspace_id, "focus": false });
    if let Some(cwd) = cwd {
        params["cwd"] = json!(cwd);
    }
    let reply: CreatedReply = serde_json::from_value(conn.request("tab.create", params).await?)
        .map_err(|err| ActionError::Rejected {
            code: "malformed_reply".into(),
            message: err.to_string(),
        })?;
    Ok(reply.into())
}

/// What [`create_worktree`] creates. Empty fields are left to herdr.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NewWorktree {
    /// New or existing branch; empty lets herdr generate one
    /// (`worktree/brave-river-0042`). An existing branch is checked out.
    pub branch: Option<String>,
    /// Where a new branch starts; empty means `HEAD`.
    pub base: Option<String>,
    /// Name of the new space; empty names it after the branch.
    pub label: Option<String>,
    /// Absolute checkout path; empty uses herdr's worktree directory
    /// (`~/.herdr/worktrees/<repo>/<branch>` unless configured).
    pub path: Option<String>,
}

/// Creates a Git worktree from the repository of space `workspace_id` and
/// opens it as a new, unfocused space, like herdr's own "new worktree".
/// herdr answers once `git worktree add` is done, which can take a moment
/// in a big repository. The source must be the repository's main
/// checkout; herdr refuses a linked worktree as source.
pub async fn create_worktree(
    conn: &Connection,
    workspace_id: &str,
    new: &NewWorktree,
) -> Result<Created, ActionError> {
    herdr_only(workspace_id)?;
    let mut params = json!({ "workspace_id": workspace_id, "focus": false });
    for (key, value) in [
        ("branch", &new.branch),
        ("base", &new.base),
        ("label", &new.label),
        ("path", &new.path),
    ] {
        if let Some(value) = value.as_deref().map(str::trim).filter(|v| !v.is_empty()) {
            params[key] = json!(value);
        }
    }
    let reply: CreatedReply =
        serde_json::from_value(conn.request("worktree.create", params).await?).map_err(|err| {
            ActionError::Rejected {
                code: "malformed_reply".into(),
                message: err.to_string(),
            }
        })?;
    Ok(reply.into())
}

/// Agent kinds herdr can start, for servers that cannot list them. The
/// usual ones come first; herdr 0.9 knows these.
pub const AGENT_KINDS: &[&str] = &[
    "claude",
    "codex",
    "opencode",
    "gemini",
    "pi",
    "cursor",
    "copilot",
    "amp",
    "droid",
    "devin",
    "agy",
    "cline",
    "omp",
    "mastracode",
    "kimi",
    "kiro",
    "grok",
    "hermes",
    "kilo",
    "qodercli",
    "qwen",
    "letta",
    "maki",
    "muse",
];

/// Shown first in a picker, in this order, when the server knows them.
pub(crate) const COMMON_KINDS: &[&str] = &["claude", "codex", "opencode", "gemini", "pi"];

/// The agent kinds this server can start. herdr has no list of installed
/// agents; `server.agent_manifests` names every agent it can detect, which
/// is the set `agent.start` accepts. Falls back to [`AGENT_KINDS`] when the
/// server does not answer it.
pub async fn agent_kinds(conn: &Connection) -> Vec<String> {
    #[derive(serde::Deserialize)]
    struct Manifest {
        agent: String,
    }
    #[derive(serde::Deserialize)]
    struct Reply {
        manifests: Vec<Manifest>,
    }
    let listed = conn
        .request("server.agent_manifests", json!({}))
        .await
        .ok()
        .and_then(|value| serde_json::from_value::<Reply>(value).ok())
        .map(|reply| reply.manifests.into_iter().map(|m| m.agent).collect());
    match listed {
        Some(kinds) => common_first(kinds),
        None => AGENT_KINDS.iter().map(|kind| (*kind).to_string()).collect(),
    }
}

fn common_first(mut kinds: Vec<String>) -> Vec<String> {
    kinds.dedup();
    let rank = |kind: &String| {
        COMMON_KINDS
            .iter()
            .position(|common| common == kind)
            .unwrap_or(COMMON_KINDS.len())
    };
    // Stable: the rest keeps the server's order.
    kinds.sort_by_key(rank);
    kinds
}

/// An agent that herdr is launching. herdr answers before the agent is up;
/// its state then arrives through the usual events.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StartedAgent {
    /// The name herdr knows the agent by, unique on the server.
    pub name: String,
    pub pane_id: String,
}

/// How often [`start_agent`] tries the next free name.
const NAME_ATTEMPTS: u32 = 20;

/// A new pane is not ready the moment herdr creates it: while the shell
/// runs its startup files or a prompt hook (e.g. `git status`), herdr sees
/// a foreground child and calls the pane busy. [`start_agent`] retries for
/// about five seconds before it gives up.
const BUSY_RETRIES: u32 = 12;
const BUSY_PAUSE: std::time::Duration = std::time::Duration::from_millis(400);

/// Starts an agent of `kind` (e.g. `claude`) in a pane that sits at its
/// shell prompt, such as the first pane of a new space or tab. herdr types
/// the agent's command into that shell, so the agent runs with the shell's
/// directory and environment.
///
/// Agent names must be unique on the server. Without `name` the agent is
/// named after its kind; a taken name gets a number (`claude-2`), so a
/// second agent of the same kind needs no input. A pane that is still
/// starting its shell gets a few seconds to reach the prompt. `args` go
/// after the agent's command, e.g. `--resume <id>` (#304).
pub async fn start_agent(
    conn: &Connection,
    pane_id: &str,
    kind: &str,
    name: Option<&str>,
    args: &[String],
) -> Result<StartedAgent, ActionError> {
    herdr_only(pane_id)?;
    let base = agent_name(name.filter(|name| !name.trim().is_empty()).unwrap_or(kind));
    let mut attempt = 1;
    let mut busy = 0;
    loop {
        let name = numbered_name(&base, attempt);
        let mut params = json!({ "name": name, "kind": kind, "pane_id": pane_id });
        if !args.is_empty() {
            params["args"] = json!(args);
        }
        match conn.request("agent.start", params).await {
            Ok(_) => {
                return Ok(StartedAgent {
                    name,
                    pane_id: pane_id.to_string(),
                });
            }
            Err(TransportError::Proto(ProtoError::Api { code, .. }))
                if code == "agent_name_taken" && attempt < NAME_ATTEMPTS =>
            {
                attempt += 1;
            }
            Err(TransportError::Proto(ProtoError::Api { code, .. }))
                if code == "agent_pane_busy" && busy < BUSY_RETRIES =>
            {
                busy += 1;
                tokio::time::sleep(BUSY_PAUSE).await;
            }
            Err(err) => return Err(err.into()),
        }
    }
}

/// How an agent from [`start_agent`] came up (#339).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentStart {
    /// herdr reports the agent ready for input, or it is still launching
    /// after [`START_DEADLINE`]: nothing to report.
    Ready,
    /// herdr no longer knows the agent before it was ready: it exited, or
    /// herdr released it at its 30 s launch timeout (a missing command, or
    /// an agent that never reported ready). Its shell stays open with the
    /// output.
    Gone,
}

/// How often [`await_agent_start`] asks herdr.
const START_POLL: std::time::Duration = std::time::Duration::from_millis(500);
/// herdr gives up on a launch after 30 s and then releases the agent; a
/// little longer here, so that release is still seen.
const START_DEADLINE: std::time::Duration = std::time::Duration::from_secs(35);

/// Waits until the agent just started in `pane_id` is ready or gone. herdr
/// answers `agent.start` before the agent runs and reports no exit code: an
/// agent that exits at once (bad arguments) is released within a second, a
/// missing command only at herdr's launch timeout. Read only.
pub async fn await_agent_start(
    conn: &Connection,
    pane_id: &str,
) -> Result<AgentStart, ActionError> {
    await_start(conn, pane_id, START_POLL, START_DEADLINE).await
}

async fn await_start(
    conn: &Connection,
    pane_id: &str,
    poll: std::time::Duration,
    deadline: std::time::Duration,
) -> Result<AgentStart, ActionError> {
    let until = tokio::time::Instant::now() + deadline;
    loop {
        let reply = conn
            .request("agent.get", json!({ "target": pane_id }))
            .await;
        if let Some(start) = start_state(reply)? {
            return Ok(start);
        }
        if tokio::time::Instant::now() + poll > until {
            return Ok(AgentStart::Ready);
        }
        tokio::time::sleep(poll).await;
    }
}

/// Reads one `agent.get` answer: ready, gone, or still launching (`None`).
fn start_state(
    reply: Result<serde_json::Value, TransportError>,
) -> Result<Option<AgentStart>, ActionError> {
    match reply {
        Ok(value) if value["agent"]["interactive_ready"].as_bool() == Some(true) => {
            Ok(Some(AgentStart::Ready))
        }
        Ok(_) => Ok(None),
        Err(TransportError::Proto(ProtoError::Api { code, .. })) if code == "agent_not_found" => {
            Ok(Some(AgentStart::Gone))
        }
        Err(err) => Err(err.into()),
    }
}

/// herdr's rule for agent names: `[a-z][a-z0-9_-]{0,31}`. Anything else is
/// turned into that shape instead of being refused.
fn agent_name(raw: &str) -> String {
    let mapped: String = raw
        .trim()
        .to_lowercase()
        .chars()
        .map(|ch| {
            if ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_' {
                ch
            } else {
                '-'
            }
        })
        .collect();
    let trimmed = mapped.trim_start_matches(|ch: char| !ch.is_ascii_lowercase());
    let mut name: String = trimmed.chars().take(28).collect();
    while name.ends_with('-') {
        name.pop();
    }
    if name.is_empty() {
        "agent".into()
    } else {
        name
    }
}

/// `base` for the first attempt, then `base-2`, `base-3`, ... (at most 32
/// characters, as `agent_name` keeps the base at 28).
fn numbered_name(base: &str, attempt: u32) -> String {
    if attempt == 1 {
        base.to_string()
    } else {
        format!("{base}-{attempt}")
    }
}

/// Renames a space. herdr answers with `workspace_renamed`, which the sync
/// applies in place.
pub async fn rename_workspace(
    conn: &Connection,
    workspace_id: &str,
    label: &str,
) -> Result<(), ActionError> {
    herdr_only(workspace_id)?;
    let label = non_empty(label)?;
    conn.request(
        "workspace.rename",
        json!({ "workspace_id": workspace_id, "label": label }),
    )
    .await?;
    Ok(())
}

/// Renames a tab; announced with `tab_renamed`.
pub async fn rename_tab(conn: &Connection, tab_id: &str, label: &str) -> Result<(), ActionError> {
    herdr_only(tab_id)?;
    let label = non_empty(label)?;
    conn.request("tab.rename", json!({ "tab_id": tab_id, "label": label }))
        .await?;
    Ok(())
}

/// Closes a tab with its panes, ending what runs in them; announced with
/// `tab_closed`. herdr closes the space too when it was its last tab.
pub async fn close_tab(conn: &Connection, tab_id: &str) -> Result<(), ActionError> {
    herdr_only(tab_id)?;
    conn.request("tab.close", json!({ "tab_id": tab_id }))
        .await?;
    Ok(())
}

/// Closes a space with all its tabs; announced with `workspace_closed`.
/// herdr refuses a repository's space that has linked worktree spaces
/// (`workspace_group_close_required`) unless `with_worktrees` closes them
/// too.
pub async fn close_workspace(
    conn: &Connection,
    workspace_id: &str,
    with_worktrees: bool,
) -> Result<(), ActionError> {
    herdr_only(workspace_id)?;
    conn.request(
        "workspace.close",
        json!({ "workspace_id": workspace_id, "close_group": with_worktrees }),
    )
    .await?;
    Ok(())
}

/// Gives the agent in a pane a name, or removes it with `None` (or an empty
/// name). herdr allows lowercase letters, digits, `-` and `_`, starting with
/// a letter, at most 32 characters, unique among agents; it refuses others
/// with `invalid_agent_name`. The name only shows up in the next snapshot,
/// see [`crate::sync::SyncState::request_snapshot`].
pub async fn rename_agent(
    conn: &Connection,
    pane_id: &str,
    name: Option<&str>,
) -> Result<(), ActionError> {
    herdr_only(pane_id)?;
    let name = name.map(str::trim).filter(|name| !name.is_empty());
    conn.request("agent.rename", json!({ "target": pane_id, "name": name }))
        .await?;
    Ok(())
}

/// herdr takes an empty label as a name, which leaves an empty row. Refuse
/// it here instead.
fn non_empty(label: &str) -> Result<&str, ActionError> {
    let label = label.trim();
    if label.is_empty() {
        return Err(ActionError::Rejected {
            code: "empty_label".into(),
            message: "the name must not be empty".into(),
        });
    }
    Ok(label)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_names_follow_herdrs_rule() {
        assert_eq!(agent_name("claude"), "claude");
        assert_eq!(agent_name("  Kino App! "), "kino-app");
        assert_eq!(agent_name("2nd try"), "nd-try");
        assert_eq!(agent_name("über"), "ber");
        assert_eq!(agent_name("---"), "agent");
        assert_eq!(agent_name(""), "agent");
        let long = agent_name(&"a".repeat(50));
        assert_eq!(long.len(), 28);
        assert_eq!(numbered_name(&long, 20).len(), 31);
        assert_eq!(numbered_name("claude", 1), "claude");
        assert_eq!(numbered_name("claude", 3), "claude-3");
    }

    #[test]
    fn worktree_reply_names_the_first_pane() -> Result<(), serde_json::Error> {
        let reply: CreatedReply = serde_json::from_value(serde_json::json!({
            "type": "worktree_created",
            "workspace": {"workspace_id": "w3", "number": 3, "label": "feature-x"},
            "tab": {"tab_id": "w3:t1", "workspace_id": "w3"},
            "root_pane": {"pane_id": "w3:p1", "workspace_id": "w3", "tab_id": "w3:t1",
                          "terminal_id": "t", "focused": false, "agent_status": "unknown", "revision": 0},
            "worktree": {"path": "/x/repo/feature-x", "branch": "feature/x", "label": "feature-x",
                         "is_bare": false, "is_detached": false, "is_prunable": false, "is_linked_worktree": true}
        }))?;
        assert_eq!(Created::from(reply).pane_id, "w3:p1");
        Ok(())
    }

    #[test]
    fn common_kinds_come_first() {
        let kinds = ["pi", "claude", "cursor", "codex", "amp"].map(String::from);
        assert_eq!(
            common_first(kinds.to_vec()),
            ["claude", "codex", "pi", "cursor", "amp"].map(String::from)
        );
    }

    fn api(code: &str) -> TransportError {
        TransportError::Proto(ProtoError::Api {
            code: code.into(),
            message: "msg".into(),
        })
    }

    #[test]
    fn blocked_agent_gets_its_own_error() {
        assert!(matches!(
            ActionError::from(api("agent_blocked")),
            ActionError::AgentBlocked
        ));
        assert!(matches!(
            ActionError::from(api("invalid_key")),
            ActionError::Rejected { code, .. } if code == "invalid_key"
        ));
        assert!(matches!(
            ActionError::from(TransportError::Closed),
            ActionError::Transport(TransportError::Closed)
        ));
    }

    #[test]
    fn herdr_core_errors_and_limits() {
        let rpc = |kind: &str| {
            TransportError::Proto(ProtoError::Rpc {
                kind: kind.into(),
                message: "msg".into(),
            })
        };
        assert!(matches!(
            ActionError::from(rpc("blocked")),
            ActionError::AgentBlocked
        ));
        assert!(matches!(
            ActionError::from(rpc("not_found")),
            ActionError::Rejected { code, .. } if code == "not_found"
        ));
        assert!(matches!(
            herdr_only("hc:t1"),
            Err(ActionError::Unsupported(message)) if message == crate::hc::NOT_AVAILABLE
        ));
        assert!(herdr_only("w1:t1").is_ok());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn herdr_core_tabs_and_spaces_are_refused_before_any_call() {
        // A connection that would fail if anything were sent.
        let conn = Connection::local("/nonexistent/herdr.sock");
        let unsupported =
            |result: Result<(), ActionError>| matches!(result, Err(ActionError::Unsupported(_)));
        assert!(unsupported(send_text(&conn, "hc:t1", "x").await));
        assert!(unsupported(rename_tab(&conn, "hc:tb1", "x").await));
        assert!(unsupported(rename_workspace(&conn, "hc:sp1", "x").await));
        assert!(unsupported(close_tab(&conn, "hc:tb1").await));
        assert!(unsupported(close_workspace(&conn, "hc:sp1", false).await));
        assert!(unsupported(rename_agent(&conn, "hc:t1", None).await));
        assert!(matches!(
            create_tab(&conn, "hc:sp1", None).await,
            Err(ActionError::Unsupported(_))
        ));
        assert!(matches!(
            create_worktree(&conn, "hc:sp1", &NewWorktree::default()).await,
            Err(ActionError::Unsupported(_))
        ));
        assert!(matches!(
            start_agent(&conn, "hc:t1", "claude", None, &[]).await,
            Err(ActionError::Unsupported(_))
        ));
    }

    #[test]
    fn start_answers_are_read() {
        let ready = Ok(serde_json::json!({"type": "agent_info",
            "agent": {"pane_id": "w1:p1", "interactive_ready": true}}));
        assert!(matches!(start_state(ready), Ok(Some(AgentStart::Ready))));
        let pending = Ok(serde_json::json!({"type": "agent_info",
            "agent": {"pane_id": "w1:p1", "launch_pending": true, "interactive_ready": false}}));
        assert!(matches!(start_state(pending), Ok(None)));
        assert!(matches!(
            start_state(Err(api("agent_not_found"))),
            Ok(Some(AgentStart::Gone))
        ));
        assert!(matches!(
            start_state(Err(api("pane_not_found"))),
            Err(ActionError::Rejected { code, .. }) if code == "pane_not_found"
        ));
    }

    // A herdr stand-in that answers `agent.get` from a script, one answer
    // per request; the last answer repeats.
    #[cfg(unix)]
    mod start_watch {
        use super::super::*;
        use std::path::PathBuf;
        use std::sync::{Arc, Mutex};
        use std::time::Duration;
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
        use tokio::net::UnixListener;

        fn fake_herdr(name: &str, answers: Vec<serde_json::Value>) -> (PathBuf, Arc<Mutex<usize>>) {
            let path = std::env::temp_dir()
                .join(format!("herdr-start-{name}-{}.sock", std::process::id()));
            let _ = std::fs::remove_file(&path);
            let listener = UnixListener::bind(&path).expect("bind fake socket");
            let asked = Arc::new(Mutex::new(0));
            let count = Arc::clone(&asked);
            tokio::spawn(async move {
                while let Ok((stream, _)) = listener.accept().await {
                    let (read, mut write) = stream.into_split();
                    let mut line = String::new();
                    if BufReader::new(read).read_line(&mut line).await.is_err() {
                        continue;
                    }
                    let request: serde_json::Value = serde_json::from_str(&line).expect("json");
                    assert_eq!(request["method"], "agent.get");
                    let index = {
                        let mut count = count.lock().expect("lock");
                        *count += 1;
                        (*count - 1).min(answers.len() - 1)
                    };
                    let mut reply = answers[index].clone();
                    reply["id"] = request["id"].clone();
                    let _ = write.write_all(format!("{reply}\n").as_bytes()).await;
                }
            });
            (path, asked)
        }

        fn pending() -> serde_json::Value {
            json!({"result": {"type": "agent_info", "agent": {
                "pane_id": "w1:p1", "launch_pending": true, "interactive_ready": false}}})
        }

        const POLL: Duration = Duration::from_millis(10);

        #[tokio::test]
        async fn an_agent_that_exits_is_gone() {
            let gone = json!({"error": {"code": "agent_not_found", "message": "gone"}});
            let (path, asked) = fake_herdr("gone", vec![pending(), pending(), gone]);
            let conn = Connection::local(&path);
            let start = await_start(&conn, "w1:p1", POLL, Duration::from_secs(5)).await;
            assert!(matches!(start, Ok(AgentStart::Gone)), "{start:?}");
            assert_eq!(*asked.lock().expect("lock"), 3);
            let _ = std::fs::remove_file(&path);
        }

        #[tokio::test]
        async fn a_ready_agent_is_ready() {
            let ready = json!({"result": {"type": "agent_info", "agent": {
                "pane_id": "w1:p1", "interactive_ready": true}}});
            let (path, _) = fake_herdr("ready", vec![pending(), ready]);
            let conn = Connection::local(&path);
            let start = await_start(&conn, "w1:p1", POLL, Duration::from_secs(5)).await;
            assert!(matches!(start, Ok(AgentStart::Ready)), "{start:?}");
            let _ = std::fs::remove_file(&path);
        }

        #[tokio::test]
        async fn a_launch_that_never_ends_reports_nothing() {
            let (path, asked) = fake_herdr("pending", vec![pending()]);
            let conn = Connection::local(&path);
            let start = await_start(&conn, "w1:p1", POLL, Duration::from_millis(100)).await;
            assert!(matches!(start, Ok(AgentStart::Ready)), "{start:?}");
            assert!(*asked.lock().expect("lock") >= 2);
            let _ = std::fs::remove_file(&path);
        }

        #[tokio::test]
        async fn other_errors_are_returned() {
            let refused = json!({"error": {"code": "pane_not_found", "message": "no pane"}});
            let (path, _) = fake_herdr("refused", vec![refused]);
            let conn = Connection::local(&path);
            let start = await_start(&conn, "w1:p1", POLL, Duration::from_secs(5)).await;
            assert!(
                matches!(&start, Err(ActionError::Rejected { code, .. }) if code == "pane_not_found"),
                "{start:?}"
            );
            let _ = std::fs::remove_file(&path);
        }
    }

    #[test]
    fn empty_labels_are_refused() {
        assert!(matches!(
            non_empty("  "),
            Err(ActionError::Rejected { code, .. }) if code == "empty_label"
        ));
        assert_eq!(non_empty(" api ").ok(), Some("api"));
    }

    #[test]
    fn create_reply_names_the_first_pane() -> Result<(), serde_json::Error> {
        let reply: CreatedReply = serde_json::from_value(serde_json::json!({
            "type": "tab_created",
            "tab": {"tab_id": "w2:t2", "workspace_id": "w2"},
            "root_pane": {"pane_id": "w2:p2", "workspace_id": "w2", "tab_id": "w2:t2",
                          "terminal_id": "t", "focused": true, "agent_status": "unknown", "revision": 0}
        }))?;
        assert_eq!(
            Created::from(reply),
            Created {
                workspace_id: "w2".into(),
                tab_id: "w2:t2".into(),
                pane_id: "w2:p2".into()
            }
        );
        Ok(())
    }
}
