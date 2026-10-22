//! Notifications when an agent starts waiting or finishes, from the core's
//! `SessionUpdate::attention`: Windows toasts, libnotify on Linux. A click
//! opens the pane, the answer buttons of a waiting agent send their key.
//! Unlike the Apple apps there is no push: the app has to run (in the tray).
//! On the Mac (development only) nothing is shown.
#![cfg_attr(not(any(windows, target_os = "linux")), allow(dead_code))]

use herdr_session::view::{AgentState, BoardItem};
use tauri::AppHandle;

/// What a notification shows and where it leads.
#[derive(Debug, Clone)]
pub struct Notice {
    pub host_id: String,
    pub workspace_id: String,
    pub pane_id: String,
    pub blocked: bool,
    pub title: String,
    pub subtitle: String,
    pub body: String,
}

/// Answer keys offered on a waiting agent's notification, as in the Apple
/// apps; Windows shows at most five buttons.
const ANSWERS: [(&str, &str); 5] = [
    ("1", "1"),
    ("2", "2"),
    ("3", "3"),
    ("enter", "Enter"),
    ("esc", "Esc"),
];

impl Notice {
    /// Texts like `AgentNotificationText` of the Apple apps.
    pub fn new(host_id: &str, host_name: &str, item: &BoardItem) -> Self {
        let agent = if item.agent.is_empty() {
            "Agent"
        } else {
            &item.agent
        };
        let blocked = item.agent_state == AgentState::Blocked;
        let place = match &item.workspace_group {
            Some(group) => format!("{} ({group})", item.workspace_name),
            None => item.workspace_name.clone(),
        };
        Self {
            host_id: host_id.to_owned(),
            workspace_id: item.workspace_id.clone(),
            pane_id: item.pane_id.clone(),
            blocked,
            title: crate::i18n::agent_title(agent, blocked),
            subtitle: format!("{host_name} · {place} · Tab {}", item.tab_label),
            body: item.title.clone(),
        }
    }
}

/// What the user did with a notification.
enum Response {
    Open,
    Key(String),
}

fn respond(app: &AppHandle, notice: &Notice, response: Response) {
    match response {
        Response::Open => {
            crate::app::open_pane(app, &notice.host_id, &notice.workspace_id, &notice.pane_id)
        }
        Response::Key(key) => crate::app::answer(app, &notice.host_id, &notice.pane_id, key),
    }
}

#[cfg(windows)]
pub fn show(app: &AppHandle, notice: Notice) {
    use tauri_winrt_notification::{Sound, Toast};
    // Installed, the Start menu shortcut carries the identifier as app id;
    // a dev build borrows PowerShell's.
    let app_id = if cfg!(debug_assertions) {
        Toast::POWERSHELL_APP_ID.to_owned()
    } else {
        app.config().identifier.clone()
    };
    let mut toast = Toast::new(&app_id)
        .title(&notice.title)
        .text1(&notice.subtitle)
        .text2(&notice.body)
        .sound(notice.blocked.then_some(Sound::Default));
    if notice.blocked {
        for (key, title) in ANSWERS {
            toast = toast.add_button(title, &format!("key.{key}"));
        }
    }
    let handle = app.clone();
    let shown = notice.clone();
    let _ = toast
        .on_activated(move |action| {
            let response = match action.as_deref().and_then(|a| a.strip_prefix("key.")) {
                Some(key) => Response::Key(key.to_owned()),
                None => Response::Open,
            };
            respond(&handle, &shown, response);
            Ok(())
        })
        .show();
}

#[cfg(target_os = "linux")]
pub fn show(app: &AppHandle, notice: Notice) {
    let app = app.clone();
    // Waiting for the click blocks, one thread per open notification.
    std::thread::spawn(move || {
        let mut notification = notify_rust::Notification::new();
        notification
            .appname("Amiscara Agents")
            .summary(&notice.title)
            // Servers read simple markup (links too) in the body; titles come
            // from the terminal, where any program can set them.
            .body(&markup_escaped(&format!(
                "{}\n{}",
                notice.subtitle, notice.body
            )))
            .action("default", crate::i18n::tr("Öffnen", "Open"));
        if notice.blocked {
            for (key, title) in ANSWERS {
                notification.action(&format!("key.{key}"), title);
            }
        }
        let Ok(handle) = notification.show() else {
            return;
        };
        handle.wait_for_action(|action| {
            let response = match action {
                "default" => Response::Open,
                other => match other.strip_prefix("key.") {
                    Some(key) => Response::Key(key.to_owned()),
                    None => return,
                },
            };
            respond(&app, &notice, response);
        });
    });
}

/// `&`, `<` and `>` as entities, for the markup of a notification body.
#[cfg(any(target_os = "linux", test))]
fn markup_escaped(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// The Mac has the SwiftUI app with its own notifications.
#[cfg(not(any(windows, target_os = "linux")))]
pub fn show(_app: &AppHandle, _notice: Notice) {}

#[cfg(test)]
mod tests {
    use super::markup_escaped;

    #[test]
    fn notification_bodies_carry_no_markup() {
        assert_eq!(
            markup_escaped(r#"<a href="https://x">klick</a> & <b>"#),
            r#"&lt;a href="https://x"&gt;klick&lt;/a&gt; &amp; &lt;b&gt;"#
        );
    }
}
