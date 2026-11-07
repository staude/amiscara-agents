//! Wire types for herdr-core (`hc`), the runtime under the herdr desktop
//! app (#329).
//!
//! herdr-core speaks JSON-RPC 2.0, one message per line, on its own socket
//! or over stdin/stdout through `hc connect` (`hc schema` has the whole
//! API). Spaces and tabs are only labels on terminals; the program in a
//! terminal reports its status itself (OSC 7501). Only the fields this
//! client uses are decoded, unknown ones are ignored.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::ProtoError;

/// Protocol generation this client speaks (`hello.generation`).
pub const HC_GENERATION: u32 = 1;

#[derive(Debug, Serialize)]
struct RpcRequest<'a> {
    jsonrpc: &'static str,
    id: u64,
    method: &'a str,
    params: &'a Value,
}

/// One request as a protocol line, including `\n`.
pub fn request_line(id: u64, method: &str, params: &Value) -> Result<Vec<u8>, ProtoError> {
    let mut line = serde_json::to_vec(&RpcRequest {
        jsonrpc: "2.0",
        id,
        method,
        params,
    })?;
    line.push(b'\n');
    Ok(line)
}

#[derive(Debug, Deserialize)]
struct RpcError {
    #[serde(default)]
    message: String,
    #[serde(default)]
    data: Option<RpcErrorData>,
}

#[derive(Debug, Deserialize)]
struct RpcErrorData {
    #[serde(default)]
    kind: String,
}

#[derive(Debug, Deserialize)]
struct RpcResponse {
    #[serde(default)]
    jsonrpc: Option<String>,
    #[serde(default)]
    id: Option<Value>,
    #[serde(default)]
    result: Option<Value>,
    #[serde(default)]
    error: Option<RpcError>,
}

/// Parses a response line into its `result`. A line without `jsonrpc` and
/// `id` is no herdr-core answer (for example the herdr server answering
/// through an older `authorized_keys` line) and comes back as
/// [`ProtoError::Malformed`]; an error carries its stable `data.kind`.
pub fn parse_response(line: &str) -> Result<Value, ProtoError> {
    let raw: RpcResponse = serde_json::from_str(line)?;
    if raw.jsonrpc.as_deref() != Some("2.0") || raw.id.is_none() {
        return Err(ProtoError::Malformed(line.trim_end().to_owned()));
    }
    match (raw.result, raw.error) {
        (_, Some(err)) => Err(ProtoError::Rpc {
            kind: err.data.map(|data| data.kind).unwrap_or_default(),
            message: err.message,
        }),
        (Some(result), None) => Ok(result),
        (None, None) => Err(ProtoError::Malformed(line.trim_end().to_owned())),
    }
}

/// `hello` result.
#[derive(Debug, Clone, Deserialize)]
pub struct HelloResult {
    pub generation: u32,
    pub version: String,
    #[serde(default)]
    pub core: Option<CoreInfo>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct CoreInfo {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
}

/// A terminal as `terminal.list`, `terminal.get` and `events.subscribe`
/// report it. `address` is `t7` on this core and `machine/t7` on a
/// connected machine.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Terminal {
    pub address: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub labels: BTreeMap<String, String>,
    #[serde(default)]
    pub argv: Vec<String>,
    #[serde(default)]
    pub cwd: String,
    /// `live` or `finished`.
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub created_ms: u64,
    /// What runs in it right now; `None` once it has finished.
    #[serde(default)]
    pub foreground: Option<Foreground>,
    /// The program's own word for what it does (OSC 7501).
    #[serde(default)]
    pub status: Option<Status>,
    #[serde(default)]
    pub title: String,
    /// Goes up each time the status leaves `working`.
    #[serde(default)]
    pub turn: u64,
    #[serde(default)]
    pub template: Option<String>,
    /// Address of the terminal that started this one (`hc run --bg` from
    /// inside a terminal), set once at start.
    #[serde(default)]
    pub parent: Option<String>,
    /// When the status word last changed, in ms since the epoch.
    #[serde(default)]
    pub status_ms: Option<u64>,
}

