//! Plain records for the app, built from the core types.

use herdr_core::SessionState;
use herdr_core::pane::PaneScreen;
use herdr_core::sync::{SyncState, SyncStatus};
use herdr_core::terminal::{Color, Span};
use herdr_proto::{AgentStatus, PaneInfo, TabLayout};

#[derive(Debug, Clone, uniffi::Enum)]
pub enum HostStatus {
    Connecting,
    Live,
    Retrying { attempt: u32, error: String },
    HostKeyUnknown { key: String, fingerprint: String },
    HostKeyChanged { key: String, fingerprint: String },
    Failed { error: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AgentState {
    Idle,
    Working,
    Blocked,
    Done,
    Unknown,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SessionUpdate {
    pub status: HostStatus,
    /// `None` until the first snapshot arrived.
    pub server_version: Option<String>,
    /// False when the server speaks a protocol this build does not know.
    pub protocol_supported: bool,
    pub focused_pane_id: Option<String>,
    pub workspaces: Vec<WorkspaceItem>,
    /// Agent panes, most urgent first.
    pub board: Vec<BoardItem>,
    /// Agents that started waiting or finished since the previous update;
    /// empty on the first update after start. For notifications.
    pub attention: Vec<BoardItem>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct WorkspaceItem {
    pub workspace_id: String,
    pub number: u32,
    pub label: String,
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

#[derive(Debug, Clone, uniffi::Record)]
pub struct TokenItem {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, uniffi::Record)]
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
#[derive(Debug, Clone, uniffi::Record)]
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
#[derive(Debug, Clone, uniffi::Record)]
pub struct PaneFrame {
    pub pane_id: String,
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PaneItem {
    pub pane_id: String,
    pub title: String,
    /// `None` for a plain shell.
    pub agent: Option<String>,
    pub agent_state: AgentState,
    pub focused: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct BoardItem {
    pub pane_id: String,
    pub workspace_id: String,
    pub tab_id: String,
    pub workspace_label: String,
    pub tab_label: String,
    pub agent: String,
    pub agent_state: AgentState,
    pub title: String,
    pub cwd: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PaneContent {
    pub pane_id: String,
    pub lines: Vec<StyledLine>,
    pub truncated: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct StyledLine {
    pub spans: Vec<StyledSpan>,
}

#[derive(Debug, Clone, uniffi::Record)]
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
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
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

pub fn session_update(state: &SyncState, previous: Option<&SessionState>) -> SessionUpdate {
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
            board: Vec::new(),
            attention: Vec::new(),
        };
    };

    let workspaces = session
        .workspaces
        .iter()
        .map(|ws| WorkspaceItem {
            workspace_id: ws.workspace_id.clone(),
            number: ws.number,
            label: ws.label.clone(),
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
            tab_label: entry.tab.map(|tab| tab.label.clone()).unwrap_or_default(),
            agent: entry
                .pane
                .display_agent
                .clone()
                .or_else(|| entry.pane.agent.clone())
                .unwrap_or_default(),
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

    SessionUpdate {
        status,
        attention,
        server_version: Some(session.version.clone()),
        protocol_supported: session.protocol == herdr_proto::SUPPORTED_PROTOCOL,
        focused_pane_id: session.focused_pane_id.clone(),
        workspaces,
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
    }
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
