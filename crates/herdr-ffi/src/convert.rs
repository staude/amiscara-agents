//! The records of `herdr_session::view`, exposed to Swift as UniFFI remote
//! types: same names and fields, so the Swift side is unchanged.

pub use herdr_session::view::{
    AgentState, BoardItem, ChainItem, ChainOutcome, ChainResult, ChainTrigger, ChoiceOption,
    ChoiceQuestion, EditorRequest, HostStatus, OpenRequest, PaneContent, PaneFrame, PaneItem,
    SessionUpdate, SpaceSlot, SplitLayout, StyledLine, StyledSpan, TabItem, TermColor, TokenItem,
    WorkspaceItem,
};

#[uniffi::remote(Enum)]
pub enum HostStatus {
    Connecting,
    Live,
    Retrying { attempt: u32, error: String },
    HostKeyUnknown { key: String, fingerprint: String },
    HostKeyChanged { key: String, fingerprint: String },
    Failed { error: String },
}

#[uniffi::remote(Enum)]
pub enum AgentState {
    Idle,
    Working,
    Blocked,
    Done,
    Unknown,
}

#[uniffi::remote(Record)]
pub struct SessionUpdate {
    pub status: HostStatus,
    /// `None` until the first snapshot arrived.
    pub server_version: Option<String>,
    /// False when the server speaks a protocol this build does not know.
    pub protocol_supported: bool,
    pub focused_pane_id: Option<String>,
    pub workspaces: Vec<WorkspaceItem>,
    /// The spaces in sidebar order: herdr's, with linked worktrees under
    /// their repository and spaces of one name group next to each other.
    pub space_order: Vec<SpaceSlot>,
    /// Agent panes, most urgent first.
    pub board: Vec<BoardItem>,
    /// Agents that started waiting or finished since the previous update;
    /// empty on the first update after start. For notifications.
    pub attention: Vec<BoardItem>,
    /// Pages agents on the host want opened (#247), all pending ones;
    /// always empty for a local host.
    pub open_requests: Vec<OpenRequest>,
    /// Folders agents on the host want opened in VS Code (#288), all
    /// pending ones; always empty for a local host.
    pub editor_requests: Vec<EditorRequest>,
    /// What chains this device ran since the previous update (#300);
    /// empty unless `set_chain_runner` named a device.
    pub chain_results: Vec<ChainResult>,
}

/// When a chain sends its prompt (#300).
#[uniffi::remote(Enum)]
pub enum ChainTrigger {
    Done,
    Blocked,
}

/// A chain of an agent, stored on the host.
#[uniffi::remote(Record)]
pub struct ChainItem {
    /// Pass it back to `remove_chain`.
    pub id: String,
    pub trigger: ChainTrigger,
    /// Runs on every matching change; otherwise it is removed once sent.
    pub repeat: bool,
    /// The target was gone or refused the prompt; it never runs again.
    pub failed: bool,
    pub target_pane_id: String,
    /// The target agent's name, else its kind and tab; empty when gone.
    pub target_label: String,
    pub text: String,
}

#[uniffi::remote(Enum)]
pub enum ChainOutcome {
    Sent,
    Failed,
    Skipped,
}

/// One run of a chain on this device, for the app's log.
#[uniffi::remote(Record)]
pub struct ChainResult {
    pub chain_id: String,
    pub trigger_pane_id: String,
    pub trigger_label: String,
    pub target_label: String,
    pub text: String,
    pub outcome: ChainOutcome,
    pub reason: Option<String>,
    /// Unix milliseconds.
    pub at_ms: u64,
}

/// A folder an agent on the host wants opened in VS Code.
#[uniffi::remote(Record)]
pub struct EditorRequest {
    pub pane_id: String,
    /// Pass it back to `dismiss_editor_request`.
    pub request_id: String,
    /// Absolute path on the host.
    pub path: String,
    pub workspace_label: String,
    pub pane_title: String,
}

/// A page an agent on the host wants opened.
#[uniffi::remote(Record)]
pub struct OpenRequest {
    pub pane_id: String,
    /// Pass it back to `dismiss_open_request`.
    pub request_id: String,
    pub url: String,
    pub workspace_label: String,
    pub pane_title: String,
    /// The URL points at the host itself; `open_url` forwards it.
    pub local_address: bool,
}

