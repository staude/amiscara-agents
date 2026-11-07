//! What the apps show, built from the core's session state: plain,
//! serialisable records (the desktop app sends them to its web view,
//! herdr-ffi exposes the same types to Swift as UniFFI remote types).

use std::collections::HashMap;

use herdr_client::SessionState;
use herdr_client::chains;
use herdr_client::pane::PaneScreen;
use herdr_client::programs::{self, ProgramMatch};
use herdr_client::question;
use herdr_client::spaces::{self, SpaceSort};
use herdr_client::sync::{SyncState, SyncStatus};
use herdr_client::terminal::{Color, Screen, Span};
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
    /// Folders agents on the host want opened in VS Code (#288), pending
    /// ones as for `open_requests`; always empty for a local host, where
    /// the `code` stand-in opens VS Code itself.
    pub editor_requests: Vec<EditorRequest>,
    /// What chains this device ran since the previous update (#300); empty
    /// unless the session runs chains, see `Session::set_chain_runner`.
    pub chain_results: Vec<ChainResult>,
}

/// When a chain sends its prompt (#300).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ChainTrigger {
    /// The agent finished.
    Done,
    /// The agent waits for an answer.
    Blocked,
}

impl From<chains::ChainTrigger> for ChainTrigger {
    fn from(trigger: chains::ChainTrigger) -> Self {
        match trigger {
            chains::ChainTrigger::Done => Self::Done,
            chains::ChainTrigger::Blocked => Self::Blocked,
        }
    }
}

impl From<ChainTrigger> for chains::ChainTrigger {
    fn from(trigger: ChainTrigger) -> Self {
        match trigger {
            ChainTrigger::Done => Self::Done,
            ChainTrigger::Blocked => Self::Blocked,
        }
    }
}

/// A chain of an agent, see [`BoardItem::chains`].
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChainItem {
    /// Pass it back to `remove_chain`.
    pub id: String,
    pub trigger: ChainTrigger,
    /// Runs on every matching change; otherwise it is removed once sent.
    pub repeat: bool,
    /// The target was gone or refused the prompt; it never runs again.
    pub failed: bool,
    pub target_pane_id: String,
    /// The target agent's name, else its kind and tab; empty when the
    /// pane is gone.
    pub target_label: String,
    pub text: String,
}

/// What became of a chain when its agent changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ChainOutcome {
    Sent,
    /// Nothing sent; the chain is marked failed and stays so.
    Failed,
    /// Nothing sent, e.g. the agent changed again in the meantime; the
    /// chain stays as it was.
    Skipped,
}

/// One run of a chain on this device, for the app's log.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChainResult {
    pub chain_id: String,
    pub trigger_pane_id: String,
    /// Name of the agent whose change fired it, as for [`ChainItem::target_label`].
    pub trigger_label: String,
    pub target_label: String,
    pub text: String,
    pub outcome: ChainOutcome,
    pub reason: Option<String>,
    /// Unix milliseconds.
    pub at_ms: u64,
}

/// A folder an agent on the host wants opened in VS Code, see
/// [`SessionUpdate::editor_requests`].
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorRequest {
    pub pane_id: String,
    /// Pass it back to `dismiss_editor_request`.
    pub request_id: String,
    /// Absolute path on the host.
    pub path: String,
    pub workspace_label: String,
    pub pane_title: String,
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
    /// Folder name of the repository's main checkout, e.g. `amiscara-agents`;
    /// the same for all its worktrees.
    pub repo_name: Option<String>,
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
    /// What runs in the pane, for its icon (#337); `None` while unknown.
    pub program: Option<ProgramItem>,
}

/// A program for an icon (#337). `id` names a table entry
/// (`herdr_client::programs`); `other` is a process missing from the table,
/// `agent` an agent kind missing from it, both with `known: false`.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProgramItem {
    pub id: String,
    pub name: String,
    /// `#RRGGBB`.
    pub color: String,
    pub known: bool,
}

/// Colour of a program missing from the table.
const UNKNOWN_PROGRAM_COLOR: &str = "#8E8E93";

