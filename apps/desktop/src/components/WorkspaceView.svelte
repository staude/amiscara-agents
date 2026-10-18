<script lang="ts">
  import { untrack } from "svelte";
  import { model } from "../lib/state.svelte";
  import type { HostConfig, TabItem, WorkspaceItem } from "../lib/types";
  import Conversation from "./Conversation.svelte";
  import InputBar from "./InputBar.svelte";
  import PaneTile from "./PaneTile.svelte";
  import StatusDot from "./StatusDot.svelte";

  let { host, workspace }: { host: HostConfig; workspace: WorkspaceItem } = $props();

  let tabId = $state<string | null>(null);
  let paneId = $state<string | null>(null);
  let conversationFor = $state<string | null>(null);

  // An agent picks its own tab and pane; a space opens on herdr's active tab.
  // Only a new selection does this, not every update of the space.
  $effect(() => {
    const sel = model.selection;
    untrack(() => {
      if (sel?.workspaceId === workspace.workspaceId) focus(sel.paneId);
    });
  });

  function focus(wanted: string | null) {
    const tabs = workspace.tabs;
    const byPane = wanted ? tabs.find((t) => t.panes.some((p) => p.paneId === wanted)) : undefined;
    if (byPane && wanted) {
      tabId = byPane.tabId;
      paneId = wanted;
    } else {
      selectTab(tabs.find((t) => t.tabId === workspace.activeTabId) ?? tabs[0]);
    }
  }

  // The shown tab was closed: herdr's active tab instead.
  $effect(() => {
    if (tabId && !workspace.tabs.some((t) => t.tabId === tabId)) {
      selectTab(workspace.tabs.find((t) => t.tabId === workspace.activeTabId) ?? workspace.tabs[0]);
    }
  });

  function selectTab(tab: TabItem | undefined) {
    tabId = tab?.tabId ?? null;
    paneId = (tab?.panes.find((p) => p.focused) ?? tab?.panes[0])?.paneId ?? null;
  }

  let tab = $derived(workspace.tabs.find((t) => t.tabId === tabId));
  let pane = $derived(tab?.panes.find((p) => p.paneId === paneId));
  // herdr's zoom is ignored on purpose: the window has room for all panes.
  let layout = $derived(tab?.layout && tab.layout.panes.length > 1 ? tab.layout : null);
</script>

<section class="space">
  <nav class="tabs">
    {#each workspace.tabs as item (item.tabId)}
      <button class="tab" class:current={item.tabId === tabId} onclick={() => selectTab(item)}>
        {item.label}
        {#if item.agentState !== "idle" && item.agentState !== "unknown"}<StatusDot state={item.agentState} />{/if}
      </button>
    {/each}
    <span class="spacer"></span>
    <span class="where">
      {workspace.worktreeName ?? workspace.name}{workspace.group ? ` (${workspace.group})` : ""} · {host.name}
    </span>
  </nav>

  <div class="panes">
    {#if tab && layout}
      {#each layout.panes as frame (frame.paneId)}
        <div
          class="slot"
          style="left: {(frame.x / layout.columns) * 100}%; top: {(frame.y / layout.rows) * 100}%;
                 width: {(frame.width / layout.columns) * 100}%; height: {(frame.height / layout.rows) * 100}%"
        >
          <PaneTile
            hostId={host.id}
            paneId={frame.paneId}
            pane={tab.panes.find((p) => p.paneId === frame.paneId)}
            selected={frame.paneId === paneId}
            fitColumns={frame.width}
            framed
            select={() => (paneId = frame.paneId)}
            openConversation={() => (conversationFor = frame.paneId)}
          />
        </div>
      {/each}
    {:else if paneId}
      {#key paneId}
        <PaneTile
          hostId={host.id}
          {paneId}
          {pane}
          selected
          openConversation={() => (conversationFor = paneId)}
        />
      {/key}
    {:else}
      <p class="empty">Keine Pane in diesem Tab.</p>
    {/if}
  </div>

  {#if pane && (host.allowInput ?? true)}
    {#key pane.paneId}
      <InputBar {host} {pane} />
    {/key}
  {/if}
</section>

{#if conversationFor}
  <Conversation hostId={host.id} paneId={conversationFor} close={() => (conversationFor = null)} />
{/if}

<style>
  .space {
    display: flex;
    flex-direction: column;
    height: 100%;
    min-height: 0;
  }
  .tabs {
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 4px 8px;
    border-bottom: 1px solid var(--line);
    overflow-x: auto;
  }
  .tab {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    border: none;
    background: none;
    font-family: ui-monospace, "Cascadia Mono", Consolas, monospace;
    padding: 4px 14px;
    border-radius: 5px;
    white-space: nowrap;
  }
  .tab.current {
    background: color-mix(in srgb, var(--accent) 25%, transparent);
  }
  .spacer {
    flex: 1;
  }
  .where {
    color: var(--secondary);
    font-size: 12px;
    white-space: nowrap;
    padding-left: 12px;
  }
  .panes {
    position: relative;
    flex: 1;
    min-height: 0;
    background: var(--sidebar);
  }
  .slot {
    position: absolute;
    padding: 2px;
    box-sizing: border-box;
  }
  .empty {
    padding: 24px;
    color: var(--secondary);
  }
</style>