/// One place in the sidebar's list of spaces.
#[uniffi::remote(Record)]
pub struct SpaceSlot {
    pub workspace_id: String,
    /// A linked worktree shown indented under its repository's space.
    pub nested: bool,
}

#[uniffi::remote(Record)]
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

#[uniffi::remote(Record)]
pub struct TokenItem {
    pub name: String,
    pub value: String,
}

#[uniffi::remote(Record)]
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
#[uniffi::remote(Record)]
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
#[uniffi::remote(Record)]
pub struct PaneFrame {
    pub pane_id: String,
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[uniffi::remote(Record)]
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

#[uniffi::remote(Record)]
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
    /// Since when the agent is in its state, in Unix milliseconds; `None`
    /// when it already was in it as the session started.
    pub state_since_ms: Option<u64>,
    /// Prompts that follow this agent's change (#300).
    pub chains: Vec<ChainItem>,
}

#[uniffi::remote(Record)]
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

#[uniffi::remote(Record)]
pub struct ChoiceQuestion {
    pub options: Vec<ChoiceOption>,
}

#[uniffi::remote(Record)]
pub struct ChoiceOption {
    /// The logical key that selects it, e.g. `2`.
    pub key: String,
    pub label: String,
}

#[uniffi::remote(Record)]
pub struct StyledLine {
    pub spans: Vec<StyledSpan>,
}

#[uniffi::remote(Record)]
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

#[uniffi::remote(Enum)]
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

pub use herdr_session::{
    ClaudeSessionItem, ScrollStep, TranscriptCursor, TranscriptEntry, TranscriptKind,
    TranscriptPage,
};

/// A step through a full-screen agent's own view.
#[uniffi::remote(Enum)]
pub enum ScrollStep {
    /// Half a screen up.
    PageUp,
    PageDown,
    /// Back to the newest output, which the agent then follows again.
    Bottom,
}

/// Who wrote an entry of a Claude Code conversation.
#[uniffi::remote(Enum)]
pub enum TranscriptKind {
    User,
    Assistant,
    Tool,
}

#[uniffi::remote(Record)]
pub struct TranscriptEntry {
    pub kind: TranscriptKind,
    pub text: String,
    /// ISO 8601, as Claude Code wrote it.
    pub timestamp: Option<String>,
}

/// Where to continue a conversation backwards, from a [`TranscriptPage`].
#[uniffi::remote(Record)]
pub struct TranscriptCursor {
    pub session_path: String,
    pub start: u64,
}

/// Part of a Claude Code conversation, oldest entry first.
#[uniffi::remote(Record)]
pub struct TranscriptPage {
    /// The session file below the host's home directory; pass it back with
    /// `start` to load the entries before this page.
    pub session_path: String,
    pub entries: Vec<TranscriptEntry>,
    /// Byte offset this page starts at; 0 means the conversation's start.
    pub start: u64,
}

pub use herdr_session::{UsageBucket, UsageReport};

/// The tokens one model used in one working directory in one hour (#302).
#[uniffi::remote(Record)]
pub struct UsageBucket {
    pub cwd: String,
    /// Start of the hour (UTC) in Unix milliseconds.
    pub hour_start_ms: u64,
    pub model: String,
    pub input: u64,
    pub output: u64,
    pub cache_write_5m: u64,
    pub cache_write_1h: u64,
    pub cache_read: u64,
}

/// Token usage of some working directories, oldest hour first.
#[uniffi::remote(Record)]
pub struct UsageReport {
    pub buckets: Vec<UsageBucket>,
}

/// A Claude Code session of a folder (#304).
#[uniffi::remote(Record)]
pub struct ClaudeSessionItem {
    /// What `claude --resume` takes.
    pub id: String,
    pub title: String,
    /// Last activity, seconds since 1970; 0 if unknown.
    pub modified: u64,
    /// Bytes of the session file, in place of a message count.
    pub size: u64,
}

pub use herdr_session::{
    DiffFile, DiffFileStatus, DiffHunk, DiffLine, DiffLineKind, WorkingTreeDiff,
};

/// How a file changed in a working tree diff (#228).
#[uniffi::remote(Enum)]
pub enum DiffFileStatus {
    Modified,
    Added,
    Deleted,
    Renamed,
    /// Not tracked by Git yet.
    Untracked,
}

