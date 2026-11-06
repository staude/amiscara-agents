//! herdr-core terminals as spaces, tabs and panes (#329).
//!
//! herdr-core knows only terminals. herdr desktop puts its spaces and tabs
//! on them as labels (`herdr.space`, `herdr.tab`, both ids, and `where` =
//! `<space> / <tab>` with the names); the order and splits it keeps in a
//! core document of its own, which is not documented, so spaces here come
//! in the order they were started. A terminal without a space label (for
//! example `hc run --bg claude`) gets a space per directory and a tab of
//! its own. The status is the program's own report (OSC 7501).
//!
//! Every id carries [`PREFIX`], so the actions can tell herdr-core's
//! terminals from herdr's panes. A pane's id is `hc:` and the terminal's
//! address: `t7` here, `machine/t7` on a machine connected to the core.

use std::collections::BTreeMap;

use herdr_proto::hc::{ListResult, Status, Terminal};
use herdr_proto::{AgentStatus, PaneInfo, TabInfo, WorkspaceInfo};
use herdr_transport::{Connection, TransportError};
use serde_json::json;

use crate::state::most_urgent;

/// Starts every id of herdr-core's spaces, tabs and panes.
pub const PREFIX: &str = "hc:";

/// What actions answer on herdr-core for what it cannot do.
pub const NOT_AVAILABLE: &str = "not available on herdr-core";

/// Whether a space, tab or pane id is herdr-core's.
pub fn is_hc(id: &str) -> bool {
    id.starts_with(PREFIX)
}

/// The terminal address behind a pane id from [`snapshot_from`].
pub fn address(pane_id: &str) -> Option<&str> {
    pane_id.strip_prefix(PREFIX)
}

/// The machine of a terminal address (`m` of `m/t7`); `None` on this core.
pub fn machine(address: &str) -> Option<&str> {
    address.split_once('/').map(|(machine, _)| machine)
}

/// The machine of a herdr-core space, tab or pane id.
pub fn machine_of(id: &str) -> Option<&str> {
    let rest = id.strip_prefix(PREFIX)?;
    let rest = rest
        .strip_prefix("dir:")
        .or_else(|| rest.strip_prefix("tab:"))
        .unwrap_or(rest);
    // A directory is absolute, so a machine comes before its first `/`.
    match rest.split_once('/') {
        Some((machine, _)) if !machine.is_empty() => Some(machine),
        _ => None,
    }
}

/// herdr-core's terminals, mapped.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct HcSnapshot {
    pub workspaces: Vec<WorkspaceInfo>,
    pub tabs: Vec<TabInfo>,
    pub panes: Vec<PaneInfo>,
}

