// Ctrl+K: spaces and agents on all hosts, matched like QuickSwitcher.swift.

import { arrange, sortedAgents } from "./spaces";
import type { AgentState, HostConfig, SessionUpdate } from "./types";

export interface SwitcherEntry {
  id: string;
  kind: "space" | "agent";
  hostId: string;
  workspaceId: string;
  paneId: string | null;
  title: string;
  subtitle: string | null;
  hostName: string;
  state: AgentState | null;
  /** Texts a query is matched against, most important first. */
  fields: string[];
}

/** Spaces in sidebar order, then agents grouped, per host. */
export function entries(hosts: HostConfig[], updates: Record<string, SessionUpdate>): SwitcherEntry[] {
  return hosts.flatMap((host) => {
    const update = updates[host.id];
    if (!update) return [];
    const spaces = arrange(update).map(({ workspace: ws, nested }): SwitcherEntry => {
      const subtitle = nested ? ws.label : [ws.group, ws.branch].filter(Boolean).join(" · ");
      return {
        id: `${host.id}/${ws.workspaceId}/`,
        kind: "space",
        hostId: host.id,
        workspaceId: ws.workspaceId,
        paneId: null,
        title: nested ? (ws.branch ?? ws.worktreeName ?? ws.label) : ws.name,
        subtitle: subtitle || null,
        hostName: host.name,
        state: ws.agentState === "unknown" ? null : ws.agentState,
        fields: [ws.name, ws.label, ws.branch, ws.worktreeName].filter((f): f is string => Boolean(f)),
      };
    });
    const agents = sortedAgents(update, "grouped").map(({ agent, tabNumber }): SwitcherEntry => {
      const space = agent.workspaceGroup ? `${agent.workspaceName} (${agent.workspaceGroup})` : agent.workspaceName;
      const place = tabNumber ? `${space} · ${tabNumber}` : space;
      return {
        id: `${host.id}/${agent.workspaceId}/${agent.paneId}`,
        kind: "agent",
        hostId: host.id,
        workspaceId: agent.workspaceId,
        paneId: agent.paneId,
        title: agent.name ?? agent.agent,
        subtitle: agent.title ? `${place} · ${agent.title}` : place,
        hostName: host.name,
        state: agent.agentState,
        fields: [agent.name ?? agent.agent, agent.agent, agent.workspaceLabel, agent.title, agent.tabLabel],
      };
    });
    return [...spaces, ...agents];
  });
}

/**
 * Every word must appear in a field, as a substring or as letters in order
 * ("hrc" finds "herdr-remote-core"). Word starts rank above substrings,
 * substrings above scattered letters, the first field above the others.
 */
export function filter(all: SwitcherEntry[], query: string): SwitcherEntry[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) return all;
  return all
    .map((entry, index) => ({ entry, index, score: score(entry.fields, words) }))
    .filter((r): r is { entry: SwitcherEntry; index: number; score: number } => r.score !== null)
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .map((r) => r.entry);
}

function score(fields: string[], words: string[]): number | null {
  const lower = fields.map((f) => f.toLowerCase());
  let total = 0;
  for (const word of words) {
    let best: number | null = null;
    lower.forEach((field, position) => {
      const bonus = position === 0 ? 1 : 0;
      const at = field.indexOf(word);
      const points =
        at >= 0 ? (at === 0 || !/[\p{L}\p{N}]/u.test(field[at - 1]) ? 6 : 4) + bonus : subsequence(word, field) ? 1 : null;
      if (points !== null && points > (best ?? 0)) best = points;
    });
    if (best === null) return null;
    total += best;
  }
  return total;
}

function subsequence(word: string, text: string): boolean {
  let i = 0;
  for (const ch of text) {
    if (ch === word[i]) i++;
    if (i === word.length) return true;
  }
  return i === word.length;
}
