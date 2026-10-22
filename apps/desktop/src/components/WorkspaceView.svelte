<script lang="ts">
  import { t } from "../lib/i18n.svelte";
  import { untrack } from "svelte";
  import * as core from "../lib/core";
  import { demo } from "../lib/demo.svelte";
  import { canWrite, closeSpace, openMenu, repositoryOf, ui, type MenuItem } from "../lib/manage.svelte";
  import { nav } from "../lib/nav.svelte";
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
  // The screenshot demo opens the conversation of its pane once (#199).
  $effect(() => {
    const target = demo.target;
    if (target?.view === "conversation" && target.pane && model.selection?.paneId === target.pane) {
      untrack(() => (conversationFor = target.pane ?? null));
      demo.target = { ...target, view: undefined };
    }
  });
  let tabError = $state<string | null>(null);
  let agentKinds = $state<string[]>([]);

  $effect(() => {
    core.agentKinds(host.id).then((kinds) => (agentKinds = kinds)).catch(() => {});
  });

  // Ctrl+Shift+[ and ]: the neighbouring tab, wrapping around like herdr.
  $effect(() => {
    const step = (delta: number) => {
      const tabs = workspace.tabs;
      if (tabs.length < 2) return;
      const at = Math.max(0, tabs.findIndex((other) => other.tabId === tabId));
      selectTab(tabs[(at + (delta % tabs.length) + tabs.length) % tabs.length]);
    };
    nav.stepTab = step;
    return () => {
      if (nav.stepTab === step) nav.stepTab = null;
    };
  });

  // The pane on screen gets no notifications while the window has focus.
  $effect(() => {
    void core.setVisiblePane(host.id, paneId);
    return () => void core.setVisiblePane(null, null);
  });

  /** Creates a tab and shows it; with `agent` that agent starts in it. */
  async function newTab(agent: string | null = null) {
    tabError = null;
    try {
      const created = await core.createTab(host.id, workspace.workspaceId);
      tabId = created.tabId;
      paneId = created.paneId;
      if (agent) await core.startAgent(host.id, created.paneId, agent);
    } catch (err) {
      tabError = core.errorText(err);
    }
  }

  function tabMenu(item: TabItem): (MenuItem | null)[] {
    return [
      {
        label: t("renameMenu"),
        disabled: !canWrite(host.id),
        action: () => (ui.dialog = { kind: "rename", hostId: host.id, target: "tab", id: item.tabId, current: item.label }),
      },
      null,
      { label: t("closeTabMenu"), danger: true, disabled: !canWrite(host.id), action: () => closeTab(item) },
    ];
  }

  function closeTab(item: TabItem) {
    ui.dialog = {
      kind: "close",
      hostId: host.id,
      target: "tab",
      id: item.tabId,
      name: item.label,
      agentState: item.agentState,
      worktrees: 0,
    };
  }

  /** "New tab with agent", worktree and close, also without right click. */
  function moreMenu(event: MouseEvent) {
    const repo = repositoryOf(workspace, model.updates[host.id]?.workspaces ?? []);
    openMenu(event, [
      ...agentKinds.map((kind) => ({ label: t("newTabWith", { agent: kind }), action: () => void newTab(kind) })),
      null,
      ...(repo
        ? [{ label: t("newWorktreeMenu"), action: () => (ui.dialog = { kind: "newWorktree", hostId: host.id, repository: repo }) }]
        : []),
      ...(tab ? [{ label: t("closeTabMenu"), danger: true, action: () => tab && closeTab(tab) }] : []),
      { label: t("closeSpaceMenu"), danger: true, action: () => closeSpace(host.id, workspace) },
    ]);
  }

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
    const byPane = wanted ? tabs.find((item) => item.panes.some((p) => p.paneId === wanted)) : undefined;
    if (byPane && wanted) {
      tabId = byPane.tabId;
      paneId = wanted;
    } else {
      selectTab(tabs.find((item) => item.tabId === workspace.activeTabId) ?? tabs[0]);
    }
  }

  // The shown tab was closed: herdr's active tab instead.
  $effect(() => {
    if (tabId && !workspace.tabs.some((item) => item.tabId === tabId)) {
      selectTab(workspace.tabs.find((item) => item.tabId === workspace.activeTabId) ?? workspace.tabs[0]);
    }
  });

  function selectTab(tab: TabItem | undefined) {
    tabId = tab?.tabId ?? null;
    paneId = (tab?.panes.find((p) => p.focused) ?? tab?.panes[0])?.paneId ?? null;
  }

  let tab = $derived(workspace.tabs.find((item) => item.tabId === tabId));
  let pane = $derived(tab?.panes.find((p) => p.paneId === paneId));
  // herdr's zoom is ignored on purpose: the window has room for all panes.
  let layout = $derived(tab?.layout && tab.layout.panes.length > 1 ? tab.layout : null);
</script>

<section class="space">
  <nav class="tabs">
    {#each workspace.tabs as item (item.tabId)}
      <button
        class="tab"
        class:current={item.tabId === tabId}
        onclick={() => selectTab(item)}
        oncontextmenu={(e) => openMenu(e, tabMenu(item))}
      >
        {item.label}
        {#if item.agentState !== "idle" && item.agentState !== "unknown"}<StatusDot state={item.agentState} />{/if}
      </button>
    {/each}
    {#if canWrite(host.id)}
      <button class="tool" title={t("newTab")} onclick={() => newTab()}>+</button>
      <button class="tool" title={t("moreTabActions")} onclick={moreMenu}>✦</button>
    {/if}
    <span class="spacer"></span>
    <span class="where">
      {workspace.worktreeName ?? workspace.name}{workspace.group ? ` (${workspace.group})` : ""} · {host.name}
    </span>
  </nav>
  {#if tabError}<p class="tab-error">{tabError}</p>{/if}

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
      <p class="empty">{t("noPaneInTab")}</p>
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
  .tool {
    border: none;
    background: none;
    padding: 2px 8px;
    color: var(--secondary);
  }
  .tab-error {
    color: var(--danger);
    font-size: 12px;
    margin: 4px 10px;
    user-select: text;
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
