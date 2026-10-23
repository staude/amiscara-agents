// Sample data instead of the Rust side, for `npm run mock`: the window in
// a normal browser, to work on the layout without a herdr server.

import { emit } from "@tauri-apps/api/event";
import { mockIPC } from "@tauri-apps/api/mocks";
import type {
  AgentState,
  HostConfig,
  PaneContent,
  PaneItem,
  SessionUpdate,
  StyledSpan,
  TabItem,
  TermColor,
  WorkspaceItem,
} from "../lib/types";

const host = (id: string, name: string, kind: "ssh" | "local"): HostConfig => ({
  id,
  name,
  kind,
  host: kind === "ssh" ? "mac.example.internal" : "",
  port: 22,
  user: "frank",
  socketPath: "/Users/frank/.config/herdr/herdr.sock",
  pinnedHostKey: "ssh-ed25519 AAAA",
  publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMock amiscara-agents mock",
  auth: "key",
  allowInput: true,
  allowUpload: true,
  notify: null,
  groupSpaces: null,
});

const hosts = [host("work", "work", "ssh"), host("nas", "nas", "ssh")];

const pane = (paneId: string, agent: string | null, agentState: AgentState, title: string): PaneItem => ({
  paneId,
  title,
  agent,
  name: null,
  agentState,
  focused: true,
});

const tab = (tabId: string, number: number, panes: PaneItem[], split = false): TabItem => ({
  tabId,
  number,
  label: String(number),
  focused: number === 1,
  agentState: panes.find((p) => p.agent)?.agentState ?? "idle",
  panes,
  layout: split
    ? {
        columns: 200,
        rows: 60,
        zoomed: false,
        panes: [
          { paneId: panes[0].paneId, x: 0, y: 0, width: 100, height: 60 },
          { paneId: panes[1].paneId, x: 100, y: 0, width: 100, height: 30 },
          { paneId: panes[2].paneId, x: 100, y: 30, width: 100, height: 30 },
        ],
      }
    : null,
});

const space = (
  workspaceId: string,
  number: number,
  label: string,
  tabs: TabItem[],
  extra: Partial<WorkspaceItem> = {},
): WorkspaceItem => {
  const slash = label.indexOf("/");
  return {
    workspaceId,
    number,
    label,
    name: slash >= 0 ? label.slice(slash + 1) : label,
    group: slash >= 0 ? label.slice(0, slash) : null,
    focused: number === 1,
    agentState: tabs.flatMap((t) => t.panes).find((p) => p.agent)?.agentState ?? "idle",
    activeTabId: tabs[0].tabId,
    repoKey: null,
    worktreeName: null,
    branch: null,
    tokens: [],
    tabs,
    ...extra,
  };
};

const workspaces: WorkspaceItem[] = [
  space("w1", 1, "enon", [tab("t1", 1, [pane("p1", "claude", "blocked", "enon: Tests")])], {
    branch: "production",
    repoKey: "enon",
  }),
  space(
    "w2",
    2,
    "amiscara-agents",
    [
      tab("t2", 1, [
        pane("p2", "claude", "working", "Desktop 3/5"),
        pane("p3", null, "idle", "zsh"),
        pane("p4", "codex", "done", "Review"),
      ], true),
      tab("t3", 2, [pane("p5", null, "idle", "cargo watch")]),
    ],
    { branch: "feature/144-desktop-main-window", repoKey: "amiscara", tokens: [{ name: "pr", value: "PR #148" }] },
  ),
  space("w3", 3, "docs-amiscara", [tab("t4", 1, [pane("p6", null, "idle", "zsh")])], {
    repoKey: "amiscara",
    worktreeName: "docs-amiscara",
    branch: "docs/handoff",
  }),
  space("w4", 4, "Privat/Dorfkino", [tab("t5", 1, [pane("p7", "claude", "done", "Dorfkino")])], { branch: "main" }),
  space("w5", 5, "Privat/Bürgergarten", [tab("t6", 1, [pane("p8", null, "idle", "zsh")])]),
];

const board = workspaces.flatMap((w) =>
  w.tabs.flatMap((t) =>
    t.panes
      .filter((p) => p.agent)
      .map((p) => ({
        paneId: p.paneId,
        workspaceId: w.workspaceId,
        tabId: t.tabId,
        workspaceLabel: w.label,
        workspaceName: w.name,
        workspaceGroup: w.group,
        tabLabel: t.label,
        agent: p.agent!,
        name: p.paneId === "p2" ? "desktop" : null,
        agentState: p.agentState,
        title: p.title,
        cwd: null,
      })),
  ),
);
board.sort((a, b) => ["blocked", "working", "done", "idle", "unknown"].indexOf(a.agentState) -
  ["blocked", "working", "done", "idle", "unknown"].indexOf(b.agentState));

const update: SessionUpdate = {
  status: { kind: "live" },
  serverVersion: "0.9.5",
  protocolSupported: true,
  focusedPaneId: "p1",
  workspaces,
  spaceOrder: [
    { workspaceId: "w1", nested: false },
    { workspaceId: "w2", nested: false },
    { workspaceId: "w3", nested: true },
    { workspaceId: "w4", nested: false },
    { workspaceId: "w5", nested: false },
  ],
  board,
  attention: [],
};

const color = (kind: "default" | number | [number, number, number]): TermColor =>
  kind === "default"
    ? { kind: "default" }
    : typeof kind === "number"
      ? { kind: "indexed", index: kind }
      : { kind: "rgb", r: kind[0], g: kind[1], b: kind[2] };

const span = (text: string, fg: Parameters<typeof color>[0] = "default", bold = false): StyledSpan => ({
  text,
  width: text.length,
  fg: color(fg),
  bg: color("default"),
  bold,
  dim: false,
  italic: false,
  underline: false,
  inverse: false,
  hidden: false,
  strikethrough: false,
  link: null,
});

