// Screenshot demo (#199): a debug build started by scripts/screenshots.sh
// opens a space, a pane and a view of the seeded demo session.

import { LogicalSize, getCurrentWindow } from "@tauri-apps/api/window";
import * as core from "./core";
import { activeFind } from "./find.svelte";
import { ui } from "./manage.svelte";
import { nav } from "./nav.svelte";
import { model } from "./state.svelte";
import type { DemoTarget } from "./types";

export const demo = $state<{ target: DemoTarget | null }>({ target: null });

/** Waits for the demo session's spaces, then opens what the script asked for. */
export async function openDemo(addHost: () => void) {
  const target = await core.demoTarget().catch(() => null);
  if (!target) return;
  demo.target = target;
  await getCurrentWindow().setSize(new LogicalSize(1440, 900));
  if (target.appearance === "dark" || target.appearance === "light") await getCurrentWindow().setTheme(target.appearance);
  const host = model.hosts[0];
  if (!host) return;
  for (let i = 0; i < 100 && !model.updates[host.id]?.workspaces.length; i++) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const space = model.updates[host.id]?.workspaces.find((w) => w.label === target.space);
  if (space) model.select(host.id, space.workspaceId, target.pane ?? null);
  if (target.view === "switcher") nav.switcherOpen = true;
  if (target.view === "settings") ui.dialog = { kind: "settings" };
  if (target.view === "addHost") addHost();
  if (target.search) {
    // The pane view registers its search once it is on screen.
    for (let i = 0; i < 50 && !activeFind.find; i++) await new Promise((resolve) => setTimeout(resolve, 100));
    activeFind.find?.show();
    activeFind.find?.setQuery(target.search);
  }
}
