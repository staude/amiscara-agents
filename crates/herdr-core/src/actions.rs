//! Writing calls: input for panes and agents, new spaces and tabs, renames.
//!
//! Keys use herdr's logical names: `enter`, `esc`, `tab`, `backspace`,
//! `up`, `down`, `left`, `right`, single characters such as `1`, and
//! combinations such as `ctrl+c`. herdr validates all keys before it writes
//! anything.

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
            other => Self::Transport(other),
        }
    }
}

/// Sends a prompt to the agent in a pane, followed by Enter. Returns once
/// herdr has written it; whether the agent starts a turn shows up in its
/// status.
pub async fn send_prompt(conn: &Connection, pane_id: &str, text: &str) -> Result<(), ActionError> {
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
    conn.request(
        "pane.send_keys",
        json!({ "pane_id": pane_id, "keys": keys }),
    )
    .await?;
    Ok(())
}

/// Types text into a pane without pressing Enter.
pub async fn send_text(conn: &Connection, pane_id: &str, text: &str) -> Result<(), ActionError> {
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

/// Renames a space. herdr answers with `workspace_renamed`, which the sync
/// applies in place.
pub async fn rename_workspace(
    conn: &Connection,
    workspace_id: &str,
    label: &str,
) -> Result<(), ActionError> {
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
    let label = non_empty(label)?;
    conn.request("tab.rename", json!({ "tab_id": tab_id, "label": label }))
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