function screen(paneId: string, history: number): PaneContent {
  const lines: StyledSpan[][] = [];
  for (let i = history; i > 0; i--) lines.push([span(`scrollback line ${i} `, 8), span("ok", 2)]);
  lines.push([span("╭─ ", [215, 119, 87]), span("Claude Code", [215, 119, 87], true), span(" ─────────────────────╮", [215, 119, 87])]);
  lines.push([span("│ ", [215, 119, 87]), span("cwd: ~/dev/project", 7)]);
  lines.push([span("╰──────────────────────────────────╯", [215, 119, 87])]);
  lines.push([]);
  lines.push([span("> ", 8), span("mach mit 144 weiter")]);
  lines.push([]);
  lines.push([span("⏺ ", 2), span("Read", "default", true), span("(apps/AmiscaraAgents/Views/HostSidebar.swift)")]);
  lines.push([span("  ⎿  Read 753 lines", 8)]);
  lines.push([span("⏺ ", 2), span("Bash", "default", true), span("(cargo clippy -p amiscara-desktop)")]);
  lines.push([span("  ⎿  Finished `dev` profile in 0.70s", 8)]);
  lines.push([span("  PR: "), { ...span("https://github.com/staude/amiscara-agents/pull/186"), link: "https://github.com/staude/amiscara-agents/pull/186" }]);
  for (let i = 0; i < 24; i++) lines.push([span(`   ${String(i + 1).padStart(3)} `, 8), span("let model = new PaneModel(hostId, paneId, live);", 6)]);
  if (paneId === "p1") {
    lines.push([span("Do you want to proceed?", "default", true)]);
    lines.push([span("❯ 1. Yes", 4)]);
    lines.push([span("  2. Yes, and don't ask again", "default")]);
    lines.push([span("  3. No, and tell Claude what to do differently (esc)", "default")]);
  } else {
    lines.push([span("✻ Thinking… ", [215, 119, 87]), span("(12s · esc to interrupt)", 8)]);
  }
  return {
    paneId,
    lines: lines.map((spans) => ({ spans })),
    truncated: false,
    historyLines: history,
  };
}

const transcript = [
  { kind: "user", text: "mach mit 144 weiter", timestamp: new Date().toISOString() },
  { kind: "assistant", text: "Ich lese zuerst die Views der Mac-App, um das Fenster nachzubauen.", timestamp: null },
  { kind: "tool", text: "Read apps/AmiscaraAgents/Views/HostSidebar.swift", timestamp: null },
  { kind: "assistant", text: "Die Sidebar steht. Als Nächstes Terminal und Eingabeleiste.", timestamp: null },
];

let replies = ["weiter", "/compact", "Bitte committen", "Commit und PR erstellen"];

mockIPC(
  (cmd, args) => {
    const a = (args ?? {}) as Record<string, unknown>;
    switch (cmd) {
      case "app_info":
        return { version: "0.1.0", protocol: 22, localSocket: true, os: "windows" };
      case "list_hosts":
        return hosts;
      case "connect":
        setTimeout(() => {
          void emit("session-update", { hostId: a.hostId, generation: 1, update });
        }, 50);
        return null;
      case "pending_links":
        return [];
      case "quick_replies":
        return replies;
      case "save_quick_replies":
        replies = (a.replies as string[]).filter((r) => r.trim());
        return null;
      case "key_line":
        return `restrict,command="…" ${hosts[0].publicKey}`;
      case "follow_pane": {
        const channel = a.channel as { id: number };
        const paneId = a.paneId as string;
        let index = 0;
        const send = (lines: number) =>
          window.__TAURI_INTERNALS__.runCallback(channel.id, {
            index: index++,
            message: { kind: "content", data: screen(paneId, lines) },
          });
        setTimeout(() => send(0), 30);
        follows.set(++followId, send);
        return followId;
      }
      case "set_follow_history": {
        const send = follows.get(a.followId as number);
        setTimeout(() => send?.(Math.min(a.lines as number, 40)), 200);
        return null;
      }
      case "agent_history":
        return screen(a.paneId as string, 40);
      case "claude_history":
        return { sessionPath: "s", entries: transcript, start: 0 };
      case "agent_kinds":
        return ["claude", "codex", "opencode", "gemini", "pi"];
      case "autostart":
        return false;
      case "create_workspace":
      case "create_tab":
      case "create_worktree":
        return { workspaceId: "w2", tabId: "t3", paneId: "p5" };
      case "session_socket": {
        const name = a.name as string;
        const dir = (a.defaultSocket as string).replace(/(\/sessions\/[^/]+)?\/herdr\.sock$/, "");
        return name ? `${dir}/sessions/${name}/herdr.sock` : `${dir}/herdr.sock`;
      }
      case "session_of_socket":
        return (a.socketPath as string).match(/\/sessions\/([^/]+)\/herdr\.sock$/)?.[1] ?? null;
      case "valid_session_name":
        return /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$/.test(a.name as string);
      case "local_default_socket":
        return null;
      case "local_sessions":
      case "host_sessions":
        return [
          { name: "herdr-remote-test", running: true },
          { name: "amiscara-screenshots", running: false },
        ];
      case "upload":
        return "/Users/frank/.amiscara-agents/uploads/img-1.png";
      default:
        console.log("mock", cmd, a);
        return null;
    }
  },
  { shouldMockEvents: true },
);

const follows = new Map<number, (lines: number) => void>();
let followId = 0;

declare global {
  interface Window {
    __TAURI_INTERNALS__: { runCallback(id: number, data: unknown): void };
  }
}
