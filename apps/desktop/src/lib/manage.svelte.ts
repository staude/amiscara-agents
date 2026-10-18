// Creating, renaming and closing in herdr: which dialog or menu is open.
// Sidebar and tab bar ask for one, App shows it.

import { model } from "./state.svelte";
import type { AgentState, WorkspaceItem } from "./types";

export interface MenuItem {
  label: string;
  action: () => void;
  danger?: boolean;
  disabled?: boolean;
}

export type Dialog =
  | { kind: "newSpace"; hostId: string }
  | { kind: "newWorktree"; hostId: string; repository: WorkspaceItem }
  | { kind: "rename"; hostId: string; target: "space" | "tab" | "agent"; id: string; current: string }
  | {
      kind: "close";
      hostId: string;
      target: "space" | "tab";
      id: string;
      name: string;
      agentState: AgentState;
      worktrees: number;
    }
  | { kind: "settings" };

export const ui = $state<{
  dialog: Dialog | null;
  menu: { x: number; y: number; items: (MenuItem | null)[] } | null;
}>({ dialog: null, menu: null });

export function openMenu(event: MouseEvent, items: (MenuItem | null)[]) {
  event.preventDefault();
  ui.menu = { x: event.clientX, y: event.clientY, items };
}

/** Writes need input allowed and a live connection, like in the Mac app. */
export function canWrite(hostId: string): boolean {
  return (model.host(hostId)?.allowInput ?? true) && model.isLive(hostId);
}

/**
 * The space a new worktree starts from: herdr wants the repository's main
 * checkout, so a linked worktree hands over to its repository's space.
 * `null` outside Git.
 */
export function repositoryOf(workspace: WorkspaceItem, all: WorkspaceItem[]): WorkspaceItem | null {
  if (workspace.worktreeName === null) {
    return workspace.branch !== null || workspace.repoKey !== null ? workspace : null;
  }
  return all.find((w) => w.repoKey === workspace.repoKey && w.worktreeName === null) ?? null;
}

/** Close a space, warning about agents in it and its linked worktrees. */
export function closeSpace(hostId: string, workspace: WorkspaceItem) {
  const all = model.updates[hostId]?.workspaces ?? [];
  const worktrees =
    workspace.worktreeName === null && workspace.repoKey !== null
      ? all.filter((w) => w.repoKey === workspace.repoKey && w.worktreeName !== null)
      : [];
  const states = [workspace, ...worktrees].map((w) => w.agentState);
  ui.dialog = {
    kind: "close",
    hostId,
    target: "space",
    id: workspace.workspaceId,
    name: workspace.worktreeName ?? workspace.name,
    agentState: states.includes("blocked") ? "blocked" : states.includes("working") ? "working" : workspace.agentState,
    worktrees: worktrees.length,
  };
}

/** The menu of a space row (sidebar). */
export function spaceMenu(hostId: string, workspace: WorkspaceItem): (MenuItem | null)[] {
  const writable = canWrite(hostId);
  const repo = repositoryOf(workspace, model.updates[hostId]?.workspaces ?? []);
  return [
    {
      label: "Umbenennen …",
      disabled: !writable,
      action: () =>
        (ui.dialog = { kind: "rename", hostId, target: "space", id: workspace.workspaceId, current: workspace.label }),
    },
    ...(repo
      ? [
          {
            label: "Neuer Worktree …",
            disabled: !writable,
            action: () => (ui.dialog = { kind: "newWorktree", hostId, repository: repo }),
          },
        ]
      : []),
    null,
    { label: "Space schließen …", danger: true, disabled: !writable, action: () => closeSpace(hostId, workspace) },
  ];
}
