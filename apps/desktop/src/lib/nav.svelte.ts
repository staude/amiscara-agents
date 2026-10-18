// What the keyboard shortcuts act on; set by the views that own it, like
// the focused values of the Mac app (AppCommands.swift).

export interface KeySender {
  send(keys: string[]): void;
  /** The agent waits at a dialog, so the options 1 to 3 make sense. */
  blocked: boolean;
}

export const nav = $state<{
  keySender: KeySender | null;
  /** Steps through the tabs of the open space, wrapping around. */
  stepTab: ((delta: number) => void) | null;
  switcherOpen: boolean;
}>({ keySender: null, stepTab: null, switcherOpen: false });
