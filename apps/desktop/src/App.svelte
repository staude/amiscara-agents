<script lang="ts">
  import { onMount } from "svelte";
  import HostEditor from "./components/HostEditor.svelte";
  import HostPanel from "./components/HostPanel.svelte";
  import LinkDialog from "./components/LinkDialog.svelte";
  import PaneView from "./components/PaneView.svelte";
  import StatusDot from "./components/StatusDot.svelte";
  import * as core from "./lib/core";
  import { model } from "./lib/state.svelte";
  import type { HostConfig, HostStatus, PaneItem } from "./lib/types";

  let editing = $state<{ host: HostConfig | null } | null>(null);
  let linkDialog = $state<{ url: string | null } | null>(null);
  let selectedPaneId = $state<string | null>(null);

  onMount(() => {
    model.load().catch((err) => (model.error = core.errorText(err)));
    void core.onAddHostLink((url) => (linkDialog = { url }));
    core
      .pendingLinks()
      .then((urls) => urls[0] && (linkDialog = { url: urls[0] }))
      .catch(() => {});
  });

  let update = $derived(model.selectedHostId ? model.updates[model.selectedHostId] : undefined);
  let workspaces = $derived(
    update
      ? update.spaceOrder
          .map((slot) => update.workspaces.find((w) => w.workspaceId === slot.workspaceId))
          .filter((w) => w !== undefined)
      : [],
  );
  let selectedPane = $derived<PaneItem | undefined>(
    workspaces.flatMap((w) => w.tabs.flatMap((t) => t.panes)).find((p) => p.paneId === selectedPaneId),
  );

  function selectHost(id: string) {
    model.selectedHostId = id;
    selectedPaneId = null;
  }

  function hostDot(status: HostStatus | undefined): string {
    switch (status?.kind) {
      case "live":
        return "live";
      case "retrying":
      case "hostKeyUnknown":
      case "hostKeyChanged":
        return "warn";
      case "failed":
        return "bad";
      default:
        return "wait";
    }
  }
</script>

<div class="layout">
  <aside class="sidebar">
    <div class="title">
      <h2>Hosts</h2>
      <span class="tools">
        <button class="icon" title="Host aus Link hinzufügen" onclick={() => (linkDialog = { url: null })}>⧉</button>
        <button class="icon" title="Host hinzufügen" onclick={() => (editing = { host: null })}>+</button>
      </span>
    </div>
    {#if model.hosts.length === 0}
      <p class="empty">Noch keine Hosts</p>
    {/if}
    <ul class="hosts">
      {#each model.hosts as host (host.id)}
        <li>
          <button
            class="host"
            class:selected={host.id === model.selectedHostId}
            onclick={() => selectHost(host.id)}
          >
            <span class="conn {hostDot(model.updates[host.id]?.status)}"></span>
            {host.name}
          </button>
          {#if host.id === model.selectedHostId}
            <ul class="tree">
              {#each workspaces as space (space.workspaceId)}
                <li class="space">
                  <StatusDot state={space.agentState} />
                  <span>{space.label}</span>
                  {#if space.branch}<span class="branch">{space.branch}</span>{/if}
                </li>
                {#each space.tabs as tab (tab.tabId)}
                  {#each tab.panes as pane (pane.paneId)}
                    <li>
                      <button
                        class="pane"
                        class:selected={pane.paneId === selectedPaneId}
                        onclick={() => (selectedPaneId = pane.paneId)}
                      >
                        <StatusDot state={pane.agent ? pane.agentState : null} />
                        <span class="label">{pane.agent ? (pane.name ?? pane.agent) : pane.title || tab.label}</span>
                      </button>
                    </li>
                  {/each}
                {/each}
              {/each}
            </ul>
          {/if}
        </li>
      {/each}
    </ul>
  </aside>
  <main class="detail">
    {#if model.selectedHost && selectedPane}
      <PaneView host={model.selectedHost} pane={selectedPane} />
    {:else if model.selectedHost}
      <HostPanel host={model.selectedHost} edit={() => (editing = { host: model.selectedHost ?? null })} />
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
    grid-template-columns: 260px 1fr;
    height: 100%;
  }
  .sidebar {
    background: var(--sidebar);
    border-right: 1px solid var(--line);
    padding: 12px 10px;
    overflow: auto;
  }
  .title {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 6px;
  }
  h2 {
    font-size: 12px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--secondary);
    margin: 4px 0 8px;
  }
  .icon {
    border: none;
    background: none;
    font-size: 16px;
    padding: 2px 6px;
    color: var(--secondary);
  }
  .empty {
    color: var(--secondary);
    padding: 0 6px;
  }
  ul {
    list-style: none;
    margin: 0;
    padding: 0;
  }
  .host,
  .pane {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    text-align: left;
    border: none;
    background: none;
    border-radius: 6px;
    padding: 5px 6px;
    color: var(--text);
  }
  .host {
    font-weight: 600;
  }
  .selected {
    background: color-mix(in srgb, var(--accent) 18%, transparent);
  }
  .conn {
    width: 8px;
    height: 8px;
    border-radius: 50%;
  }
  .conn.live {
    background: #30d158;
  }
  .conn.warn {
    background: #ff9500;
  }
  .conn.bad {
    background: #d70015;
  }
  .conn.wait {
    background: var(--secondary);
    opacity: 0.5;
  }
  .tree {
    margin: 2px 0 8px 12px;
  }
  .space {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 12px;
    color: var(--secondary);
    padding: 6px 6px 2px;
  }
  .branch {
    font-size: 11px;
    opacity: 0.8;
  }
  .pane .label {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .detail {
    min-width: 0;
    min-height: 0;
    overflow: auto;
  }
  .placeholder {
    height: 100%;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    text-align: center;
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
    color: #d70015;
    padding: 0 24px;
  }
</style>
