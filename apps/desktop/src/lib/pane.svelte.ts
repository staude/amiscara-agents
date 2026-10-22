// The live screen of one pane, optionally with scrollback above it; like
// PaneModel.swift. Only a live pane (the selected one) loads history.

import * as core from "./core";
import type { PaneContent, ScrollStep } from "./types";

/** Most history rows herdr returns for one read (`pane::MAX_HISTORY_LINES`). */
export const MAX_HISTORY = 1000;
const HISTORY_STEPS = [200, 500, MAX_HISTORY];

export class PaneModel {
  /** The followed screen, with scrollback when asked for. */
  private followed = $state<PaneContent | null>(null);
  error = $state<string | null>(null);
  /**
   * The transcript of a full-screen agent such as Claude Code, which herdr
   * keeps no scrollback for (#187): read once on request and shown instead
   * of the live screen until `hideHistory()`. Plain text.
   */
  agentHistory = $state<PaneContent | null>(null);
  loadingAgentHistory = $state(false);
  /** Why the last step through a full-screen agent failed. */
  agentError = $state<string | null>(null);
  /** The app scrolled the agent's own view up, also on the host; undone in `stop()`. */
  private agentScrolled = false;
  /** History rows asked for; 0 shows only the visible screen. */
  historyLines = $state(0);
  /** Rows of the last screen-only read, to tell whether history added any. */
  private screenRows = $state(0);
  private follower: core.Follower | null = null;
  private live: boolean;
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
          this.followed = event.data;
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
        }
      })
      .catch((err) => (this.error = core.errorText(err)));
  }

  /** Ends the follower once its request in flight is done. */
  stop() {
    this.stopped = true;
    this.follower?.stop();
    this.follower = null;
    if (this.agentScrolled) core.scrollAgent(this.hostId, this.paneId, "bottom").catch(() => {});
  }

  /** What the pane view shows: the agent's transcript, else the live screen. */
  get content(): PaneContent | null {
    return this.agentHistory ?? this.followed;
  }

  get isLoadingHistory(): boolean {
    return this.historyLines > (this.followed?.historyLines ?? 0);
  }

  /** History read, but nothing above the screen: full-screen programs. */
  get hasNoHistory(): boolean {
    const c = this.followed;
    if (!c || this.agentHistory || this.isLoadingHistory || c.historyLines === 0 || c.truncated) return false;
    return this.screenRows > 0 && c.lines.length <= this.screenRows;
  }

  get canLoadMoreHistory(): boolean {
    const c = this.followed;
    if (!c || this.agentHistory || this.isLoadingHistory) return false;
    return c.historyLines === 0 || (c.truncated && c.historyLines < MAX_HISTORY);
  }

  loadMoreHistory() {
    if (!this.live || !this.canLoadMoreHistory) return;
    this.historyLines = HISTORY_STEPS.find((n) => n > this.historyLines) ?? MAX_HISTORY;
    this.follower?.setHistoryLines(this.historyLines);
  }

  hideHistory() {
    this.historyLines = 0;
    this.agentHistory = null;
    this.agentError = null;
    this.follower?.setHistoryLines(0);
  }

  /**
   * Reads the transcript of the full-screen agent in the pane. herdr scrolls
   * the agent on the host through it and back down, which takes a moment
   * and works only while the agent is idle.
   */
  async loadAgentHistory() {
    if (this.loadingAgentHistory) return;
    this.loadingAgentHistory = true;
    this.agentError = null;
    try {
      this.agentHistory = await core.agentHistory(this.hostId, this.paneId);
    } catch (err) {
      this.agentError = scrollError(err);
    } finally {
      this.loadingAgentHistory = false;
    }
  }

  /** Scrolls the full-screen agent's own view; the live screen follows. */
  async scrollAgent(step: ScrollStep) {
    this.agentScrolled = step !== "bottom";
    this.agentError = null;
    try {
      await core.scrollAgent(this.hostId, this.paneId, step);
    } catch (err) {
      this.agentError = scrollError(err);
    }
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

function scrollError(err: unknown): string {
  const working = typeof err === "object" && err !== null && (err as { kind?: string }).kind === "agentWorking";
  return working
    ? "Der Agent arbeitet gerade. Den Verlauf gibt es, sobald er fertig ist; blättern geht schon jetzt."
    : core.errorText(err);
}
