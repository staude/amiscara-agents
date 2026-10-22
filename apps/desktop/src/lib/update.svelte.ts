// Updates from this repository's releases (tauri-plugin-updater): the
// manifest is `latest.json` in the release `updates`, and it and the
// installers are signed with the updater key, which the app checks before
// installing. Like the Mac app (Sparkle), it looks at start and then every
// 24 hours, unless that is turned off in the settings.

import { relaunch } from "@tauri-apps/plugin-process";
import { check, type Update } from "@tauri-apps/plugin-updater";

const DAY = 24 * 60 * 60 * 1000;
const AUTO_KEY = "updatesAutomatic";

function readAuto(): boolean {
  try {
    return localStorage.getItem(AUTO_KEY) !== "false";
  } catch {
    return true;
  }
}

class Updater {
  /** Look on start and every 24 hours. */
  automatic = $state(readAuto());
  available = $state<Update | null>(null);
  state = $state<"idle" | "checking" | "current" | "downloading" | "failed">("idle");
  progress = $state(0);
  error = $state<string | null>(null);
  private timer: ReturnType<typeof setInterval> | null = null;

  /** Starts the automatic search; the app calls it once. */
  start() {
    this.schedule();
  }

  setAutomatic(on: boolean) {
    this.automatic = on;
    try {
      localStorage.setItem(AUTO_KEY, String(on));
    } catch {
      // Storage blocked: the setting lasts until the app quits.
    }
    this.schedule();
  }

  private schedule() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    if (!this.automatic) return;
    void this.check(true);
    this.timer = setInterval(() => {
      // An offer already shown or an install under way needs no new look.
      if (!this.available && this.state !== "downloading") void this.check(true);
    }, DAY);
  }

  /** `quiet`: on start, where no answer or failure needs a word. */
  async check(quiet = false) {
    this.state = "checking";
    this.error = null;
    try {
      this.available = await check();
      this.state = this.available ? "idle" : "current";
    } catch (err) {
      this.state = quiet ? "idle" : "failed";
      if (!quiet) this.error = String(err);
    }
  }

  /** Downloads, installs and restarts; Windows quits for its installer. */
  async install() {
    const update = this.available;
    if (!update) return;
    this.state = "downloading";
    this.progress = 0;
    let total = 0;
    let done = 0;
    try {
      await update.downloadAndInstall((event) => {
        if (event.event === "Started") total = event.data.contentLength ?? 0;
        if (event.event === "Progress") {
          done += event.data.chunkLength;
          this.progress = total ? Math.round((done / total) * 100) : 0;
        }
      });
      await relaunch();
    } catch (err) {
      this.state = "failed";
      this.error = String(err);
    }
  }
}

export const updater = new Updater();
