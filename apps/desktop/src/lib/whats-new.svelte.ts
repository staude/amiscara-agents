// "What's New" after an update (#341): the notes of apps/whats-new.json,
// built into the app. After an update the dialog shows once the versions
// since the one seen last; the settings show all up to the installed one.

import * as core from "./core";
import { ui } from "./manage.svelte";
import { model } from "./state.svelte";

const SEEN_KEY = "whatsNewSeenVersion";

function readSeen(): string | null {
  try {
    return localStorage.getItem(SEEN_KEY);
  } catch {
    return null;
  }
}

function writeSeen(version: string) {
  try {
    localStorage.setItem(SEEN_KEY, version);
  } catch {
    // Storage blocked: the notes show again on the next start.
  }
}

class WhatsNew {
  /** The version to note as seen once the automatic dialog closes. */
  private unseen: string | null = null;

  /** On start, after `model.load()`: shows the notes of an update once. */
  async start() {
    const current = model.info?.version;
    if (!current) return;
    const seen = readSeen();
    // The first start (or a version seen already) shows nothing.
    if (seen === null || seen === current) {
      writeSeen(current);
      return;
    }
    let entries;
    try {
      entries = await core.whatsNew(seen);
    } catch {
      return;
    }
    // A downgrade or a version without notes: nothing to show.
    if (entries.length === 0) {
      writeSeen(current);
      return;
    }
    // Another dialog is open: the notes wait for the next start.
    if (ui.dialog) return;
    // Started with the system the window is hidden; the version counts as
    // seen only when the dialog was closed.
    this.unseen = current;
    ui.dialog = { kind: "whatsNew", entries };
  }

  /** "Neuigkeiten" in the settings: all versions up to the installed one. */
  async showAll() {
    try {
      ui.dialog = { kind: "whatsNew", entries: await core.whatsNew(null) };
    } catch (err) {
      model.error = core.errorText(err);
    }
  }

  /** The dialog closed. */
  closed() {
    if (this.unseen) writeSeen(this.unseen);
    this.unseen = null;
  }
}

export const whatsNew = new WhatsNew();
