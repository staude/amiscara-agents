// The sidebar's order, like HostSidebar.swift: spaces in the core's order
// (worktrees after their repository, name groups together), agents grouped
// by space or by state.

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

export const stateLabel: Record<AgentState, string> = {
  blocked: "wartet",
  working: "arbeitet",
  done: "fertig",
  idle: "bereit",
  unknown: "unbekannt",
};