impl Terminal {
    pub fn is_live(&self) -> bool {
        self.state == "live"
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Foreground {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub argv: Vec<String>,
    #[serde(default)]
    pub cwd: String,
}

/// One OSC 7501 record. `state` is `idle`, `working`, `done`, `blocked` or
/// `error`; `app` names the program (`claude-code`).
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Status {
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub app: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub msg: Option<String>,
    #[serde(default)]
    pub kind: Option<String>,
}

/// `terminal.list` result.
#[derive(Debug, Clone, Deserialize)]
pub struct ListResult {
    #[serde(default)]
    pub terminals: Vec<Terminal>,
}

/// `events.subscribe` result: the matching terminals, then events after
/// `seq` follow as notifications.
#[derive(Debug, Clone, Deserialize)]
pub struct SubscribeResult {
    #[serde(default)]
    pub seq: u64,
    #[serde(default)]
    pub terminals: Vec<Terminal>,
}

/// `terminal.read` result: plain text, no colours.
#[derive(Debug, Clone, Deserialize)]
pub struct ReadResult {
    pub text: String,
    #[serde(default)]
    pub complete: bool,
}

/// `machine.exec` result; the output is base64.
#[derive(Debug, Clone, Deserialize)]
pub struct ExecResult {
    #[serde(default)]
    pub code: Option<i32>,
    #[serde(default)]
    pub stdout: String,
    #[serde(default)]
    pub stderr: String,
    #[serde(default)]
    pub timed_out: bool,
}

impl ExecResult {
    pub fn stdout_text(&self) -> String {
        String::from_utf8_lossy(&decode_base64(&self.stdout)).into_owned()
    }

    pub fn stderr_text(&self) -> String {
        String::from_utf8_lossy(&decode_base64(&self.stderr)).into_owned()
    }
}

/// Standard base64 with or without padding; characters outside the
/// alphabet are skipped.
pub fn decode_base64(text: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    let mut buffer = 0u32;
    let mut bits = 0u32;
    for byte in text.bytes() {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            _ => continue,
        };
        buffer = (buffer << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((buffer >> bits) & 0xff) as u8);
        }
    }
    out
}

/// A notification on a subscription.
#[derive(Debug, Clone, PartialEq)]
pub enum Notification {
    /// One fact changed: `kind` is `created`, `status`, `title`, `labels`,
    /// `foreground`, `turn`, `finished`, `removed`, ...; `data` the new
    /// values (the whole terminal for `created`).
    Event {
        seq: u64,
        terminal: String,
        kind: String,
        data: Value,
    },
    /// Sent every 15 s while nothing else happens.
    Heartbeat { seq: u64 },
    /// The subscriber fell behind; a fresh snapshot follows in `params`
    /// when the core sends one.
    Missed { params: Value },
    /// A notification this client does not know.
    Other,
}

