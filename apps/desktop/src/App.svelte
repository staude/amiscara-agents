<script lang="ts">
  import { i18n, t } from "./lib/i18n.svelte";
  import { onMount } from "svelte";
  import { openDemo } from "./lib/demo.svelte";
  import ContextMenu from "./components/ContextMenu.svelte";
  import HostEditor from "./components/HostEditor.svelte";
  import HostPanel from "./components/HostPanel.svelte";
  import LinkDialog from "./components/LinkDialog.svelte";
  import ManageDialogs from "./components/ManageDialogs.svelte";
  import QuickSwitcher from "./components/QuickSwitcher.svelte";
  import SessionDialog from "./components/SessionDialog.svelte";
  import Sidebar from "./components/Sidebar.svelte";
  import WorkspaceView from "./components/WorkspaceView.svelte";
  import * as core from "./lib/core";
  import { activeFind } from "./lib/find.svelte";
  import { ui } from "./lib/manage.svelte";
  import { nav } from "./lib/nav.svelte";
  import { arrange } from "./lib/spaces";
  import { applyTheme, prefs } from "./lib/prefs.svelte";
  import { model } from "./lib/state.svelte";
  import { updater } from "./lib/update.svelte";
  import type { HostConfig } from "./lib/types";

  let editing = $state<{ host: HostConfig | null } | null>(null);
  let linkDialog = $state<{ url: string | null } | null>(null);
  let addingSession = $state<HostConfig | null>(null);

  $effect(() => applyTheme(prefs.theme));
  // The Rust side words the tray, notifications and defaults in the same language.
  $effect(() => {
    document.documentElement.lang = i18n.lang;
    if (import.meta.env.MODE !== "mock") core.setLanguage(i18n.lang).catch(() => {});
  });

  onMount(() => {
    model
      .load()
      .then(() => openDemo(() => (editing = { host: null })))
      .catch((err) => (model.error = core.errorText(err)));
    if (import.meta.env.MODE !== "mock") updater.start();
    void core.onAddHostLink((url) => (linkDialog = { url }));
    void core.onOpenPane(({ hostId, workspaceId, paneId }) => {
      const workspace =
        workspaceId ||
        model.updates[hostId]?.board.find((a) => a.paneId === paneId)?.workspaceId ||
        null;
      model.select(hostId, workspace, paneId);
    });
    core
      .pendingLinks()
      .then((urls) => urls[0] && (linkDialog = { url: urls[0] }))
      .catch(() => {});
  });

  // Shortcuts like the Mac app's menu commands, with Ctrl for Cmd (Cmd
  // also works on the Mac during development). Ctrl+Alt is AltGr on
  // Windows, so a key typed with AltGr is never taken.
  function onKey(event: KeyboardEvent) {
    const mod = event.ctrlKey || event.metaKey;
    const key = event.key;
    const handled = (() => {
      if (event.getModifierState("AltGraph")) return false;
      if (mod && event.altKey && nav.keySender) {
        const arrows: Record<string, string> = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right" };
        const digit = event.code.match(/^(?:Digit|Numpad)([1-3])$/)?.[1];
        if (digit && nav.keySender.blocked) return nav.keySender.send([digit]), true;
        if (arrows[key]) return nav.keySender.send([arrows[key]]), true;
        return false;
      }
      if (mod && event.shiftKey && key === "Enter" && nav.keySender) return nav.keySender.send(["enter"]), true;
      if (mod && !event.shiftKey && key === "." && nav.keySender) return nav.keySender.send(["esc"]), true;
      if (mod && !event.altKey && key.toLowerCase() === "k") return (nav.switcherOpen = true), true;
      if (mod && !event.altKey && key.toLowerCase() === "f" && activeFind.find) return activeFind.find.show(), true;
      if (key === "F3" && activeFind.find) {
        if (!activeFind.find.open) activeFind.find.show();
        else activeFind.find.step(event.shiftKey ? -1 : 1, activeFind.matches);
        return true;
      }
      // Tabs: Ctrl+Shift+[ / ] by key position (any layout), Ctrl+PageUp/Down.
      if (mod && nav.stepTab && ((event.shiftKey && event.code === "BracketLeft") || key === "PageUp")) {
        return nav.stepTab(-1), true;
      }
      if (mod && nav.stepTab && ((event.shiftKey && event.code === "BracketRight") || key === "PageDown")) {
        return nav.stepTab(1), true;
      }
      if (mod && !event.altKey && !event.shiftKey && /^Digit[1-9]$/.test(event.code)) {
        return selectSpace(Number(event.code.slice(5))), true;
      }
      if (mod && (key === "+" || key === "=")) return prefs.zoom(1), true;
      if (mod && key === "-") return prefs.zoom(-1), true;
      if (mod && event.code === "Digit0") return prefs.zoom(null), true;
      return false;
    })();
    if (handled) event.preventDefault();
  }

  /** Ctrl+1 to Ctrl+9: the spaces of the current host in sidebar order. */
  function selectSpace(number: number) {
    const hostId = model.selection?.hostId ?? model.hosts[0]?.id;
    const update = hostId ? model.updates[hostId] : undefined;
    const space = update ? arrange(update)[number - 1] : undefined;
    if (hostId && space) model.select(hostId, space.workspace.workspaceId);
  }
