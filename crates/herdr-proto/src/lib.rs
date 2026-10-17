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

#[derive(Debug, Deserialize)]
pub struct WorkspaceList {
    pub workspaces: Vec<Workspace>,
}

#[derive(Debug, Deserialize)]
pub struct Workspace {
    pub workspace_id: String,
    #[serde(default)]
    pub number: u32,
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default)]
    pub focused: bool,
    #[serde(default)]
    pub tab_count: u32,
    #[serde(default)]
    pub pane_count: u32,
    #[serde(default)]
    pub agent_status: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct PaneList {
    pub panes: Vec<Pane>,
}

#[derive(Debug, Deserialize)]
pub struct Pane {
    pub pane_id: String,
    pub workspace_id: String,
    pub tab_id: String,
    #[serde(default)]
    pub focused: bool,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub agent: Option<String>,
    #[serde(default)]
    pub display_agent: Option<String>,
    #[serde(default)]
    pub terminal_title_stripped: Option<String>,
    #[serde(default)]
    pub agent_status: Option<String>,
    #[serde(default)]
    pub revision: u64,
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
}
