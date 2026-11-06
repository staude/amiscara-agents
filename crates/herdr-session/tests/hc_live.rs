//! Against a herdr-core test session only (writes: starts a shell there,
//! types into it and ends it):
//! `HC_SESSION=amiscara-test hc server start`, then
//! `HC_SESSION=amiscara-test cargo test -p herdr-session --test hc_live -- --ignored --nocapture`,
//! afterwards `HC_SESSION=amiscara-test hc server stop`.

#![cfg(unix)]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use herdr_session::view::{AgentState, SessionUpdate};
use herdr_session::{Endpoint, Session, SessionError, SpaceSort};
use herdr_transport::Connection;
use serde_json::json;

/// Polls `check` on the latest update for up to `secs` seconds.
async fn wait_for<T>(
    latest: &Arc<Mutex<Option<SessionUpdate>>>,
    secs: u64,
    check: impl Fn(&SessionUpdate) -> Option<T>,
) -> Option<T> {
    for _ in 0..secs * 5 {
        let found = latest.lock().expect("lock").as_ref().and_then(&check);
        if found.is_some() {
            return found;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    None
}

/// Polls the pane's screen until a line reads `wanted`.
async fn screen_shows(session: &Session, pane: &str, wanted: &str) -> bool {
    for _ in 0..75 {
        if let Ok(text) = session.screen_excerpt(pane, 40).await
            && text.lines().any(|line| line.trim() == wanted)
        {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    false
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs a herdr-core test session"]
async fn a_herdr_core_space_takes_prompts_keys_and_scripts() {
    let session_name = std::env::var("HC_SESSION").unwrap_or_default();
    assert!(
        !session_name.is_empty() && session_name != "default",
        "set HC_SESSION to a test session, never the one in use"
    );
    let hc_socket = Connection::default_local_hc_socket();
    let conn = Connection::local_with_hc("/nonexistent/herdr.sock", hc_socket);
    let repo = env!("CARGO_MANIFEST_DIR");
    let started = conn
        .hc_request(
            "terminal.run",
            json!({
                "argv": ["sh"],
                "cwd": repo,
                "name": "amiscara-live",
                "env": {"PS1": "$ "},
                "labels": {
                    "herdr.space": "sp-amiscara-live",
                    "herdr.tab": "tb-amiscara-live",
                    "where": "amiscara-live / 1"
                }
            }),
        )
        .await
        .expect("terminal.run");
    let address = started["address"]
        .as_str()
        .or_else(|| started["terminal"]["address"].as_str())
        .expect("address")
        .to_owned();
    let pane = format!("hc:{address}");

    let latest = Arc::new(Mutex::new(None));
    let store = latest.clone();
    let session = Session::start(
        Endpoint::Local {
            socket_path: Some("/nonexistent/herdr.sock".into()),
            hc_socket_path: None,
        },
        false,
        SpaceSort::Herdr,
        move |update| *store.lock().expect("lock") = Some(update),
    )
    .expect("session");

    let space = wait_for(&latest, 15, |update| {
        update
            .workspaces
            .iter()
            .find(|ws| ws.workspace_id == "hc:sp-amiscara-live")
            .cloned()
    })
    .await
    .expect("the space shows up");
    assert_eq!(space.label, "amiscara-live");
    assert!(space.tabs[0].panes.iter().any(|item| item.pane_id == pane));
    let version = latest
        .lock()
        .expect("lock")
        .as_ref()
        .and_then(|update| update.server_version.clone());
    assert!(
        version
            .as_deref()
            .is_some_and(|v| v.starts_with("herdr-core")),
        "{version:?}"
    );

    // A prompt: pasted, then Enter.
    session
        .send_prompt(&pane, "echo hc-prompt-ok")
        .await
        .expect("prompt");
    assert!(screen_shows(&session, &pane, "hc-prompt-ok").await);

    // Keys, one by one.
    let keys: Vec<String> = ["e", "c", "h", "o", "space", "k", "1", "enter"]
        .into_iter()
        .map(String::from)
        .collect();
    session.send_keys(&pane, &keys).await.expect("keys");
    assert!(screen_shows(&session, &pane, "k1").await);

    // Text without Enter is refused rather than typed wrongly.
    assert!(matches!(
        session.send_text(&pane, "äöü 'x'").await,
        Err(SessionError::Unsupported(_))
    ));

    // The program's own status report (OSC 7501) reaches the board.
    session
        .send_prompt(
            &pane,
            r"printf '\033]7501;state=blocked:app=claude-code\007'",
        )
        .await
        .expect("status prompt");
    let blocked = wait_for(&latest, 15, |update| {
        update
            .board
            .iter()
            .find(|item| item.pane_id == pane && item.agent_state == AgentState::Blocked)
            .map(|item| item.agent.clone())
    })
    .await;
    assert_eq!(blocked.as_deref(), Some("claude"));

    // A script through machine.exec, without a tab.
    session
        .working_tree_diff(&pane)
        .await
        .expect("diff runs on herdr-core");

    // Spaces and tabs stay herdr desktop's.
    assert!(matches!(
        session.rename_tab("hc:tb-amiscara-live", "x").await,
        Err(SessionError::Unsupported(_))
    ));

    session.stop();
    let _ = conn
        .hc_request("terminal.kill", json!({ "terminal": address }))
        .await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    let _ = conn
        .hc_request("terminal.rm", json!({ "terminal": address }))
        .await;
}
