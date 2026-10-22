// Mirrors of the Rust records (serde, camelCase): herdr_session::view and
// the desktop crate's hosts and errors.

export type HostKind = "local" | "ssh";
export type Auth = "key" | "agent";

export interface HostConfig {
  id: string;
  name: string;
  kind: HostKind;
  host: string;
  port: number;
  user: string;
  socketPath: string;
  pinnedHostKey: string | null;
  publicKey: string | null;
  auth: Auth;
  allowInput: boolean | null;
  allowUpload: boolean | null;
  notify: boolean | null;
  groupSpaces: boolean | null;
}

export interface AppError {
  kind: string;
  message: string;
}

export interface AppInfo {
  version: string;
  protocol: number;
  localSocket: boolean;
  os: string;
}

export interface AddHostLink {
  name: string;
  host: string;
  port: number;
  user: string;
  socketPath: string;
  hostKey: string;
}

export type HostStatus =
  | { kind: "connecting" }
  | { kind: "live" }
  | { kind: "retrying"; attempt: number; error: string }
  | { kind: "hostKeyUnknown"; key: string; fingerprint: string }
  | { kind: "hostKeyChanged"; key: string; fingerprint: string }
  | { kind: "failed"; error: string };

export type AgentState = "idle" | "working" | "blocked" | "done" | "unknown";

export interface PaneItem {
  paneId: string;
  title: string;
  agent: string | null;
  name: string | null;
  agentState: AgentState;
  focused: boolean;
}

export interface TabItem {
  tabId: string;
  number: number;
  label: string;
  focused: boolean;
  agentState: AgentState;
  panes: PaneItem[];
  layout: SplitLayout | null;
}

export interface PaneFrame {
  paneId: string;
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface SplitLayout {
  columns: number;
  rows: number;
  zoomed: boolean;
  panes: PaneFrame[];
}

export interface TokenItem {
  name: string;
  value: string;
}

export interface WorkspaceItem {
  workspaceId: string;
  number: number;
  label: string;
  name: string;
  group: string | null;
  focused: boolean;
  agentState: AgentState;
  activeTabId: string;
  repoKey: string | null;
  worktreeName: string | null;
  branch: string | null;
  tokens: TokenItem[];
  tabs: TabItem[];
}

export interface SpaceSlot {
  workspaceId: string;
  nested: boolean;
}

export interface BoardItem {
  paneId: string;
  workspaceId: string;
  tabId: string;
  workspaceLabel: string;
  workspaceName: string;
  workspaceGroup: string | null;
  tabLabel: string;
  agent: string;
  name: string | null;
  agentState: AgentState;
  title: string;
  cwd: string | null;
}

export interface SessionUpdate {
  status: HostStatus;
  serverVersion: string | null;
  protocolSupported: boolean;
  focusedPaneId: string | null;
  workspaces: WorkspaceItem[];
  spaceOrder: SpaceSlot[];
  board: BoardItem[];
  attention: BoardItem[];
}

export type TermColor =
  | { kind: "default" }
  | { kind: "indexed"; index: number }
  | { kind: "rgb"; r: number; g: number; b: number };

export interface StyledSpan {
  text: string;
  width: number;
  fg: TermColor;
  bg: TermColor;
  bold: boolean;
  dim: boolean;
  italic: boolean;
  underline: boolean;
  inverse: boolean;
  hidden: boolean;
  strikethrough: boolean;
  /** Web address to open on a click (#186). */
  link: string | null;
}

export interface PaneContent {
  paneId: string;
  lines: { spans: StyledSpan[] }[];
  truncated: boolean;
  historyLines: number;
}

export type PaneEvent =
  | { kind: "content"; data: PaneContent }
  | { kind: "error"; data: string };

/** A step through a full-screen agent's own view (#187). */
export type ScrollStep = "pageUp" | "pageDown" | "bottom";

export type TranscriptKind = "user" | "assistant" | "tool";

export interface TranscriptEntry {
  kind: TranscriptKind;
  text: string;
  timestamp: string | null;
}

export interface TranscriptCursor {
  sessionPath: string;
  start: number;
}

export interface TranscriptPage {
  sessionPath: string;
  entries: TranscriptEntry[];
  start: number;
}

/** What the screenshot demo opens (#199), see `demo_target`. */
export interface DemoTarget {
  space?: string;
  pane?: string;
  view?: string;
  search?: string;
  appearance?: string;
}
