//! Wire types for the herdr socket API.
//!
//! The server speaks newline-delimited JSON: one request line in, one
//! response line out. Subscriptions keep the connection open and stream one
//! event per line after the initial acknowledgement.

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
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct WorktreeInfo {
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
    LayoutUpdated {},
    /// An event type this client does not know yet.
    #[serde(other)]
    Unknown,
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
    fn stream_error_is_an_error() {
        let line =
            serde_json::json!({"id": "1", "error": {"code": "events_lost", "message": "gap"}});
        assert!(matches!(
            parse_event(line),
            Err(ProtoError::Api { code, .. }) if code == "events_lost"
        ));
    }
}