/// Parses one line of a subscription. An error line ends it.
pub fn parse_notification(value: &Value) -> Result<Notification, ProtoError> {
    if let Some(err) = value.get("error") {
        let err: RpcError = serde_json::from_value(err.clone())?;
        return Err(ProtoError::Rpc {
            kind: err.data.map(|data| data.kind).unwrap_or_default(),
            message: err.message,
        });
    }
    let params = value.get("params").cloned().unwrap_or(Value::Null);
    let seq = params.get("seq").and_then(Value::as_u64).unwrap_or(0);
    Ok(match value.get("method").and_then(Value::as_str) {
        Some("event") => Notification::Event {
            seq,
            terminal: params
                .get("terminal")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            kind: params
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            data: params.get("data").cloned().unwrap_or(Value::Null),
        },
        Some("heartbeat") => Notification::Heartbeat { seq },
        Some("missed") => Notification::Missed { params },
        _ => Notification::Other,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn requests_are_json_rpc_lines() -> Result<(), ProtoError> {
        let line = request_line(7, "terminal.list", &json!({}))?;
        assert_eq!(line.last(), Some(&b'\n'));
        let value: Value = serde_json::from_slice(&line)?;
        assert_eq!(
            value,
            json!({"jsonrpc": "2.0", "id": 7, "method": "terminal.list", "params": {}})
        );
        Ok(())
    }

    #[test]
    fn responses_need_json_rpc_and_an_id() -> Result<(), ProtoError> {
        let ok = r#"{"id":1,"jsonrpc":"2.0","result":{"generation":1,"version":"0.1.18","core":{"id":"c6","name":"work"},"framed":false,"methods":[],"features":[]}}"#;
        let hello: HelloResult = serde_json::from_value(parse_response(ok)?)?;
        assert_eq!((hello.generation, hello.version.as_str()), (1, "0.1.18"));
        let err = r#"{"error":{"code":-32000,"data":{"hint":"see `hc ls --all`","kind":"not_found"},"message":"no terminal \"t99\""},"id":4,"jsonrpc":"2.0"}"#;
        assert!(matches!(
            parse_response(err),
            Err(ProtoError::Rpc { kind, .. }) if kind == "not_found"
        ));
        // The herdr server answering a line meant for herdr-core.
        let herdr = r#"{"id":"1","error":{"code":"invalid_request","message":"unknown method"}}"#;
        assert!(matches!(
            parse_response(herdr),
            Err(ProtoError::Malformed(_))
        ));
        assert!(matches!(
            parse_response(r#"{"id":1,"jsonrpc":"2.0"}"#),
            Err(ProtoError::Malformed(_))
        ));
        Ok(())
    }

    #[test]
    fn terminals_decode_with_labels_and_status() -> Result<(), ProtoError> {
        let value = json!({
            "address": "t2", "argv": ["zsh"], "cols": 200, "created_ms": 1793970847784u64,
            "cwd": "/tmp", "foreground": {"argv": ["zsh"], "cwd": "/private/tmp", "name": "zsh", "pid": 1},
            "labels": {"herdr.space": "spA", "herdr.tab": "tbB", "where": "Mein Space / 1"},
            "name": null, "state": "live", "status": {"app": "claude-code", "state": "working"},
            "title": "staude@work:/tmp", "turn": 3, "rows": 120, "screen": "exact",
            "parent": "t1", "status_ms": 1793970900000u64
        });
        let terminal: Terminal = serde_json::from_value(value)?;
        assert!(terminal.is_live());
        assert_eq!(terminal.labels["where"], "Mein Space / 1");
        assert_eq!(
            terminal.status.as_ref().map(|s| s.state.as_str()),
            Some("working")
        );
        assert_eq!(
            terminal.foreground.as_ref().map(|f| f.cwd.as_str()),
            Some("/private/tmp")
        );
        assert_eq!(terminal.parent.as_deref(), Some("t1"));
        assert_eq!(terminal.status_ms, Some(1793970900000));
        Ok(())
    }

    #[test]
    fn notifications_are_told_apart() -> Result<(), ProtoError> {
        let event = json!({"jsonrpc": "2.0", "method": "event", "params": {
            "data": {"records": {}, "reported": true, "status": {"app": "claude-code", "state": "idle"}},
            "seq": 18, "terminal": "t2", "type": "status"}});
        match parse_notification(&event)? {
            Notification::Event {
                seq,
                terminal,
                kind,
                data,
            } => {
                assert_eq!(
                    (seq, terminal.as_str(), kind.as_str()),
                    (18, "t2", "status")
                );
                assert_eq!(data["status"]["state"], "idle");
            }
            other => panic!("unexpected {other:?}"),
        }
        let beat = json!({"jsonrpc": "2.0", "method": "heartbeat", "params": {"seq": 20}});
        assert_eq!(
            parse_notification(&beat)?,
            Notification::Heartbeat { seq: 20 }
        );
        let missed =
            json!({"jsonrpc": "2.0", "method": "missed", "params": {"seq": 30, "terminals": []}});
        assert!(matches!(
            parse_notification(&missed)?,
            Notification::Missed { .. }
        ));
        let other = json!({"jsonrpc": "2.0", "method": "sparkle", "params": {}});
        assert_eq!(parse_notification(&other)?, Notification::Other);
        Ok(())
    }

    #[test]
    fn base64_decodes_with_and_without_padding() {
        assert_eq!(decode_base64("bWFpbgo="), b"main\n");
        assert_eq!(decode_base64("bWFpbgo"), b"main\n");
        assert_eq!(decode_base64(""), b"");
        let exec = ExecResult {
            code: Some(0),
            stdout: "ZmVhdHVyZS8zMjkK".into(),
            stderr: String::new(),
            timed_out: false,
        };
        assert_eq!(exec.stdout_text(), "feature/329\n");
    }
}
