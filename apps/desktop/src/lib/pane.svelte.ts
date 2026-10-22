// The live screen of one pane, optionally with scrollback above it; like
// PaneModel.swift. Only a live pane (the selected one) loads history.

import * as core from "./core";
import type { PaneContent } from "./types";

/** Most history rows herdr returns for one read (`pane::MAX_HISTORY_LINES`). */
export const MAX_HISTORY = 1000;
const HISTORY_STEPS = [200, 500, MAX_HISTORY];

export class PaneModel {
  content = $state<PaneContent | null>(null);
  error = $state<string | null>(null);
  /** History rows asked for; 0 shows only the visible screen. */
  historyLines = $state(0);
  /** Rows of the last screen-only read, to tell whether history added any. */
  private screenRows = $state(0);
  private follower: core.Follower | null = null;
  private live: boolean;
  /** Lines the terminal wrapped come joined, see `setUnwrap`. */
  private unwrap = false;
  private stopped = false;

  constructor(
    readonly hostId: string,
    readonly paneId: string,
    live: boolean,
  ) {
    this.live = live;
    core
      .followPane(hostId, paneId, live, (event) => {
        if (event.kind === "content") {
          if (event.data.historyLines === 0) this.screenRows = event.data.lines.length;
          this.content = event.data;
          this.error = null;
        } else if (!event.data.includes("pane_not_found")) {
          // A closed pane: the view moves on once the session reports it.
          this.error = event.data;
        }
      })
      .then((follower) => {
        if (this.stopped) follower.stop();
        else {
          this.follower = follower;
          if (this.live !== live) follower.setLive(this.live);
          if (this.unwrap) follower.setUnwrap(true);
        }
      })
      .catch((err) => (this.error = core.errorText(err)));
  }

  /** Ends the follower once its request in flight is done. */
  stop() {
    this.stopped = true;
    this.follower?.stop();
    this.follower = null;
  }

  get isLoadingHistory(): boolean {
    return this.historyLines > (this.content?.historyLines ?? 0);
  }

  /** History read, but nothing above the screen: full-screen programs. */
  get hasNoHistory(): boolean {
    const c = this.content;
    if (!c || this.isLoadingHistory || c.historyLines === 0 || c.truncated) return false;
    return this.screenRows > 0 && c.lines.length <= this.screenRows;
  }

  get canLoadMoreHistory(): boolean {
    const c = this.content;
    if (!c || this.isLoadingHistory) return false;
    return c.historyLines === 0 || (c.truncated && c.historyLines < MAX_HISTORY);
  }

  loadMoreHistory() {
    if (!this.live || !this.canLoadMoreHistory) return;
    this.historyLines = HISTORY_STEPS.find((n) => n > this.historyLines) ?? MAX_HISTORY;
    this.follower?.setHistoryLines(this.historyLines);
  }

  hideHistory() {
    this.historyLines = 0;
    this.follower?.setHistoryLines(0);
  }

  /**
   * Joins the rows the terminal wrapped at the pane width, for a view that
   * wraps lines at its own width (#191). Drops loaded history, whose row
   * count would no longer match the screen's.
   */
  setUnwrap(unwrap: boolean) {
    if (unwrap === this.unwrap) return;
    this.unwrap = unwrap;
    if (this.historyLines > 0) this.hideHistory();
    this.follower?.setUnwrap(unwrap);
  }

  /** The fast pace for the selected pane, the slow one beside it. */
  setLive(live: boolean) {
    if (live === this.live) return;
    this.live = live;
    this.follower?.setLive(live);
    if (!live && this.historyLines > 0) this.hideHistory();
  }

  get plainText(): string {
    return (this.content?.lines ?? []).map((l) => l.spans.map((s) => s.text).join("")).join("\n");
  }
}
