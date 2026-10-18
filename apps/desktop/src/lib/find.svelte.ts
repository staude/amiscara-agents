// Search state of one pane view, and the one the shortcuts act on.

import type { SearchMatch } from "./search";

export class FindState {
  open = $state(false);
  query = $state("");
  /** Index into the matches; null means the last one, nearest the bottom. */
  index = $state<number | null>(null);
  /** Bumped when the user moves to another match; only then the view scrolls. */
  scrollRequest = $state(0);
  /** Bumped by Ctrl+F, also while open, to focus the field. */
  focusRequest = $state(0);

  show() {
    this.open = true;
    this.focusRequest++;
  }

  close() {
    this.open = false;
    this.query = "";
    this.index = null;
  }

  setQuery(query: string) {
    this.query = query;
    this.index = null;
    this.scrollRequest++;
  }

  current(matches: SearchMatch[]): number | null {
    if (matches.length === 0) return null;
    return Math.min(this.index ?? matches.length - 1, matches.length - 1);
  }

  step(delta: number, matches: SearchMatch[]) {
    const at = this.current(matches);
    if (at === null) return;
    this.index = (at + delta + matches.length) % matches.length;
    this.scrollRequest++;
  }
}

/** What Ctrl+F and F3 act on: the selected pane's search and matches. */
export const activeFind = $state<{ find: FindState | null; matches: SearchMatch[] }>({
  find: null,
  matches: [],
});