/// Maps the live terminals onto spaces, tabs and panes. Spaces are
/// numbered from `first_number` (after herdr's), in the order of their
/// first terminal; tabs from 1 the same way.
pub fn snapshot_from(terminals: &[Terminal], first_number: u32) -> HcSnapshot {
    struct Tab<'a> {
        id: String,
        first: &'a Terminal,
        panes: Vec<&'a Terminal>,
    }
    struct Space<'a> {
        id: String,
        first: &'a Terminal,
        tabs: Vec<Tab<'a>>,
    }

    let mut live: Vec<&Terminal> = terminals.iter().filter(|t| t.is_live()).collect();
    live.sort_by(|a, b| (a.created_ms, &a.address).cmp(&(b.created_ms, &b.address)));
    // In order of the first terminal, since `live` is sorted.
    let mut spaces: Vec<Space<'_>> = Vec::new();
    for terminal in live {
        let space_id = space_id(terminal);
        let tab_id = tab_id(terminal);
        let space = match spaces.iter().position(|space| space.id == space_id) {
            Some(index) => &mut spaces[index],
            None => {
                spaces.push(Space {
                    id: space_id,
                    first: terminal,
                    tabs: Vec::new(),
                });
                let last = spaces.len() - 1;
                &mut spaces[last]
            }
        };
        match space.tabs.iter_mut().find(|tab| tab.id == tab_id) {
            Some(tab) => tab.panes.push(terminal),
            None => space.tabs.push(Tab {
                id: tab_id,
                first: terminal,
                panes: vec![terminal],
            }),
        }
    }

    let mut snapshot = HcSnapshot::default();
    for (space, number) in spaces.iter().zip(first_number..) {
        let mut space_status = Vec::new();
        let mut pane_count = 0;
        for (index, tab) in space.tabs.iter().enumerate() {
            let tab_number = u32::try_from(index + 1).unwrap_or(u32::MAX);
            let panes: Vec<PaneInfo> = tab
                .panes
                .iter()
                .map(|terminal| pane(terminal, &space.id, &tab.id))
                .collect();
            let status = most_urgent(panes.iter().map(|pane| pane.agent_status));
            space_status.push(status);
            pane_count += panes.len();
            snapshot.tabs.push(TabInfo {
                tab_id: tab.id.clone(),
                workspace_id: space.id.clone(),
                number: tab_number,
                label: tab_name(tab.first, tab_number),
                focused: index == 0,
                pane_count: u32::try_from(panes.len()).unwrap_or(u32::MAX),
                agent_status: status,
            });
            snapshot.panes.extend(panes);
        }
        snapshot.workspaces.push(WorkspaceInfo {
            workspace_id: space.id.clone(),
            number,
            label: space_name(space.first),
            focused: false,
            tab_count: u32::try_from(space.tabs.len()).unwrap_or(u32::MAX),
            pane_count: u32::try_from(pane_count).unwrap_or(u32::MAX),
            active_tab_id: space
                .tabs
                .first()
                .map(|tab| tab.id.clone())
                .unwrap_or_default(),
            agent_status: most_urgent(space_status.into_iter()),
            worktree: None,
            tokens: BTreeMap::new(),
        });
    }
    snapshot
}

/// `m/` for a terminal on a connected machine, else nothing.
fn machine_part(terminal: &Terminal) -> String {
    machine(&terminal.address).map_or_else(String::new, |machine| format!("{machine}/"))
}

fn non_empty(text: &str) -> Option<&str> {
    let text = text.trim();
    (!text.is_empty()).then_some(text)
}

/// Where the terminal's program works now, else where it started.
fn directory(terminal: &Terminal) -> &str {
    terminal
        .foreground
        .as_ref()
        .and_then(|fg| non_empty(&fg.cwd))
        .unwrap_or(&terminal.cwd)
}

fn space_id(terminal: &Terminal) -> String {
    match terminal
        .labels
        .get("herdr.space")
        .and_then(|id| non_empty(id))
    {
        Some(space) => format!("{PREFIX}{}{space}", machine_part(terminal)),
        None => format!(
            "{PREFIX}dir:{}{}",
            machine_part(terminal),
            directory(terminal)
        ),
    }
}

fn tab_id(terminal: &Terminal) -> String {
    match terminal
        .labels
        .get("herdr.tab")
        .and_then(|id| non_empty(id))
    {
        Some(tab) => format!("{PREFIX}{}{tab}", machine_part(terminal)),
        None => format!("{PREFIX}tab:{}", terminal.address),
    }
}

/// herdr desktop's `where` label, split at its last ` / `.
fn where_names(terminal: &Terminal) -> Option<(&str, &str)> {
    let place = terminal.labels.get("where")?;
    Some(match place.rsplit_once(" / ") {
        Some((space, tab)) => (space.trim(), tab.trim()),
        None => (place.trim(), ""),
    })
}

fn space_name(terminal: &Terminal) -> String {
    let name = where_names(terminal)
        .and_then(|(space, _)| non_empty(space))
        .map(str::to_owned)
        .unwrap_or_else(|| {
            let dir = directory(terminal).trim_end_matches('/');
            match dir.rsplit_once('/') {
                Some((_, last)) if !last.is_empty() => last.to_owned(),
                _ if dir.is_empty() => "/".to_owned(),
                _ => dir.to_owned(),
            }
        });
    format!("{}{name}", machine_part(terminal))
}

