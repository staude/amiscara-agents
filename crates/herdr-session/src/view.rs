//! What the apps show, built from the core's session state: plain,
//! serialisable records (the desktop app sends them to its web view,
//! herdr-ffi exposes the same types to Swift as UniFFI remote types).

use std::collections::HashMap;

use herdr_core::SessionState;
use herdr_core::pane::PaneScreen;
use herdr_core::question;
use herdr_core::spaces::{self, SpaceSort};
use herdr_core::sync::{SyncState, SyncStatus};
use herdr_core::terminal::{Color, Screen, Span};
use herdr_proto::{AgentStatus, PaneInfo, TabLayout};

#[derive(Debug, Clone, serde::Serialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum HostStatus {
    Connecting,
    Live,
    Retrying { attempt: u32, error: String },
    HostKeyUnknown { key: String, fingerprint: String },
    HostKeyChanged { key: String, fingerprint: String },
    Failed { error: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentState {
    Idle,
    Working,
    Blocked,
    Done,
    Unknown,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionUpdate {
    pub status: HostStatus,
    /// `None` until the first snapshot arrived.
    pub server_version: Option<String>,
    /// False when the server speaks a protocol this build does not know.
    pub protocol_supported: bool,
    pub focused_pane_id: Option<String>,
    pub workspaces: Vec<WorkspaceItem>,
    /// The spaces in sidebar order: herdr's or the host's sort, with linked
    /// worktrees under their repository and spaces of one name group next
    /// to each other.
    pub space_order: Vec<SpaceSlot>,
    /// Agent panes, most urgent first.
    pub board: Vec<BoardItem>,
    /// Agents that started waiting or finished since the previous update;
    /// empty on the first update after start. For notifications.
    pub attention: Vec<BoardItem>,
    /// Pages agents on the host want opened (#247), all that are pending
    /// right now: a request leaves the list once a client opened it or its
    /// time ran out. Always empty for a local host, whose own browser
    /// opens them already.
    pub open_requests: Vec<OpenRequest>,
}

/// A page an agent on the host wants opened, see
/// [`SessionUpdate::open_requests`].
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenRequest {
    pub pane_id: String,
    /// Pass it back to `dismiss_open_request`.
    pub request_id: String,
    pub url: String,
    pub workspace_label: String,
    pub pane_title: String,
    /// The URL points at the host itself (`localhost`, `127.0.0.1`,
    /// `[::1]`); `open_url` forwards it through the connection.
    pub local_address: bool,
}

/// One place in the sidebar's list of spaces.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpaceSlot {
    pub workspace_id: String,
    /// A linked worktree shown indented under its repository's space.
    pub nested: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceItem {
    pub workspace_id: String,
    pub number: u32,
    /// The full name as herdr shows it, e.g. `Privat/Dorfkino`.
    pub label: String,
    /// The name without its group, e.g. `Dorfkino`; the full label when the
    /// space forms no group (no `/`, or a linked worktree).
    pub name: String,
    /// The sidebar group from the name's part before the first `/`, e.g.
    /// `Privat`. A linked worktree gets its repository space's group.
    pub group: Option<String>,
    pub focused: bool,
    pub agent_state: AgentState,
    pub active_tab_id: String,
    /// Git repository of the space, shared by all its worktrees.
    pub repo_key: Option<String>,
    /// For a linked worktree: its directory name, e.g. `docs-herdr-remote`.
    /// herdr shows such spaces indented under the repository's space.
    pub worktree_name: Option<String>,
    /// Git branch of the space's focused pane, as herdr's sidebar shows it.
    pub branch: Option<String>,
    /// Custom values from plugins or agents (`workspace.report_metadata`),
    /// sorted by name; herdr can show them as extra rows.
    pub tokens: Vec<TokenItem>,
    pub tabs: Vec<TabItem>,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenItem {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TabItem {
    pub tab_id: String,
    pub number: u32,
    pub label: String,
    pub focused: bool,
    pub agent_state: AgentState,
    pub panes: Vec<PaneItem>,
    /// Where herdr draws each pane; `None` if the server sent no layout.
    pub layout: Option<SplitLayout>,
}

/// The arrangement of a tab's panes in terminal cells, as herdr draws it.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SplitLayout {
    /// Size of the whole tab area.
    pub columns: u32,
    pub rows: u32,
    /// herdr shows only the focused pane right now; the frames still
    /// describe the split.
    pub zoomed: bool,
    pub panes: Vec<PaneFrame>,
}

/// One pane's rectangle, relative to the tab area's top left corner.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneFrame {
    pub pane_id: String,
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneItem {
    pub pane_id: String,
    pub title: String,
    /// `None` for a plain shell.
    pub agent: Option<String>,
    /// Custom agent name from `agent.rename`.
    pub name: Option<String>,
    pub agent_state: AgentState,
    pub focused: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BoardItem {
    pub pane_id: String,
    pub workspace_id: String,
    pub tab_id: String,
    pub workspace_label: String,
    /// Short name and group of the space, as in [`WorkspaceItem`].
    pub workspace_name: String,
    pub workspace_group: Option<String>,
    pub tab_label: String,
    pub agent: String,
    /// Custom name from `agent.rename`, e.g. `reviewer`.
    pub name: Option<String>,
    pub agent_state: AgentState,
    pub title: String,
    pub cwd: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneContent {
    pub pane_id: String,
    pub lines: Vec<StyledLine>,
    /// With history: herdr holds older rows than these.
    pub truncated: bool,
    /// History rows asked for, 0 when `lines` is the visible screen only.
    pub history_lines: u32,
    /// The agent's choice question at the bottom, if any (#272).
    pub question: Option<ChoiceQuestion>,
}

/// A question an agent asks with numbered options, such as Claude Code's
/// permission prompt; answered by sending one option's key.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChoiceQuestion {
    pub options: Vec<ChoiceOption>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChoiceOption {
    /// The logical key that selects it, e.g. `2`.
    pub key: String,
    pub label: String,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StyledLine {
    pub spans: Vec<StyledSpan>,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StyledSpan {
    pub text: String,
    /// Terminal columns (wide characters count two).
    pub width: u32,
    pub fg: TermColor,
    pub bg: TermColor,
    pub bold: bool,
    pub dim: bool,
    pub italic: bool,
    pub underline: bool,
    pub inverse: bool,
    pub hidden: bool,
    pub strikethrough: bool,
    /// Web address to open on a click (#186).
    pub link: Option<String>,
}

#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum TermColor {
    Default,
    /// 0-7 normal, 8-15 bright, 16-255 xterm cube and greys.
    Indexed {
        index: u8,
    },
    Rgb {
        r: u8,
        g: u8,
        b: u8,
    },
}

/// `group_by_name` is the host's setting for the "Bereich/Name" convention:
/// off, every space keeps its full label and herdr's order. `sort` orders
/// the spaces on each level of the sidebar. `open_requests` is false for a
/// local host.
pub fn session_update(
    state: &SyncState,
    previous: Option<&SessionState>,
    group_by_name: bool,
    sort: &SpaceSort,
    open_requests: bool,
) -> SessionUpdate {
    let status = match &state.status {
        SyncStatus::Connecting => HostStatus::Connecting,
        SyncStatus::Live => HostStatus::Live,
        SyncStatus::Retrying { attempt, error } => HostStatus::Retrying {
            attempt: *attempt,
            error: error.clone(),
        },
        SyncStatus::HostKeyUnknown { key, fingerprint } => HostStatus::HostKeyUnknown {
            key: key.clone(),
            fingerprint: fingerprint.clone(),
        },
        SyncStatus::HostKeyChanged { key, fingerprint } => HostStatus::HostKeyChanged {
            key: key.clone(),
            fingerprint: fingerprint.clone(),
        },
        SyncStatus::Failed { error } => HostStatus::Failed {
            error: error.clone(),
        },
    };
    let Some(session) = &state.session else {
        return SessionUpdate {
            status,
            server_version: None,
            protocol_supported: true,
            focused_pane_id: None,
            workspaces: Vec::new(),
            space_order: Vec::new(),
            board: Vec::new(),
            attention: Vec::new(),
            open_requests: Vec::new(),
        };
    };

    let arranged = spaces::arrange(&session.workspaces, group_by_name, sort);
    let names: HashMap<&str, (&str, Option<&str>)> = arranged
        .iter()
        .map(|p| (p.workspace.workspace_id.as_str(), (p.name, p.group)))
        .collect();
    let short_name = |workspace_id: &str, label: &str| -> String {
        names
            .get(workspace_id)
            .map_or(label, |(name, _)| name)
            .to_owned()
    };
    let group_of = |workspace_id: &str| -> Option<String> {
        names
            .get(workspace_id)
            .and_then(|(_, group)| group.map(str::to_owned))
    };
    let space_order = arranged
        .iter()
        .map(|p| SpaceSlot {
            workspace_id: p.workspace.workspace_id.clone(),
            nested: p.nested,
        })
        .collect();

    let workspaces = session
        .workspaces
        .iter()
        .map(|ws| WorkspaceItem {
            workspace_id: ws.workspace_id.clone(),
            number: ws.number,
            label: ws.label.clone(),
            name: short_name(&ws.workspace_id, &ws.label),
            group: group_of(&ws.workspace_id),
            focused: ws.focused,
            agent_state: ws.agent_status.into(),
            active_tab_id: ws.active_tab_id.clone(),
            repo_key: ws
                .worktree
                .as_ref()
                .map(|wt| wt.repo_key.clone())
                .filter(|key| !key.is_empty()),
            worktree_name: ws
                .worktree
                .as_ref()
                .filter(|wt| wt.is_linked_worktree)
                .map(|wt| worktree_name(&wt.checkout_path)),
            branch: session.branches.get(&ws.workspace_id).cloned(),
            tokens: ws
                .tokens
                .iter()
                .filter(|(_, value)| !value.is_empty())
                .map(|(name, value)| TokenItem {
                    name: name.clone(),
                    value: value.clone(),
                })
                .collect(),
            tabs: session
                .tabs
                .iter()
                .filter(|tab| tab.workspace_id == ws.workspace_id)
                .map(|tab| TabItem {
                    tab_id: tab.tab_id.clone(),
                    number: tab.number,
                    label: tab.label.clone(),
                    focused: tab.focused,
                    agent_state: tab.agent_status.into(),
                    panes: session
                        .panes
                        .iter()
                        .filter(|pane| pane.tab_id == tab.tab_id)
                        .map(|pane| PaneItem {
                            pane_id: pane.pane_id.clone(),
                            title: title(pane),
                            agent: pane.display_agent.clone().or_else(|| pane.agent.clone()),
                            name: session.agent_names.get(&pane.pane_id).cloned(),
                            agent_state: pane.agent_status.into(),
                            focused: pane.focused,
                        })
                        .collect(),
                    layout: session.layout(&tab.tab_id).map(split_layout),
                })
                .collect(),
        })
        .collect();

    let board: Vec<BoardItem> = session
        .board()
        .into_iter()
        .map(|entry| BoardItem {
            pane_id: entry.pane.pane_id.clone(),
            workspace_id: entry.pane.workspace_id.clone(),
            tab_id: entry.pane.tab_id.clone(),
            workspace_label: entry
                .workspace
                .map(|ws| ws.label.clone())
                .unwrap_or_default(),
            workspace_name: short_name(
                &entry.pane.workspace_id,
                entry.workspace.map_or("", |ws| ws.label.as_str()),
            ),
            workspace_group: group_of(&entry.pane.workspace_id),
            tab_label: entry.tab.map(|tab| tab.label.clone()).unwrap_or_default(),
            agent: entry
                .pane
                .display_agent
                .clone()
                .or_else(|| entry.pane.agent.clone())
                .unwrap_or_default(),
            name: session.agent_names.get(&entry.pane.pane_id).cloned(),
            agent_state: entry.pane.agent_status.into(),
            title: title(entry.pane),
            cwd: entry.pane.cwd.clone(),
        })
        .collect();

    let attention = match previous {
        Some(before) => {
            let panes = session.attention_since(before);
            board
                .iter()
                .filter(|item: &&BoardItem| panes.contains(&item.pane_id))
                .cloned()
                .collect()
        }
        None => Vec::new(),
    };

    let open_requests = if open_requests {
        session
            .open_requests()
            .into_iter()
            .map(|request| {
                let pane = session.pane(&request.pane_id);
                OpenRequest {
                    workspace_label: pane
                        .and_then(|pane| session.workspace(&pane.workspace_id))
                        .map(|ws| ws.label.clone())
                        .unwrap_or_default(),
                    pane_title: pane.map(title).unwrap_or_default(),
                    local_address: crate::forward::local_port(&request.url).is_some(),
                    pane_id: request.pane_id,
                    request_id: request.open_id,
                    url: request.url,
                }
            })
            .collect()
    } else {
        Vec::new()
    };

    SessionUpdate {
        status,
        attention,
        open_requests,
        server_version: Some(session.version.clone()),
        protocol_supported: session.protocol == herdr_proto::SUPPORTED_PROTOCOL,
        focused_pane_id: session.focused_pane_id.clone(),
        workspaces,
        space_order,
        board,
    }
}

pub fn pane_content(screen: &PaneScreen) -> PaneContent {
    PaneContent {
        pane_id: screen.pane_id.clone(),
        lines: screen
            .screen
            .lines
            .iter()
            .map(|line| StyledLine {
                spans: line.spans.iter().map(styled_span).collect(),
            })
            .collect(),
        truncated: screen.truncated,
        history_lines: screen.history_lines,
        question: choice_question(&screen.screen),
    }
}

/// The choice question at the bottom of a screen, see
/// [`herdr_core::question`].
pub fn choice_question(screen: &Screen) -> Option<ChoiceQuestion> {
    let choices = question::detect(screen)?;
    Some(ChoiceQuestion {
        options: choices
            .into_iter()
            .map(|choice| ChoiceOption {
                key: choice.number.to_string(),
                label: choice.label,
            })
            .collect(),
    })
}

fn styled_span(span: &Span) -> StyledSpan {
    let style = span.style;
    StyledSpan {
        text: span.text.clone(),
        width: u32::try_from(span.width()).unwrap_or(u32::MAX),
        fg: style.fg.into(),
        bg: style.bg.into(),
        bold: style.bold,
        dim: style.dim,
        italic: style.italic,
        underline: style.underline,
        inverse: style.inverse,
        hidden: style.hidden,
        strikethrough: style.strikethrough,
        link: span.link.clone(),
    }
}

fn split_layout(layout: &TabLayout) -> SplitLayout {
    let area = layout.area;
    SplitLayout {
        columns: area.width.into(),
        rows: area.height.into(),
        zoomed: layout.zoomed,
        panes: layout
            .panes
            .iter()
            .map(|pane| PaneFrame {
                pane_id: pane.pane_id.clone(),
                x: pane.rect.x.saturating_sub(area.x).into(),
                y: pane.rect.y.saturating_sub(area.y).into(),
                width: pane.rect.width.into(),
                height: pane.rect.height.into(),
            })
            .collect(),
    }
}

/// Last path component of a worktree checkout.
fn worktree_name(checkout_path: &str) -> String {
    checkout_path
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or(checkout_path)
        .to_owned()
}

/// What to call a pane: its label, else the terminal title, else the cwd.
fn title(pane: &PaneInfo) -> String {
    pane.label
        .clone()
        .or_else(|| pane.terminal_title_stripped.clone())
        .or_else(|| pane.title.clone())
        .or_else(|| pane.cwd.clone())
        .unwrap_or_default()
}

impl From<AgentStatus> for AgentState {
    fn from(status: AgentStatus) -> Self {
        match status {
            AgentStatus::Idle => Self::Idle,
            AgentStatus::Working => Self::Working,
            AgentStatus::Blocked => Self::Blocked,
            AgentStatus::Done => Self::Done,
            AgentStatus::Unknown => Self::Unknown,
        }
    }
}

impl From<Color> for TermColor {
    fn from(color: Color) -> Self {
        match color {
            Color::Default => Self::Default,
            Color::Indexed(index) => Self::Indexed { index },
            Color::Rgb(r, g, b) => Self::Rgb { r, g, b },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use herdr_proto::{CellRect, LayoutPane};

    #[test]
    fn frames_are_relative_to_the_area() {
        let rect = |x, y, width, height| CellRect {
            x,
            y,
            width,
            height,
        };
        let pane = |id: &str, rect| LayoutPane {
            pane_id: id.to_owned(),
            focused: false,
            rect,
        };
        let layout = TabLayout {
            workspace_id: "w1".into(),
            tab_id: "w1:t1".into(),
            zoomed: true,
            area: rect(2, 1, 120, 40),
            focused_pane_id: "w1:p2".into(),
            panes: vec![
                pane("w1:p1", rect(2, 1, 60, 40)),
                pane("w1:p2", rect(62, 1, 60, 40)),
            ],
            splits: Vec::new(),
        };
        let split = split_layout(&layout);
        assert_eq!((split.columns, split.rows, split.zoomed), (120, 40, true));
        let second = &split.panes[1];
        assert_eq!(
            (second.pane_id.as_str(), second.x, second.y, second.width),
            ("w1:p2", 60, 0, 60)
        );
    }

    #[test]
    fn worktree_name_is_the_checkout_directory() {
        assert_eq!(
            worktree_name("/Users/x/dev/enon/.worktrees/docs-herdr-remote"),
            "docs-herdr-remote"
        );
        assert_eq!(worktree_name("/srv/repo/"), "repo");
    }
}
