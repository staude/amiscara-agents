//! Input for panes and agents: the only writing calls in the core.
//!
//! Keys use herdr's logical names: `enter`, `esc`, `tab`, `backspace`,
//! `up`, `down`, `left`, `right`, single characters such as `1`, and
//! combinations such as `ctrl+c`. herdr validates all keys before it writes
//! anything.

use herdr_proto::ProtoError;
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
}
