// The sidebar's order, like HostSidebar.swift: spaces in the core's order
// (worktrees after their repository, name groups together), agents grouped
// by space or by state.

import { t } from "./i18n.svelte";
import type { AgentOrder } from "./prefs.svelte";
import type { AgentState, BoardItem, SessionUpdate, WorkspaceItem } from "./types";

export interface SpaceEntry {
  workspace: WorkspaceItem;
  nested: boolean;
}

export type SpaceBlock =
  | { kind: "space"; entry: SpaceEntry }
  | { kind: "group"; name: string; entries: SpaceEntry[] };

export function arrange(update: SessionUpdate): SpaceEntry[] {
  const byId = new Map<string, WorkspaceItem>();
  for (const w of update.workspaces) if (!byId.has(w.workspaceId)) byId.set(w.workspaceId, w);
  return update.spaceOrder.flatMap((slot) => {
    const workspace = byId.get(slot.workspaceId);
    return workspace ? [{ workspace, nested: slot.nested }] : [];
  });
}

/** The core keeps a group's spaces adjacent; a group ends at another one. */
export function blocks(entries: SpaceEntry[]): SpaceBlock[] {
  const out: SpaceBlock[] = [];
  for (const entry of entries) {
    const group = entry.workspace.group;
    const last = out[out.length - 1];
    if (!group) out.push({ kind: "space", entry });
    else if (last?.kind === "group" && last.name === group) last.entries.push(entry);
    else out.push({ kind: "group", name: group, entries: [entry] });
  }
  return out;
}

/** Where a dragged row may go, as in HostSidebar.swift. */
type Level = { kind: "top" } | { kind: "group"; name: string } | { kind: "worktrees"; of: string };

const sameLevel = (a: Level, b: Level) =>
  a.kind === b.kind &&
  (a.kind !== "group" || a.name === (b as { name: string }).name) &&
  (a.kind !== "worktrees" || a.of === (b as { of: string }).of);

/**
 * The rows that move with `key` (a workspace ID or `group/<Name>`), from
 * `start` to before `end`: a group with all its entries, a space with its
 * nested worktrees.
 */
function segment(key: string, entries: SpaceEntry[]): { level: Level; start: number; end: number } | null {
  const index = entries.findIndex((e) => e.workspace.workspaceId === key);
  if (index >= 0) {
    const entry = entries[index];
    if (entry.nested) {
      let head = index - 1;
      while (head >= 0 && entries[head].nested) head--;
      if (head < 0) return null;
      return { level: { kind: "worktrees", of: entries[head].workspace.workspaceId }, start: index, end: index + 1 };
    }
    let end = index + 1;
    while (end < entries.length && entries[end].nested) end++;
    const group = entry.workspace.group;
    return { level: group ? { kind: "group", name: group } : { kind: "top" }, start: index, end };
  }
  if (!key.startsWith("group/")) return null;
  const name = key.slice("group/".length);
  const start = entries.findIndex((e) => e.workspace.group === name);
  if (start < 0) return null;
  let end = start;
  while (end < entries.length && entries[end].workspace.group === name) end++;
  return { level: { kind: "top" }, start, end };
}

/**
 * The manual order after dropping `dragged` on `target` (#243): behind it
 * when it came from above, otherwise in front of it. `null` when both are
 * on different levels or the same row.
 */
export function moveSpace(entries: SpaceEntry[], dragged: string, target: string): string[] | null {
  if (dragged === target) return null;
  const from = segment(dragged, entries);
  const to = segment(target, entries);
  if (!from || !to || !sameLevel(from.level, to.level)) return null;
  const ids = entries.map((e) => e.workspace.workspaceId);
  const moving = ids.splice(from.start, from.end - from.start);
  const at = from.start < to.start ? to.end - moving.length : to.start;
  ids.splice(at, 0, ...moving);
  return ids;
}

export const urgency: Record<AgentState, number> = {
  blocked: 0,
  working: 1,
  done: 2,
  idle: 3,
  unknown: 4,
};

export interface AgentEntry {
  agent: BoardItem;
  /** Tab label, only when the agent's space has several tabs. */
  tabNumber: string | null;
}

export function sortedAgents(update: SessionUpdate, order: AgentOrder): AgentEntry[] {
  const spaceIndex = new Map<string, number>();
  arrange(update).forEach((e, i) => {
    if (!spaceIndex.has(e.workspace.workspaceId)) spaceIndex.set(e.workspace.workspaceId, i);
  });
  const tabNumber = new Map<string, number>();
  const tabCount = new Map<string, number>();
  for (const w of update.workspaces) {
    tabCount.set(w.workspaceId, w.tabs.length);
    for (const t of w.tabs) tabNumber.set(t.tabId, t.number);
  }
  const place = (a: BoardItem) => [
    spaceIndex.get(a.workspaceId) ?? Number.MAX_SAFE_INTEGER,
    tabNumber.get(a.tabId) ?? Number.MAX_SAFE_INTEGER,
  ];
  // The board arrives sorted by urgency; its index breaks ties.
  const ranked = update.board.map((agent, index) => ({ agent, index }));
  ranked.sort((a, b) => {
    const keyA = [...(order === "status" ? [urgency[a.agent.agentState]] : []), ...place(a.agent), a.index];
    const keyB = [...(order === "status" ? [urgency[b.agent.agentState]] : []), ...place(b.agent), b.index];
    for (let i = 0; i < keyA.length; i++) if (keyA[i] !== keyB[i]) return keyA[i] - keyB[i];
    return 0;
  });
  return ranked.map(({ agent }) => ({
    agent,
    tabNumber: (tabCount.get(agent.workspaceId) ?? 0) > 1 ? agent.tabLabel : null,
  }));
}

/** An agent's state in words, as in the sidebar. */
export function stateLabel(state: AgentState): string {
  switch (state) {
    case "blocked":
      return t("stateBlocked");
    case "working":
      return t("stateWorking");
    case "done":
      return t("stateDone");
    case "idle":
      return t("stateIdle");
    default:
      return t("stateUnknown");
  }
}
