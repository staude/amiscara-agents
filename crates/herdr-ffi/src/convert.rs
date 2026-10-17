//! Plain records for the app, built from the core types.

use herdr_core::pane::PaneScreen;
use herdr_core::sync::{SyncState, SyncStatus};
use herdr_core::terminal::{Color, Span};
use herdr_proto::{AgentStatus, PaneInfo};

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
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct WorkspaceItem {
    pub workspace_id: String,
    pub number: u32,
    pub label: String,
    pub focused: bool,
    pub agent_state: AgentState,
    pub tabs: Vec<TabItem>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TabItem {
    pub tab_id: String,
    pub number: u32,
    pub label: String,
    pub focused: bool,
    pub agent_state: AgentState,
    pub panes: Vec<PaneItem>,
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

pub fn session_update(state: &SyncState) -> SessionUpdate {
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
                })
                .collect(),
        })
        .collect();

    let board = session
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

    SessionUpdate {
        status,
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