/// The tab's name from `where`, unless that is only herdr desktop's
/// number; then the terminal's name, its program, or the tab's number.
fn tab_name(terminal: &Terminal, number: u32) -> String {
    where_names(terminal)
        .map(|(_, tab)| tab)
        .filter(|tab| !tab.is_empty() && !tab.chars().all(|ch| ch.is_ascii_digit()))
        .or_else(|| terminal.name.as_deref().and_then(non_empty))
        .or_else(|| {
            terminal
                .status
                .as_ref()
                .and_then(|status| status.app.as_deref())
                .and_then(non_empty)
        })
        .or_else(|| {
            terminal
                .foreground
                .as_ref()
                .and_then(|fg| non_empty(&fg.name))
        })
        .map_or_else(|| number.to_string(), str::to_owned)
}

/// herdr's status for an OSC 7501 report; `error` waits for the user like
/// `blocked`.
pub fn agent_status(status: Option<&Status>) -> AgentStatus {
    match status.map(|status| status.state.as_str()) {
        Some("idle") => AgentStatus::Idle,
        Some("working") => AgentStatus::Working,
        Some("blocked" | "error") => AgentStatus::Blocked,
        Some("done") => AgentStatus::Done,
        _ => AgentStatus::Unknown,
    }
}

/// The agent kind as herdr names it: the reporting program (`claude-code`
/// is `claude`), else the foreground program when it is a known agent.
fn agent_kind(terminal: &Terminal) -> Option<String> {
    let reported = terminal
        .status
        .as_ref()
        .and_then(|status| status.app.as_deref())
        .and_then(non_empty)
        .map(|app| {
            let app = app.to_lowercase();
            app.strip_suffix("-code").map(str::to_owned).unwrap_or(app)
        });
    reported.or_else(|| {
        let name = terminal.foreground.as_ref()?.name.to_lowercase();
        crate::actions::COMMON_KINDS
            .contains(&name.as_str())
            .then_some(name)
    })
}

fn pane(terminal: &Terminal, workspace_id: &str, tab_id: &str) -> PaneInfo {
    let title = terminal
        .status
        .as_ref()
        .and_then(|status| status.title.as_deref())
        .and_then(non_empty)
        .or_else(|| non_empty(&terminal.title))
        .map(str::to_owned);
    PaneInfo {
        pane_id: format!("{PREFIX}{}", terminal.address),
        workspace_id: workspace_id.to_owned(),
        tab_id: tab_id.to_owned(),
        focused: false,
        cwd: non_empty(&terminal.cwd).map(str::to_owned),
        foreground_cwd: terminal
            .foreground
            .as_ref()
            .and_then(|fg| non_empty(&fg.cwd))
            .map(str::to_owned),
        label: terminal
            .name
            .as_deref()
            .and_then(non_empty)
            .map(str::to_owned),
        title: title.clone(),
        agent: agent_kind(terminal),
        display_agent: None,
        terminal_title_stripped: title,
        agent_status: agent_status(terminal.status.as_ref()),
        revision: terminal.turn,
        tokens: BTreeMap::new(),
    }
}

/// One terminal as a pane, read fresh with `terminal.get`.
pub async fn pane_info(conn: &Connection, pane_id: &str) -> Result<PaneInfo, TransportError> {
    let address = address(pane_id).unwrap_or(pane_id);
    let value = conn
        .hc_request("terminal.get", json!({ "terminal": address }))
        .await?;
    let terminal: Terminal =
        serde_json::from_value(value).map_err(herdr_proto::ProtoError::from)?;
    Ok(pane(&terminal, &space_id(&terminal), &tab_id(&terminal)))
}

