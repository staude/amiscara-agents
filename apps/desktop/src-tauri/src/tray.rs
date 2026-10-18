//! The tray icon (Windows notification area, Linux status icon): how many
//! agents wait, a menu to jump to them, and the app keeps running there
//! with the window closed, like the Mac menu bar item.

use std::collections::HashMap;

use herdr_session::view::{AgentState, BoardItem};
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager};

const TRAY_ID: &str = "main";
const ICON: &[u8] = include_bytes!("../icons/tray.png");
const ICON_WAITING: &[u8] = include_bytes!("../icons/tray-waiting.png");

/// A waiting agent as the menu lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Waiting {
    host_id: String,
    host_name: String,
    workspace_id: String,
    pane_id: String,
    label: String,
}

/// Waiting agents per host, from the last update of each session.
#[derive(Default)]
pub struct WaitingAgents(HashMap<String, Vec<Waiting>>);

impl WaitingAgents {
    /// Records a host's board; true when the tray needs a new menu.
    pub fn set(&mut self, host_id: &str, host_name: &str, board: &[BoardItem]) -> bool {
        let waiting: Vec<Waiting> = board
            .iter()
            .filter(|item| item.agent_state == AgentState::Blocked)
            .map(|item| Waiting {
                host_id: host_id.to_owned(),
                host_name: host_name.to_owned(),
                workspace_id: item.workspace_id.clone(),
                pane_id: item.pane_id.clone(),
                label: {
                    let agent = if item.agent.is_empty() {
                        "Agent"
                    } else {
                        &item.agent
                    };
                    let place = match &item.workspace_group {
                        Some(group) => format!("{} ({group})", item.workspace_name),
                        None => item.workspace_name.clone(),
                    };
                    format!("{agent}: {place} · Tab {}", item.tab_label)
                },
            })
            .collect();
        if self.0.get(host_id) == Some(&waiting) {
            return false;
        }
        self.0.insert(host_id.to_owned(), waiting);
        true
    }

    pub fn remove(&mut self, host_id: &str) -> bool {
        self.0.remove(host_id).is_some()
    }

    fn all(&self) -> Vec<&Waiting> {
        let mut all: Vec<&Waiting> = self.0.values().flatten().collect();
        all.sort_by(|a, b| (&a.host_name, &a.label).cmp(&(&b.host_name, &b.label)));
        all
    }
}

pub fn create(app: &AppHandle) -> tauri::Result<()> {
    let menu = build_menu(app, &WaitingAgents::default())?;
    TrayIconBuilder::with_id(TRAY_ID)
        .icon(Image::from_bytes(ICON)?)
        .tooltip("Amiscara Agents")
        .menu(&menu)
        // On Windows a left click opens the window, the menu is on the right.
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| {
            let id = event.id().as_ref();
            if id == "open" {
                show_window(app);
            } else if id == "quit" {
                app.exit(0);
            } else if let Some(target) = id.strip_prefix("agent|") {
                let mut parts = target.splitn(3, '|');
                if let (Some(host), Some(space), Some(pane)) =
                    (parts.next(), parts.next(), parts.next())
                {
                    crate::app::open_pane(app, host, space, pane);
                }
            }
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                show_window(tray.app_handle());
            }
        })
        .build(app)?;
    Ok(())
}

/// New menu, icon and tooltip for the waiting agents.
pub fn refresh(app: &AppHandle, waiting: &WaitingAgents) {
    let Some(tray) = app.tray_by_id(TRAY_ID) else {
        return;
    };
    let count = waiting.all().len();
    if let Ok(menu) = build_menu(app, waiting) {
        let _ = tray.set_menu(Some(menu));
    }
    let icon = if count > 0 { ICON_WAITING } else { ICON };
    if let Ok(image) = Image::from_bytes(icon) {
        let _ = tray.set_icon(Some(image));
    }
    let _ = tray.set_tooltip(Some(match count {
        0 => "Amiscara Agents".to_owned(),
        1 => "Amiscara Agents: 1 Agent wartet".to_owned(),
        n => format!("Amiscara Agents: {n} Agents warten"),
    }));
}

fn build_menu(app: &AppHandle, waiting: &WaitingAgents) -> tauri::Result<Menu<tauri::Wry>> {
    let menu = Menu::new(app)?;
    let all = waiting.all();
    if all.is_empty() {
        menu.append(&MenuItem::with_id(
            app,
            "none",
            "Kein Agent wartet",
            false,
            None::<&str>,
        )?)?;
    }
    // Host names only help when there is more than one host.
    let several_hosts = all.iter().any(|w| w.host_id != all[0].host_id);
    for entry in &all {
        let text = if several_hosts {
            format!("{} · {}", entry.host_name, entry.label)
        } else {
            entry.label.clone()
        };
        let id = format!(
            "agent|{}|{}|{}",
            entry.host_id, entry.workspace_id, entry.pane_id
        );
        menu.append(&MenuItem::with_id(app, id, text, true, None::<&str>)?)?;
    }
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(
        app,
        "open",
        "Amiscara Agents öffnen",
        true,
        None::<&str>,
    )?)?;
    menu.append(&MenuItem::with_id(
        app,
        "quit",
        "Beenden",
        true,
        None::<&str>,
    )?)?;
    Ok(menu)
}

pub fn show_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}
