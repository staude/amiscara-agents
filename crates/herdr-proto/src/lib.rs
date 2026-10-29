//! Wire types for the herdr socket API.
//!
//! The server speaks newline-delimited JSON: one request line in, one
//! response line out. Subscriptions keep the connection open and stream one
//! event per line after the initial acknowledgement.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Protocol generation this client was written against (`ping.protocol`).
pub const SUPPORTED_PROTOCOL: u32 = 22;

#[derive(Debug, Serialize)]
pub struct Request<'a> {
    pub id: &'a str,
    pub method: &'a str,
    pub params: Value,
}

impl Request<'_> {
    /// Serialises the request as a single protocol line, including `\n`.
    pub fn to_line(&self) -> Result<Vec<u8>, ProtoError> {
        let mut line = serde_json::to_vec(self)?;
        line.push(b'\n');
        Ok(line)
    }
}

#[derive(Debug, Deserialize)]
pub struct ApiError {
    pub code: String,
    pub message: String,
}

#[derive(Debug, thiserror::Error)]
pub enum ProtoError {
    #[error("herdr error {code}: {message}")]
    Api { code: String, message: String },
    #[error("malformed response: {0}")]
    Malformed(String),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Deserialize)]
struct RawResponse {
    #[serde(default)]
    result: Option<Value>,
    #[serde(default)]
    error: Option<ApiError>,
}

/// Parses a response line into its `result` payload.
pub fn parse_response(line: &str) -> Result<Value, ProtoError> {
    let raw: RawResponse = serde_json::from_str(line)?;
    match (raw.result, raw.error) {
        (_, Some(err)) => Err(ProtoError::Api {
            code: err.code,
            message: err.message,
        }),
        (Some(result), None) => Ok(result),
        (None, None) => Err(ProtoError::Malformed(line.to_owned())),
    }
}

#[derive(Debug, Deserialize)]
pub struct Pong {
    pub version: String,
    pub protocol: u32,
    #[serde(default)]
    pub capabilities: Value,
}

/// Agent state as herdr reports it. Values a newer server adds map to `Unknown`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentStatus {
    Idle,
    Working,
    Blocked,
    Done,
    #[default]
    #[serde(other)]
    Unknown,
}