/// The program of one pane: the agent kind herdr reports (the raw `agent`,
/// since `display_agent` may carry a status text), else what the sync
/// driver found among the foreground processes.
fn program_item(session: &SessionState, pane: &PaneInfo) -> Option<ProgramItem> {
    if let Some(kind) = pane.agent.as_deref().filter(|kind| !kind.is_empty()) {
        return Some(match programs::for_agent(kind) {
            Some(program) => known_program(program),
            None => ProgramItem {
                id: "agent".into(),
                name: kind.to_owned(),
                color: UNKNOWN_PROGRAM_COLOR.into(),
                known: false,
            },
        });
    }
    Some(match session.programs.get(&pane.pane_id)? {
        ProgramMatch::Known(program) => known_program(program),
        ProgramMatch::Unknown(name) => ProgramItem {
            id: "other".into(),
            name: name.clone(),
            color: UNKNOWN_PROGRAM_COLOR.into(),
            known: false,
        },
    })
}

fn known_program(program: &programs::Program) -> ProgramItem {
    ProgramItem {
        id: program.id.into(),
        name: program.name.into(),
        color: program.color.into(),
        known: true,
    }
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
    /// Since when the agent is in its state, in Unix milliseconds, as this
    /// session saw it change; `None` for agents already in that state when
    /// the session started. herdr does not report this time itself.
    pub state_since_ms: Option<u64>,
    /// Prompts that follow this agent's change (#300), stored on the host.
    pub chains: Vec<ChainItem>,
    /// The agent as a program, for its icon (#337).
    pub program: Option<ProgramItem>,
}

/// Remembers since when each agent pane is in its state, across updates of
/// one session, and fills [`BoardItem::state_since_ms`].
#[derive(Debug, Default)]
pub(crate) struct StateClock {
    seen: HashMap<String, (AgentState, Option<u64>)>,
    stamped: bool,
}