/// All terminals, live and finished, with `terminal.list`.
pub async fn list(conn: &Connection) -> Result<Vec<Terminal>, TransportError> {
    let value = conn.hc_request("terminal.list", json!({})).await?;
    let list: ListResult = serde_json::from_value(value).map_err(herdr_proto::ProtoError::from)?;
    Ok(list.terminals)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn terminal(value: Value) -> Terminal {
        let mut base = json!({
            "address": "t1", "argv": ["zsh"], "cwd": "/Users/me", "state": "live",
            "created_ms": 1, "labels": {}, "title": ""
        });
        if let (Some(base), Some(extra)) = (base.as_object_mut(), value.as_object()) {
            for (key, value) in extra {
                base.insert(key.clone(), value.clone());
            }
        }
        match serde_json::from_value(base) {
            Ok(terminal) => terminal,
            Err(err) => panic!("fixture: {err}"),
        }
    }

    fn desktop(address: &str, created: u64, space: &str, tab: &str, place: &str) -> Terminal {
        terminal(json!({
            "address": address, "created_ms": created,
            "labels": {"herdr.space": space, "herdr.tab": tab, "where": place},
        }))
    }

    #[test]
    fn herdr_desktop_labels_make_spaces_and_tabs() {
        let terminals = vec![
            desktop("t3", 30, "spB", "tbB1", "Bücher / 2"),
            desktop("t1", 10, "spA", "tbA1", "Kino / Review"),
            desktop("t2", 20, "spA", "tbA2", "Kino / 3"),
            desktop("t4", 40, "spA", "tbA1", "Kino / Review"),
            terminal(json!({"address": "t5", "state": "finished", "created_ms": 1})),
        ];
        let snapshot = snapshot_from(&terminals, 4);
        let spaces: Vec<_> = snapshot
            .workspaces
            .iter()
            .map(|ws| {
                (
                    ws.workspace_id.as_str(),
                    ws.number,
                    ws.label.as_str(),
                    ws.tab_count,
                    ws.pane_count,
                )
            })
            .collect();
        assert_eq!(
            spaces,
            [("hc:spA", 4, "Kino", 2, 3), ("hc:spB", 5, "Bücher", 1, 1)]
        );
        let tabs: Vec<_> = snapshot
            .tabs
            .iter()
            .map(|tab| {
                (
                    tab.tab_id.as_str(),
                    tab.number,
                    tab.label.as_str(),
                    tab.focused,
                )
            })
            .collect();
        // A tab named only by herdr desktop's number, with no program
        // known, gets its own number.
        assert_eq!(
            tabs,
            [
                ("hc:tbA1", 1, "Review", true),
                ("hc:tbA2", 2, "2", false),
                ("hc:tbB1", 1, "1", true)
            ]
        );
        assert_eq!(snapshot.workspaces[0].active_tab_id, "hc:tbA1");
        let panes: Vec<_> = snapshot
            .panes
            .iter()
            .map(|pane| (pane.pane_id.as_str(), pane.tab_id.as_str()))
            .collect();
        assert_eq!(
            panes,
            [
                ("hc:t1", "hc:tbA1"),
                ("hc:t4", "hc:tbA1"),
                ("hc:t2", "hc:tbA2"),
                ("hc:t3", "hc:tbB1")
            ]
        );
    }

    #[test]
    fn terminals_without_space_get_one_per_directory() {
        let terminals = vec![
            terminal(json!({"address": "t1", "created_ms": 1, "cwd": "/Users/me",
                "foreground": {"name": "claude", "argv": ["claude"], "cwd": "/Users/me/dev/kino"}})),
            terminal(
                json!({"address": "t2", "created_ms": 2, "cwd": "/Users/me/dev/kino",
                "name": "reviewer"}),
            ),
            terminal(json!({"address": "box/t1", "created_ms": 3, "cwd": "/srv/app"})),
        ];
        let snapshot = snapshot_from(&terminals, 1);
        let spaces: Vec<_> = snapshot
            .workspaces
            .iter()
            .map(|ws| (ws.workspace_id.as_str(), ws.label.as_str(), ws.tab_count))
            .collect();
        assert_eq!(
            spaces,
            [
                ("hc:dir:/Users/me/dev/kino", "kino", 2),
                ("hc:dir:box//srv/app", "box/app", 1)
            ]
        );
        let tabs: Vec<_> = snapshot
            .tabs
            .iter()
            .map(|tab| (tab.tab_id.as_str(), tab.label.as_str()))
            .collect();
        assert_eq!(
            tabs,
            [
                ("hc:tab:t1", "claude"),
                ("hc:tab:t2", "reviewer"),
                ("hc:tab:box/t1", "1")
            ]
        );
        assert_eq!(snapshot.panes[2].pane_id, "hc:box/t1");
        assert_eq!(machine_of("hc:box/t1"), Some("box"));
        assert_eq!(machine_of("hc:dir:box//srv/app"), Some("box"));
        assert_eq!(machine_of("hc:tab:box/t1"), Some("box"));
        assert_eq!(machine_of("hc:dir:/Users/me/dev/kino"), None);
        assert_eq!(machine_of("hc:t1"), None);
        assert_eq!(machine_of("w1:p1"), None);
    }

    #[test]
    fn status_and_agent_come_from_the_report() {
        let terminals = vec![
            terminal(json!({"address": "t1", "created_ms": 1,
                "labels": {"herdr.space": "s", "herdr.tab": "a", "where": "S / 1"},
                "status": {"app": "claude-code", "state": "working", "title": "Fix login"}})),
            terminal(json!({"address": "t2", "created_ms": 2,
                "labels": {"herdr.space": "s", "herdr.tab": "a", "where": "S / 1"},
                "status": {"app": "Codex", "state": "error"}})),
            terminal(json!({"address": "t3", "created_ms": 3,
                "labels": {"herdr.space": "s", "herdr.tab": "b", "where": "S / 2"},
                "foreground": {"name": "opencode", "argv": [], "cwd": "/x"}})),
            terminal(json!({"address": "t4", "created_ms": 4,
                "labels": {"herdr.space": "s", "herdr.tab": "c", "where": "S / 3"},
                "foreground": {"name": "vim", "argv": [], "cwd": "/x"}})),
        ];
        let snapshot = snapshot_from(&terminals, 1);
        let panes: Vec<_> = snapshot
            .panes
            .iter()
            .map(|pane| {
                (
                    pane.agent.as_deref(),
                    pane.agent_status,
                    pane.title.as_deref(),
                )
            })
            .collect();
        assert_eq!(
            panes,
            [
                (Some("claude"), AgentStatus::Working, Some("Fix login")),
                (Some("codex"), AgentStatus::Blocked, None),
                (Some("opencode"), AgentStatus::Unknown, None),
                (None, AgentStatus::Unknown, None)
            ]
        );
        // The most urgent pane decides for its tab and space.
        assert_eq!(snapshot.tabs[0].agent_status, AgentStatus::Blocked);
        assert_eq!(snapshot.tabs[2].agent_status, AgentStatus::Unknown);
        assert_eq!(snapshot.workspaces[0].agent_status, AgentStatus::Blocked);
        assert_eq!(agent_status(None), AgentStatus::Unknown);
    }

    #[test]
    fn foreign_machines_name_their_spaces() {
        let terminals = vec![desktop("vps/t2", 1, "spX", "tbX", "api / Deploy")];
        let snapshot = snapshot_from(&terminals, 1);
        assert_eq!(snapshot.workspaces[0].workspace_id, "hc:vps/spX");
        assert_eq!(snapshot.workspaces[0].label, "vps/api");
        assert_eq!(snapshot.tabs[0].tab_id, "hc:vps/tbX");
        assert_eq!(snapshot.tabs[0].label, "Deploy");
        assert!(is_hc(&snapshot.panes[0].pane_id) && !is_hc("w1:p1"));
        assert_eq!(address("hc:vps/t2"), Some("vps/t2"));
    }
}