#[uniffi::remote(Enum)]
pub enum DiffLineKind {
    Context,
    Added,
    Removed,
    /// `\\ No newline at end of file`.
    Note,
}

#[uniffi::remote(Record)]
pub struct DiffLine {
    pub kind: DiffLineKind,
    /// The line without its `+`, `-` or ` ` prefix.
    pub text: String,
}

#[uniffi::remote(Record)]
pub struct DiffHunk {
    /// The `@@ -a,b +c,d @@ context` line.
    pub header: String,
    pub lines: Vec<DiffLine>,
}

/// One file of a working tree diff.
#[uniffi::remote(Record)]
pub struct DiffFile {
    /// The path after the change (before it for a deleted file).
    pub path: String,
    /// The path before a rename.
    pub old_path: Option<String>,
    pub status: DiffFileStatus,
    /// Binary content; no hunks.
    pub binary: bool,
    /// An untracked file too big to show; no hunks.
    pub too_large: bool,
    pub additions: u32,
    pub deletions: u32,
    pub hunks: Vec<DiffHunk>,
}

/// A working tree diff; `truncated` when it was cut off at the size the
/// apps read.
#[uniffi::remote(Record)]
pub struct WorkingTreeDiff {
    pub files: Vec<DiffFile>,
    pub truncated: bool,
}

pub use herdr_session::{DailyItem, DailyItemKind, DailyLog};

/// What an entry of a host's day is (#301).
#[uniffi::remote(Enum)]
pub enum DailyItemKind {
    /// The user gave a Claude agent a task.
    Prompt,
    /// The agent ended its turn with an answer.
    Done,
    Commit,
}

#[uniffi::remote(Record)]
pub struct DailyItem {
    pub kind: DailyItemKind,
    /// Unix milliseconds.
    pub time_ms: u64,
    /// The space it happened in, else the folder's name.
    pub place: String,
    /// First line of the prompt, the answer or the commit message.
    pub text: String,
    /// A commit's author.
    pub author: Option<String>,
}

/// One day of a host, oldest first; `truncated` when not every session
/// file was read to the day's start.
#[uniffi::remote(Record)]
pub struct DailyLog {
    pub items: Vec<DailyItem>,
    pub truncated: bool,
}

pub use herdr_session::{Directory, DirectoryEntry, EntryKind, FileContent, FilePreview};

/// What an entry of the file browser is (#259).
#[uniffi::remote(Enum)]
pub enum EntryKind {
    Directory,
    File,
    /// A broken link, a socket, a device and the like: not opened.
    Other,
}

/// An entry of a directory in the file browser.
#[uniffi::remote(Record)]
pub struct DirectoryEntry {
    pub name: String,
    /// Absolute, in the listed directory.
    pub path: String,
    pub kind: EntryKind,
    pub size: u64,
    /// Seconds since 1970, 0 if unknown.
    pub modified: u64,
    /// A dot file, `node_modules` or `target`: folded away by default.
    pub hidden: bool,
}

/// A directory on the host with real, absolute paths.
#[uniffi::remote(Record)]
pub struct Directory {
    pub home: String,
    pub path: String,
    /// Directories first, then by name without regard to case.
    pub entries: Vec<DirectoryEntry>,
}

#[uniffi::remote(Enum)]
pub enum FileContent {
    /// Up to 1 MB; `truncated` when the file is longer.
    Text { text: String, truncated: bool },
    /// The whole image file.
    Image { data: Vec<u8> },
    /// Neither: only size and type are shown.
    Binary,
}

/// A file of the file browser to show on the device.
#[uniffi::remote(Record)]
pub struct FilePreview {
    /// The real, absolute path.
    pub path: String,
    pub name: String,
    pub size: u64,
    /// Seconds since 1970, 0 if unknown.
    pub modified: u64,
    pub content: FileContent,
    /// Whole text up to 256 KB, UTF-8 without `\r`: can be saved back
    /// (#271).
    pub editable: bool,
}

pub use herdr_session::GitHubRepo;

/// A GitHub repository of the spaces on a host (#296), with the spaces
/// that show it.
#[uniffi::remote(Record)]
pub struct GitHubRepo {
    /// `owner/name`.
    pub repo: String,
    pub workspace_ids: Vec<String>,
}
