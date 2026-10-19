// Updates from the public release repository (tauri-plugin-updater): the
// manifest and the installers are signed with the updater key, which the
// app checks before installing.

import { relaunch } from "@tauri-apps/plugin-process";
import { check, type Update } from "@tauri-apps/plugin-updater";

class Updater {
  available = $state<Update | null>(null);
  state = $state<"idle" | "checking" | "current" | "downloading" | "failed">("idle");
  progress = $state(0);
  error = $state<string | null>(null);

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