</script>

<svelte:window onkeydown={onKey} />

<div class="layout">
  <Sidebar
    addHost={() => (editing = { host: null })}
    addLink={() => (linkDialog = { url: null })}
    addSession={(host) => (addingSession = host)}
  />
  <main class="detail">
    {#if updater.available}
      <div class="update">
        {#if updater.state === "downloading"}
          {t("updateLoading", { version: updater.available.version })} {updater.progress ? `${updater.progress} %` : ""}
        {:else}
          {t("updateAvailable", { version: updater.available.version })}
          <button class="primary" onclick={() => updater.install()}>{t("updateInstall")}</button>
          {#if updater.error}<span class="update-error">{updater.error}</span>{/if}
        {/if}
      </div>
    {/if}
    {#if model.selectedHost && model.selectedWorkspace}
      {#key `${model.selectedHost.id}/${model.selectedWorkspace.workspaceId}`}
        <WorkspaceView host={model.selectedHost} workspace={model.selectedWorkspace} />
      {/key}
    {:else if model.selectedHost && model.selection?.workspaceId}
      <p class="placeholder-text">{t("spaceLoading")}</p>
    {:else if model.selectedHost}
      <div class="scroll">
        <HostPanel host={model.selectedHost} edit={() => (editing = { host: model.selectedHost ?? null })} />
      </div>
    {:else}
      <div class="placeholder">
        <h1>Amiscara Agents</h1>
        <p>{t("welcomeHint")}</p>
        <p>
          <button class="primary" onclick={() => (editing = { host: null })}>{t("addHost")}</button>
          <button onclick={() => (linkDialog = { url: null })}>{t("pasteLink")}</button>
        </p>
        {#if model.info}
          <p class="meta">{t("versionInfo", { version: model.info.version, protocol: model.info.protocol })}</p>
        {/if}
      </div>
    {/if}
    {#if model.error}<p class="error">{model.error}</p>{/if}
  </main>
</div>

{#if editing}
  <HostEditor host={editing.host} close={() => (editing = null)} />
{/if}
{#if addingSession}
  <SessionDialog
    host={addingSession}
    close={() => (addingSession = null)}
    pick={(draft) => {
      addingSession = null;
      editing = { host: draft };
    }}
  />
{/if}
{#if linkDialog}
  <LinkDialog url={linkDialog.url} close={() => (linkDialog = null)} />
{/if}
<ManageDialogs />
{#if ui.menu}
  <ContextMenu x={ui.menu.x} y={ui.menu.y} items={ui.menu.items} close={() => (ui.menu = null)} />
{/if}
{#if nav.switcherOpen}
  <QuickSwitcher close={() => (nav.switcherOpen = false)} />
{/if}

<style>
  .layout {
    display: grid;
    grid-template-columns: 280px 1fr;
    height: 100%;
  }
  .detail {
    min-width: 0;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }
  .detail > :global(*) {
    flex: 1;
    min-height: 0;
  }
  .scroll {
    overflow: auto;
  }
  .placeholder {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    text-align: center;
  }
  .placeholder-text {
    padding: 24px;
    color: var(--secondary);
  }
  h1 {
    font-size: 20px;
    margin: 0 0 8px;
  }
  .placeholder p {
    color: var(--secondary);
    margin: 4px 0;
  }
  .meta {
    font-size: 12px;
  }
  .update {
    flex: none !important;
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 6px 12px;
    background: color-mix(in srgb, var(--accent) 15%, var(--bg));
    border-bottom: 1px solid var(--line);
  }
  .update-error {
    color: var(--danger);
    font-size: 12px;
  }
  .error {
    flex: none !important;
    color: var(--danger);
    padding: 0 24px;
  }
</style>