impl StateClock {
    /// Stamps `board` with the remembered times; a pane that is new or
    /// changed its state gets `now_ms`, except on the first call, when the
    /// time of the states already shown is unknown. `attention` holds
    /// entries of `board` and gets the same times.
    pub(crate) fn stamp(
        &mut self,
        board: &mut [BoardItem],
        attention: &mut [BoardItem],
        now_ms: u64,
    ) {
        let mut seen = HashMap::with_capacity(board.len());
        for item in board.iter_mut() {
            let since = match self.seen.get(&item.pane_id) {
                Some((state, since)) if *state == item.agent_state => *since,
                _ if self.stamped => Some(now_ms),
                _ => None,
            };
            item.state_since_ms = since;
            seen.insert(item.pane_id.clone(), (item.agent_state, since));
        }
        for item in attention.iter_mut() {
            item.state_since_ms = seen.get(&item.pane_id).and_then(|(_, since)| *since);
        }
        self.seen = seen;
        self.stamped = true;
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
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
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChoiceQuestion {
    pub options: Vec<ChoiceOption>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChoiceOption {
    /// The logical key that selects it, e.g. `2`.
    pub key: String,
    pub label: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StyledLine {
    pub spans: Vec<StyledSpan>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
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
    /// herdr-core terminal address as written (`t7`, `vps/t7`, #331); the
    /// app links it only to a terminal that lives. Missing in screens saved
    /// before it.
    #[serde(default)]
    pub terminal: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
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

/// A pane's screen as JSON, for the app to keep the last one on the
/// device (#276).
pub fn pane_content_to_json(content: &PaneContent) -> String {
    serde_json::to_string(content).expect("pane content serializes")
}

/// The screen from [`pane_content_to_json`]; `None` for anything else,
/// e.g. a file written by another version.
pub fn pane_content_from_json(json: &str) -> Option<PaneContent> {
    serde_json::from_str(json).ok()
}

/// herdr's status of a tab or space, except that `done` turns into the
/// most urgent status of its agents when none of them is still unseen done
/// (#335), `idle` without agents.
fn group_status(
    session: &SessionState,
    reported: AgentStatus,
    member: impl Fn(&PaneInfo) -> bool,
) -> AgentStatus {
    if reported != AgentStatus::Done {
        return reported;
    }
    let shown: Vec<AgentStatus> = session
        .panes
        .iter()
        .filter(|pane| pane.agent.is_some() && member(pane))
        .map(|pane| session.agent_status(pane))
        .collect();
    [
        AgentStatus::Done,
        AgentStatus::Blocked,
        AgentStatus::Working,
    ]
    .into_iter()
    .find(|status| shown.contains(status))
    .unwrap_or(AgentStatus::Idle)
}

/// `group_by_name` is the host's setting for the "Bereich/Name" convention:
/// off, every space keeps its full label and herdr's order. `sort` orders
/// the spaces on each level of the sidebar. `open_requests` is false for a
/// local host; it covers editor requests too.
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
            editor_requests: Vec::new(),
            chain_results: Vec::new(),
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
            agent_state: group_status(session, ws.agent_status, |pane| {
                pane.workspace_id == ws.workspace_id
            })
            .into(),
            active_tab_id: ws.active_tab_id.clone(),
            repo_key: ws
                .worktree
                .as_ref()
                .map(|wt| wt.repo_key.clone())
                .filter(|key| !key.is_empty()),
            repo_name: ws
                .worktree
                .as_ref()
                .map(|wt| wt.repo_name.clone())
                .filter(|name| !name.is_empty()),
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
                    agent_state: group_status(session, tab.agent_status, |pane| {
                        pane.tab_id == tab.tab_id
                    })
                    .into(),
                    panes: session
                        .panes
                        .iter()
                        .filter(|pane| pane.tab_id == tab.tab_id)
                        .map(|pane| PaneItem {
                            pane_id: pane.pane_id.clone(),
                            title: title(pane),
                            agent: pane.display_agent.clone().or_else(|| pane.agent.clone()),
                            name: session.agent_names.get(&pane.pane_id).cloned(),
                            agent_state: session.agent_status(pane).into(),
                            focused: pane.focused,
                            program: program_item(session, pane),
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
            agent_state: session.agent_status(entry.pane).into(),
            title: title(entry.pane),
            cwd: entry.pane.cwd.clone(),
            state_since_ms: None,
            chains: chains::chains_of(entry.pane)
                .into_iter()
                .map(|chain| chain_item(session, chain))
                .collect(),
            program: program_item(session, entry.pane),
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

    let editor_requests = if open_requests {
        session
            .editor_requests()
            .into_iter()
            .map(|request| {
                let pane = session.pane(&request.pane_id);
                EditorRequest {
                    workspace_label: pane
                        .and_then(|pane| session.workspace(&pane.workspace_id))
                        .map(|ws| ws.label.clone())
                        .unwrap_or_default(),
                    pane_title: pane.map(title).unwrap_or_default(),
                    pane_id: request.pane_id,
                    request_id: request.editor_id,
                    path: request.path,
                }
            })
            .collect()
    } else {
        Vec::new()
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
        editor_requests,
        chain_results: Vec::new(),
        server_version: Some(session.version.clone()),
        // herdr-core alone has no herdr protocol to check (#329).
        protocol_supported: !session.backends.herdr
            || session.protocol == herdr_proto::SUPPORTED_PROTOCOL,
        focused_pane_id: session.focused_pane_id.clone(),
        workspaces,
        space_order,
        board,
    }
}

/// A chain as the apps show it.
pub fn chain_item(session: &SessionState, chain: chains::Chain) -> ChainItem {
    ChainItem {
        target_label: pane_label(session, &chain.target_pane_id),
        id: chain.id,
        trigger: chain.trigger.into(),
        repeat: chain.repeat,
        failed: chain.failed,
        target_pane_id: chain.target_pane_id,
        text: chain.text,
    }
}

/// What to call an agent pane in a chain: its name, else its kind and
/// tab, e.g. `claude · Tab 2`; empty when the pane is gone.
pub fn pane_label(session: &SessionState, pane_id: &str) -> String {
    if let Some(name) = session.agent_names.get(pane_id) {
        return name.clone();
    }
    let Some(pane) = session.pane(pane_id) else {
        return String::new();
    };
    let kind = pane
        .display_agent
        .clone()
        .or_else(|| pane.agent.clone())
        .unwrap_or_else(|| title(pane));
    match session.tab(&pane.tab_id) {
        Some(tab) => format!("{kind} · Tab {}", tab.label),
        None => kind,
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
/// [`herdr_client::question`].
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
        terminal: span.terminal.clone(),
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

    fn board_item(pane_id: &str, agent_state: AgentState) -> BoardItem {
        BoardItem {
            pane_id: pane_id.to_owned(),
            workspace_id: "w1".into(),
            tab_id: "w1:t1".into(),
            workspace_label: "space".into(),
            workspace_name: "space".into(),
            workspace_group: None,
            tab_label: "tab".into(),
            agent: "claude".into(),
            name: None,
            agent_state,
            title: String::new(),
            cwd: None,
            state_since_ms: None,
            chains: Vec::new(),
            program: None,
        }
    }

    fn stamped(clock: &mut StateClock, board: &[(&str, AgentState)], now: u64) -> Vec<Option<u64>> {
        let mut items: Vec<BoardItem> = board
            .iter()
            .map(|(id, state)| board_item(id, *state))
            .collect();
        clock.stamp(&mut items, &mut [], now);
        items.iter().map(|item| item.state_since_ms).collect()
    }

    #[test]
    fn the_first_stamp_knows_no_times() {
        let mut clock = StateClock::default();
        let board = [("p1", AgentState::Blocked), ("p2", AgentState::Working)];
        assert_eq!(stamped(&mut clock, &board, 100), [None, None]);
        assert_eq!(stamped(&mut clock, &board, 200), [None, None]);
    }

    #[test]
    fn a_changed_state_gets_the_time_and_keeps_it() {
        let mut clock = StateClock::default();
        stamped(&mut clock, &[("p1", AgentState::Working)], 100);
        assert_eq!(
            stamped(&mut clock, &[("p1", AgentState::Blocked)], 200),
            [Some(200)]
        );
        assert_eq!(
            stamped(&mut clock, &[("p1", AgentState::Blocked)], 300),
            [Some(200)]
        );
    }

    #[test]
    fn a_pane_that_comes_back_starts_anew() {
        let mut clock = StateClock::default();
        stamped(&mut clock, &[("p1", AgentState::Done)], 100);
        assert_eq!(
            stamped(&mut clock, &[("p2", AgentState::Working)], 200),
            [Some(200)]
        );
        assert_eq!(
            stamped(
                &mut clock,
                &[("p1", AgentState::Done), ("p2", AgentState::Working)],
                300
            ),
            [Some(300), Some(200)]
        );
    }

    #[test]
    fn attention_gets_the_time_of_its_board_entry() {
        let mut clock = StateClock::default();
        stamped(&mut clock, &[("p1", AgentState::Working)], 100);
        let mut board = vec![board_item("p1", AgentState::Done)];
        let mut attention = board.clone();
        clock.stamp(&mut board, &mut attention, 200);
        assert_eq!(attention[0].state_since_ms, Some(200));
    }

    /// One space with two tabs: `t1` holds a done agent in finish 4 with
    /// the seen mark `mark`, `t2` an unseen done agent unless `second_done`
    /// is false. herdr reports both tabs and the space as done.
    fn seen_update(mark: Option<&str>, second_done: bool) -> SessionUpdate {
        let tokens = mark.map_or_else(|| serde_json::json!({}), |m| serde_json::json!({"seen": m}));
        let second = if second_done { "done" } else { "working" };
        let snapshot = serde_json::json!({
            "version": "0.9.5", "protocol": 22,
            "workspaces": [{"workspace_id": "w1", "number": 1, "label": "web",
                            "agent_status": "done", "active_tab_id": "w1:t1"}],
            "tabs": [
                {"tab_id": "w1:t1", "workspace_id": "w1", "number": 1, "label": "1", "agent_status": "done"},
                {"tab_id": "w1:t2", "workspace_id": "w1", "number": 2, "label": "2", "agent_status": second}
            ],
            "panes": [
                {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
                 "agent": "claude", "agent_status": "done", "tokens": tokens},
                {"pane_id": "w1:p2", "workspace_id": "w1", "tab_id": "w1:t2",
                 "agent": "codex", "agent_status": second}
            ],
            "agents": [{"pane_id": "w1:p1", "agent_status": "done",
                        "state_change_seq": 4, "completion_seq": 4}]
        });
        let snapshot = serde_json::from_value(snapshot).expect("snapshot");
        let state = SyncState {
            status: SyncStatus::Live,
            session: Some(std::sync::Arc::new(SessionState::from_snapshot(snapshot))),
            ..SyncState::default()
        };
        session_update(&state, None, false, &SpaceSort::default(), false)
    }

    fn states(
        update: &SessionUpdate,
    ) -> (
        AgentState,
        Vec<AgentState>,
        Vec<AgentState>,
        Vec<AgentState>,
    ) {
        let ws = &update.workspaces[0];
        (
            ws.agent_state,
            ws.tabs.iter().map(|tab| tab.agent_state).collect(),
            ws.tabs
                .iter()
                .flat_map(|tab| &tab.panes)
                .map(|pane| pane.agent_state)
                .collect(),
            update.board.iter().map(|item| item.agent_state).collect(),
        )
    }

    #[test]
    fn a_seen_finish_shows_as_idle_everywhere() {
        use AgentState::{Done, Idle, Working};
        // Unseen: as herdr reports it.
        assert_eq!(
            states(&seen_update(None, false)),
            (
                Done,
                vec![Done, Working],
                vec![Done, Working],
                vec![Working, Done]
            )
        );
        // Seen: pane, board and tab turn idle, the space shows its
        // working agent.
        assert_eq!(
            states(&seen_update(Some("4"), false)),
            (
                Working,
                vec![Idle, Working],
                vec![Idle, Working],
                vec![Working, Idle]
            )
        );
        // A mark for an older finish counts for nothing.
        assert_eq!(
            states(&seen_update(Some("3"), false)).1,
            vec![Done, Working]
        );
        // Another unseen finish keeps the space done.
        assert_eq!(
            states(&seen_update(Some("4"), true)),
            (Done, vec![Idle, Done], vec![Idle, Done], vec![Done, Idle])
        );
    }

    #[test]
    fn program_comes_from_the_raw_agent_kind_or_the_processes() {
        let snapshot: herdr_proto::SessionSnapshot = serde_json::from_value(serde_json::json!({
            "version": "0.9.5", "protocol": 22, "workspaces": [], "tabs": [],
            "panes": [
                {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
                 "agent": "claude", "display_agent": "📋 #337 · planning"},
                {"pane_id": "w1:p2", "workspace_id": "w1", "tab_id": "w1:t1", "agent": "hal"},
                {"pane_id": "w1:p3", "workspace_id": "w1", "tab_id": "w1:t1"},
                {"pane_id": "w1:p4", "workspace_id": "w1", "tab_id": "w1:t1"},
                {"pane_id": "w1:p5", "workspace_id": "w1", "tab_id": "w1:t1"}
            ]
        }))
        .expect("snapshot");
        let mut session = SessionState::from_snapshot(snapshot);
        let vim = programs::all().iter().find(|p| p.id == "vim").expect("vim");
        session
            .programs
            .insert("w1:p3".into(), ProgramMatch::Known(vim));
        session
            .programs
            .insert("w1:p4".into(), ProgramMatch::Unknown("caffeinate".into()));
        let item = |id: &str| program_item(&session, session.pane(id).expect("pane"));

        let claude = item("w1:p1").expect("claude");
        assert_eq!((claude.id.as_str(), claude.known), ("claude", true));
        let hal = item("w1:p2").expect("agent");
        assert_eq!(
            (hal.id.as_str(), hal.name.as_str(), hal.known),
            ("agent", "hal", false)
        );
        let vim = item("w1:p3").expect("vim");
        assert_eq!((vim.id.as_str(), vim.color.as_str()), ("vim", "#019733"));
        let other = item("w1:p4").expect("other");
        assert_eq!(
            (other.id.as_str(), other.name.as_str(), other.known),
            ("other", "caffeinate", false)
        );
        assert_eq!(item("w1:p5"), None);
    }

    #[test]
    fn worktree_name_is_the_checkout_directory() {
        assert_eq!(
            worktree_name("/Users/x/dev/enon/.worktrees/docs-herdr-remote"),
            "docs-herdr-remote"
        );
        assert_eq!(worktree_name("/srv/repo/"), "repo");
    }
    #[test]
    fn pane_content_survives_json() {
        let span = |text: &str, fg, bg, link: Option<&str>| StyledSpan {
            text: text.to_owned(),
            width: text.chars().count() as u32,
            fg,
            bg,
            bold: true,
            dim: false,
            italic: true,
            underline: false,
            inverse: true,
            hidden: false,
            strikethrough: true,
            link: link.map(str::to_owned),
            terminal: link.is_none().then(|| "vps/t7".to_owned()),
        };
        let content = PaneContent {
            pane_id: "w1:p2".into(),
            lines: vec![
                StyledLine {
                    spans: vec![
                        span(
                            "plain",
                            TermColor::Default,
                            TermColor::Indexed { index: 12 },
                            None,
                        ),
                        span(
                            "link",
                            TermColor::Rgb { r: 1, g: 2, b: 3 },
                            TermColor::Default,
                            Some("https://example.com"),
                        ),
                    ],
                },
                StyledLine { spans: Vec::new() },
            ],
            truncated: true,
            history_lines: 200,
            question: Some(ChoiceQuestion {
                options: vec![ChoiceOption {
                    key: "1".into(),
                    label: "Yes".into(),
                }],
            }),
        };
        let back = pane_content_from_json(&pane_content_to_json(&content)).expect("round trip");
        assert_eq!(back.pane_id, "w1:p2");
        assert_eq!((back.truncated, back.history_lines), (true, 200));
        assert_eq!(back.lines.len(), 2);
        assert_eq!(back.question, content.question);
        assert!(back.lines[1].spans.is_empty());
        let spans = &back.lines[0].spans;
        assert_eq!(spans[0].fg, TermColor::Default);
        assert_eq!(spans[0].bg, TermColor::Indexed { index: 12 });
        assert_eq!(spans[1].fg, TermColor::Rgb { r: 1, g: 2, b: 3 });
        assert_eq!(spans[1].link.as_deref(), Some("https://example.com"));
        assert_eq!(spans[0].link, None);
        assert_eq!(spans[0].terminal.as_deref(), Some("vps/t7"));
        assert_eq!(spans[1].terminal, None);
        assert!(spans[1].bold && spans[1].italic && spans[1].inverse && spans[1].strikethrough);
        assert!(!spans[1].dim && !spans[1].underline && !spans[1].hidden);
        assert_eq!((spans[0].text.as_str(), spans[0].width), ("plain", 5));
    }

    #[test]
    fn saved_span_without_terminal_reads() {
        let json = r#"{"paneId":"w1:p1","lines":[{"spans":[{"text":"a","width":1,
            "fg":{"kind":"default"},"bg":{"kind":"default"},"bold":false,"dim":false,
            "italic":false,"underline":false,"inverse":false,"hidden":false,
            "strikethrough":false,"link":null}]}],"truncated":false,"historyLines":0,
            "question":null}"#;
        let content = pane_content_from_json(json).expect("old screen");
        assert_eq!(content.lines[0].spans[0].terminal, None);
    }

    #[test]
    fn broken_pane_json_is_none() {
        assert!(pane_content_from_json("").is_none());
        assert!(pane_content_from_json("{\"paneId\": 3}").is_none());
    }
}
