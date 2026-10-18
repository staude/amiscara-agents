<script lang="ts">
  import { onMount } from "svelte";
  import HostEditor from "./components/HostEditor.svelte";
  import HostPanel from "./components/HostPanel.svelte";
  import LinkDialog from "./components/LinkDialog.svelte";
  import Sidebar from "./components/Sidebar.svelte";
  import WorkspaceView from "./components/WorkspaceView.svelte";
  import * as core from "./lib/core";
  import { activeFind } from "./lib/find.svelte";
  import { prefs } from "./lib/prefs.svelte";
  import { model } from "./lib/state.svelte";
  import type { HostConfig } from "./lib/types";

  let editing = $state<{ host: HostConfig | null } | null>(null);
  let linkDialog = $state<{ url: string | null } | null>(null);

  onMount(() => {
    model.load().catch((err) => (model.error = core.errorText(err)));
    void core.onAddHostLink((url) => (linkDialog = { url }));
    core
      .pendingLinks()
      .then((urls) => urls[0] && (linkDialog = { url: urls[0] }))
      .catch(() => {});
  });

  // Ctrl+F and F3 search the selected pane, Ctrl+plus/minus/0 zoom the
  // terminal (Cmd on the Mac during development).
  function onKey(event: KeyboardEvent) {
    const mod = event.ctrlKey || event.metaKey;
    if (mod && !event.altKey && event.key.toLowerCase() === "f" && activeFind.find) {
      event.preventDefault();
      activeFind.find.show();
    } else if (event.key === "F3" && activeFind.find) {
      event.preventDefault();
      if (!activeFind.find.open) activeFind.find.show();
      else activeFind.find.step(event.shiftKey ? -1 : 1, activeFind.matches);
    } else if (mod && (event.key === "+" || event.key === "=")) {
      event.preventDefault();
      prefs.zoom(1);
    } else if (mod && event.key === "-") {
      event.preventDefault();
      prefs.zoom(-1);
    } else if (mod && event.key === "0") {
      event.preventDefault();
      prefs.zoom(null);
    }
  }
</script>

<svelte:window onkeydown={onKey} />

<div class="layout">
  <Sidebar addHost={() => (editing = { host: null })} addLink={() => (linkDialog = { url: null })} />
  <main class="detail">
    {#if model.selectedHost && model.selectedWorkspace}
      {#key `${model.selectedHost.id}/${model.selectedWorkspace.workspaceId}`}
        <WorkspaceView host={model.selectedHost} workspace={model.selectedWorkspace} />
      {/key}
    {:else if model.selectedHost && model.selection?.workspaceId}
      <p class="placeholder-text">Space wird geladen …</p>
    {:else if model.selectedHost}
      <div class="scroll">
        <HostPanel host={model.selectedHost} edit={() => (editing = { host: model.selectedHost ?? null })} />
      </div>
    {:else}
      <div class="placeholder">
        <h1>Amiscara Agents</h1>
        <p>Fügen Sie einen Host hinzu, um seine Agents zu sehen.</p>
        <p>
          <button class="primary" onclick={() => (editing = { host: null })}>Host hinzufügen</button>
          <button onclick={() => (linkDialog = { url: null })}>Link einfügen</button>
        </p>
        {#if model.info}
          <p class="meta">Version {model.info.version}, herdr-Protokoll {model.info.protocol}</p>
        {/if}
      </div>
    {/if}
    {#if model.error}<p class="error">{model.error}</p>{/if}
  </main>
</div>

{#if editing}
  <HostEditor host={editing.host} close={() => (editing = null)} />
{/if}
{#if linkDialog}
  <LinkDialog url={linkDialog.url} close={() => (linkDialog = null)} />
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
  .error {
    flex: none !important;
    color: var(--danger);
    padding: 0 24px;
  }
</style>