impl AgentStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Working => "working",
            Self::Blocked => "blocked",
            Self::Done => "done",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct WorkspaceList {
    pub workspaces: Vec<WorkspaceInfo>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct WorkspaceInfo {
    pub workspace_id: String,
    #[serde(default)]
    pub number: u32,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub focused: bool,
    #[serde(default)]
    pub tab_count: u32,
    #[serde(default)]
    pub pane_count: u32,
    #[serde(default)]
    pub active_tab_id: String,
    #[serde(default)]
    pub agent_status: AgentStatus,
    #[serde(default)]
    pub worktree: Option<WorktreeInfo>,
    /// Custom values set via `workspace.report_metadata` (plugins, agents);
    /// herdr's sidebar can show them as extra rows under the space.
    #[serde(default)]
    pub tokens: BTreeMap<String, String>,
}

/// `worktree.list` result: the worktrees of the space's repository.
#[derive(Debug, Deserialize)]
pub struct WorktreeListResult {
    #[serde(default)]
    pub worktrees: Vec<WorktreeEntry>,
}

#[derive(Debug, Deserialize)]
pub struct WorktreeEntry {
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub branch: Option<String>,
    /// The space showing this worktree, if one is open.
    #[serde(default)]
    pub open_workspace_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct WorktreeInfo {
    /// Same for every worktree of one repository (its `.git` path).
    #[serde(default)]
    pub repo_key: String,
    pub repo_name: String,
    pub checkout_path: String,
    #[serde(default)]
    pub is_linked_worktree: bool,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct TabInfo {
    pub tab_id: String,
    pub workspace_id: String,
    #[serde(default)]
    pub number: u32,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub focused: bool,
    #[serde(default)]
    pub pane_count: u32,
    #[serde(default)]
    pub agent_status: AgentStatus,
}

#[derive(Debug, Deserialize)]
pub struct PaneList {
    pub panes: Vec<PaneInfo>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct PaneInfo {
    pub pane_id: String,
    pub workspace_id: String,
    pub tab_id: String,
    #[serde(default)]
    pub focused: bool,
    #[serde(default)]
    pub cwd: Option<String>,
    /// Directory of the foreground process, e.g. after `cd` in the shell.
    #[serde(default)]
    pub foreground_cwd: Option<String>,
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub agent: Option<String>,
    #[serde(default)]
    pub display_agent: Option<String>,
    #[serde(default)]
    pub terminal_title_stripped: Option<String>,
    #[serde(default)]
    pub agent_status: AgentStatus,
    #[serde(default)]
    pub revision: u64,
    /// Custom values set via `pane.report_metadata`, merged per source;
    /// herdr cuts each value to 80 characters. The host's browser stand-in
    /// reports opened URLs here (`open_id`, `open_url_0`, ...).
    #[serde(default)]
    pub tokens: BTreeMap<String, String>,
}

/// `pane.get` result.
#[derive(Debug, Deserialize)]
pub struct PaneGetResult {
    pub pane: PaneInfo,
}

/// `session.snapshot` result: the whole server state in one answer.
#[derive(Debug, Deserialize)]
pub struct SnapshotResult {
    pub snapshot: SessionSnapshot,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SessionSnapshot {
    pub version: String,
    pub protocol: u32,
    #[serde(default)]
    pub focused_workspace_id: Option<String>,
    #[serde(default)]
    pub focused_tab_id: Option<String>,
    #[serde(default)]
    pub focused_pane_id: Option<String>,
    pub workspaces: Vec<WorkspaceInfo>,
    pub tabs: Vec<TabInfo>,
    pub panes: Vec<PaneInfo>,
    /// One entry per tab: where herdr draws each pane.
    #[serde(default)]
    pub layouts: Vec<TabLayout>,
    /// Agent panes with their custom names. Older servers leave it out.
    #[serde(default)]
    pub agents: Vec<AgentInfo>,
}

/// An agent as `agent.list`, `agent.get` and the snapshot report it. The
/// name is not part of [`PaneInfo`], and `agent.rename` announces itself
/// with a `pane_updated` that does not carry it either.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct AgentInfo {
    pub pane_id: String,
    /// Set with `agent.rename`; `None` when the agent has no custom name.
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub agent_status: AgentStatus,
    /// Counts the agent's state changes; chains (#300) claim one change by
    /// it.
    #[serde(default)]
    pub state_change_seq: u64,
    /// Equals `state_change_seq` when the current `done` or `idle` ended a
    /// turn of work. herdr 0.9.5 sets it after an Esc as well.
    #[serde(default)]
    pub completion_seq: Option<u64>,
}

/// `agent.get` result.
#[derive(Debug, Deserialize)]
pub struct AgentGetResult {
    pub agent: AgentInfo,
}

/// How herdr arranges the panes of one tab, in terminal cells. Each pane has
/// its rectangle inside `area`; `splits` describes the tree behind it. A
/// zoomed tab keeps the split rectangles, herdr just draws the focused pane
/// over the whole area.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct TabLayout {
    pub workspace_id: String,
    pub tab_id: String,
    #[serde(default)]
    pub zoomed: bool,
    pub area: CellRect,
    #[serde(default)]
    pub focused_pane_id: String,
    pub panes: Vec<LayoutPane>,
    #[serde(default)]
    pub splits: Vec<LayoutSplit>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
pub struct CellRect {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct LayoutPane {
    pub pane_id: String,
    #[serde(default)]
    pub focused: bool,
    pub rect: CellRect,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct LayoutSplit {
    #[serde(default)]
    pub id: String,
    pub direction: SplitDirection,
    #[serde(default)]
    pub ratio: f32,
    pub rect: CellRect,
}

/// `right`: side by side, `down`: one above the other.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SplitDirection {
    Right,
    Down,
    #[serde(other)]
    Unknown,
}

/// One event from `events.subscribe`. Global subscriptions send
/// `{"event":"pane_created","data":{"type":"pane_created",...}}`, per-pane
/// subscriptions send `{"event":"pane.agent_status_changed","data":{...}}`
/// without a `type`. [`parse_event`] folds both into this enum. Only the
/// fields the client uses are decoded.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    WorkspaceCreated {
        workspace: WorkspaceInfo,
    },
    WorkspaceUpdated {
        workspace: WorkspaceInfo,
    },
    WorkspaceMetadataUpdated {
        workspace: WorkspaceInfo,
    },
    WorkspaceClosed {
        workspace_id: String,
    },
    WorkspaceRenamed {
        workspace_id: String,
        label: String,
    },
    WorkspaceMoved {
        workspace_id: String,
    },
    WorkspaceReordered {},
    WorkspaceFocused {
        workspace_id: String,
    },
    WorktreeCreated {},
    WorktreeOpened {},
    WorktreeRemoved {},
    TabCreated {
        tab: TabInfo,
    },
    TabClosed {
        workspace_id: String,
        tab_id: String,
    },
    TabRenamed {
        workspace_id: String,
        tab_id: String,
        label: String,
    },
    TabMoved {
        workspace_id: String,
        tab_id: String,
    },
    TabFocused {
        workspace_id: String,
        tab_id: String,
    },
    PaneCreated {
        pane: PaneInfo,
    },
    PaneClosed {
        workspace_id: String,
        pane_id: String,
    },
    PaneUpdated {
        pane: PaneInfo,
    },
    PaneFocused {
        workspace_id: String,
        pane_id: String,
    },
    PaneMoved {
        previous_pane_id: String,
        pane: PaneInfo,
    },
    PaneOutputChanged {
        pane_id: String,
        revision: u64,
    },
    PaneExited {
        pane_id: String,
    },
    PaneAgentDetected {
        pane_id: String,
        #[serde(default)]
        agent: Option<String>,
    },
    PaneAgentStatusChanged {
        pane_id: String,
        agent_status: AgentStatus,
        #[serde(default)]
        agent: Option<String>,
        #[serde(default)]
        display_agent: Option<String>,
        #[serde(default)]
        title: Option<String>,
    },
    /// Sent on splits, resizes, zoom and swaps. Older or unexpected payloads
    /// leave `layout` empty and the client falls back to a snapshot.
    LayoutUpdated {
        #[serde(default, deserialize_with = "lenient")]
        layout: Option<TabLayout>,
    },
    /// An event type this client does not know yet.
    #[serde(other)]
    Unknown,
}

/// `None` instead of an error for a payload that does not parse, so one odd
/// field cannot end the event stream.
fn lenient<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::de::DeserializeOwned,
{
    let value = Value::deserialize(deserializer)?;
    Ok(serde_json::from_value(value).ok())
}

/// Parses one line of an event stream. An error line (for example
/// `events_lost`) ends the subscription and comes back as `Err`.
pub fn parse_event(mut value: Value) -> Result<Event, ProtoError> {
    if let Some(err) = value.get("error") {
        let err: ApiError = serde_json::from_value(err.clone())?;
        return Err(ProtoError::Api {
            code: err.code,
            message: err.message,
        });
    }
    let name = value
        .get("event")
        .and_then(Value::as_str)
        .ok_or_else(|| ProtoError::Malformed(value.to_string()))?
        .replace('.', "_");
    let mut data = value
        .get_mut("data")
        .map(Value::take)
        .ok_or_else(|| ProtoError::Malformed(value.to_string()))?;
    let Some(fields) = data.as_object_mut() else {
        return Err(ProtoError::Malformed(value.to_string()));
    };
    fields.entry("type").or_insert_with(|| Value::String(name));
    Ok(serde_json::from_value(data)?)
}

/// `pane.read` result: the screen sits in a nested `read` object.
#[derive(Debug, Deserialize)]
pub struct PaneReadResult {
    pub read: PaneRead,
}

#[derive(Debug, Deserialize)]
pub struct PaneRead {
    pub pane_id: String,
    #[serde(default)]
    pub revision: u64,
    pub text: String,
    #[serde(default)]
    pub truncated: bool,
}

/// Global event types that can be subscribed without a `pane_id`.
/// `pane.agent_status_changed`, `pane.output_matched` and `pane.scroll_changed`
/// are per-pane subscriptions and need one entry per pane.
pub const GLOBAL_SUBSCRIPTIONS: &[&str] = &[
    "workspace.created",
    "workspace.updated",
    "workspace.metadata_updated",
    "workspace.renamed",
    "workspace.moved",
    "workspace.reordered",
    "workspace.closed",
    "workspace.focused",
    "worktree.created",
    "worktree.opened",
    "worktree.removed",
    "tab.created",
    "tab.closed",
    "tab.focused",
    "tab.renamed",
    "tab.moved",
    "pane.created",
    "pane.closed",
    "pane.updated",
    "pane.focused",
    "pane.moved",
    "pane.exited",
    "pane.agent_detected",
    "layout.updated",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_result() -> Result<(), ProtoError> {
        let line = r#"{"id":"1","result":{"type":"pong","version":"0.9.4","protocol":22}}"#;
        let pong: Pong = serde_json::from_value(parse_response(line)?)?;
        assert_eq!(pong.protocol, 22);
        assert_eq!(pong.version, "0.9.4");
        Ok(())
    }

    #[test]
    fn parses_error() {
        let line = r#"{"id":"s","error":{"code":"invalid_request","message":"missing field"}}"#;
        assert!(matches!(
            parse_response(line),
            Err(ProtoError::Api { code, .. }) if code == "invalid_request"
        ));
    }

    #[test]
    fn request_is_one_line() -> Result<(), ProtoError> {
        let req = Request {
            id: "1",
            method: "ping",
            params: serde_json::json!({}),
        };
        let line = req.to_line()?;
        assert_eq!(line.iter().filter(|b| **b == b'\n').count(), 1);
        assert_eq!(line.last(), Some(&b'\n'));
        Ok(())
    }

    #[test]
    fn parses_global_event() -> Result<(), ProtoError> {
        let line = serde_json::json!({
            "event": "pane_updated",
            "data": {"type": "pane_updated", "pane": {
                "pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
                "terminal_id": "t", "focused": true, "agent_status": "blocked", "revision": 7
            }}
        });
        match parse_event(line)? {
            Event::PaneUpdated { pane } => {
                assert_eq!(pane.agent_status, AgentStatus::Blocked);
                assert_eq!(pane.revision, 7);
            }
            other => panic!("unexpected {other:?}"),
        }
        Ok(())
    }

    #[test]
    fn parses_per_pane_event_without_type() -> Result<(), ProtoError> {
        let line = serde_json::json!({
            "event": "pane.agent_status_changed",
            "data": {"pane_id": "w1:p1", "workspace_id": "w1", "agent_status": "done",
                     "agent": "claude", "state_labels": {}}
        });
        assert!(matches!(
            parse_event(line)?,
            Event::PaneAgentStatusChanged {
                agent_status: AgentStatus::Done,
                ..
            }
        ));
        Ok(())
    }

    #[test]
    fn unknown_event_and_status_do_not_fail() -> Result<(), ProtoError> {
        let line = serde_json::json!({"event": "pane_sparkled", "data": {"type": "pane_sparkled"}});
        assert_eq!(parse_event(line)?, Event::Unknown);
        let status: AgentStatus = serde_json::from_value(serde_json::json!("pondering"))?;
        assert_eq!(status, AgentStatus::Unknown);
        Ok(())
    }

    #[test]
    fn parses_layout_event() -> Result<(), ProtoError> {
        let line = serde_json::json!({
            "event": "layout_updated",
            "data": {"type": "layout_updated", "layout": {
                "workspace_id": "w1", "tab_id": "w1:t1", "zoomed": false,
                "area": {"x": 0, "y": 0, "width": 120, "height": 40},
                "focused_pane_id": "w1:p1",
                "panes": [
                    {"pane_id": "w1:p1", "focused": true, "rect": {"x": 0, "y": 0, "width": 60, "height": 40}},
                    {"pane_id": "w1:p2", "focused": false, "rect": {"x": 60, "y": 0, "width": 60, "height": 40}}
                ],
                "splits": [{"id": "split_0_root", "direction": "right", "ratio": 0.5,
                            "rect": {"x": 0, "y": 0, "width": 120, "height": 40}}]
            }}
        });
        let Event::LayoutUpdated {
            layout: Some(layout),
        } = parse_event(line)?
        else {
            panic!("expected a layout");
        };
        assert_eq!(layout.panes.len(), 2);
        assert_eq!(layout.panes[1].rect.x, 60);
        assert_eq!(layout.splits[0].direction, SplitDirection::Right);
        // Without a usable payload the event still parses.
        for data in [
            serde_json::json!({"type": "layout_updated"}),
            serde_json::json!({"type": "layout_updated", "layout": {}}),
        ] {
            let line = serde_json::json!({"event": "layout_updated", "data": data});
            assert_eq!(parse_event(line)?, Event::LayoutUpdated { layout: None });
        }
        Ok(())
    }

    #[test]
    fn parses_agent_get() -> Result<(), ProtoError> {
        let line = r#"{"id":"1","result":{"type":"agent_info","agent":{"pane_id":"w1:p1","agent_status":"done","state_change_seq":10,"completion_seq":10,"revision":3}}}"#;
        let got: AgentGetResult = serde_json::from_value(parse_response(line)?)?;
        assert_eq!(got.agent.agent_status, AgentStatus::Done);
        assert_eq!(
            (got.agent.state_change_seq, got.agent.completion_seq),
            (10, Some(10))
        );
        let line = r#"{"id":"1","result":{"type":"agent_info","agent":{"pane_id":"w1:p1"}}}"#;
        let got: AgentGetResult = serde_json::from_value(parse_response(line)?)?;
        assert_eq!(
            (got.agent.state_change_seq, got.agent.completion_seq),
            (0, None)
        );
        Ok(())
    }

    #[test]
    fn stream_error_is_an_error() {
        let line =
            serde_json::json!({"id": "1", "error": {"code": "events_lost", "message": "gap"}});
        assert!(matches!(
            parse_event(line),
            Err(ProtoError::Api { code, .. }) if code == "events_lost"
        ));
    }
}
