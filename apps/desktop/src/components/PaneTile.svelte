<script lang="ts">
  import { t } from "../lib/i18n.svelte";
  import { untrack } from "svelte";
  import { activeFind, FindState } from "../lib/find.svelte";
  import { PaneModel } from "../lib/pane.svelte";
  import { openFolderInEditor } from "../lib/manage.svelte";
  import { findMatches } from "../lib/search";
  import { stateLabel } from "../lib/spaces";
  import { model as app } from "../lib/state.svelte";
  import type { PaneItem } from "../lib/types";
  import SearchBar from "./SearchBar.svelte";
  import StatusDot from "./StatusDot.svelte";
  import Terminal from "./Terminal.svelte";

  // `selected`: the pane the input bar and the shortcuts act on; it alone
  // is read at full pace and may load history. `fitColumns` for split tabs.
  let {
    hostId,
    paneId,
    pane,
    selected,
    fitColumns = null,
    framed = false,
    select = () => {},
    openConversation,
  }: {
    hostId: string;
    paneId: string;
    pane: PaneItem | undefined;
    selected: boolean;
    fitColumns?: number | null;
    framed?: boolean;
    select?: () => void;
    openConversation: () => void;
  } = $props();

  let pane_model = $state<PaneModel | null>(null);
  const find = new FindState();
  let copied = $state(false);

  // One follower per pane and session; a new session (reconnect) ends the
  // old follower, so its generation is part of the key.
  $effect(() => {
    void app.generations[hostId];
    // The pace follows `selected` below without a new follower.
    const created = new PaneModel(hostId, paneId, untrack(() => selected));
    pane_model = created;
    return () => created.stop();
  });

  $effect(() => {
    pane_model?.setLive(selected);
    if (!selected) find.close();
  });

  let matches = $derived(find.open && pane_model ? findMatches(find.query, pane_model.content) : []);

  // The selected tile owns Ctrl+F and F3.
  $effect(() => {
    if (!selected) return;
    activeFind.find = find;
    activeFind.matches = matches;
    return () => {
      if (activeFind.find === find) {
        activeFind.find = null;
        activeFind.matches = [];
      }
    };
  });

  async function copyText() {
    if (!pane_model) return;
    await navigator.clipboard.writeText(pane_model.plainText);
    copied = true;
    setTimeout(() => (copied = false), 1500);
  }

  let title = $derived(pane ? pane.title || pane.paneId : paneId);
  let live = $derived(app.isLive(hostId));
</script>

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
<div class="tile" class:framed class:selected={framed && selected} onmousedown={select}>
  <header class:compact={framed}>
    <StatusDot state={pane?.agent ? pane.agentState : null} />
    <span class="title">{title}</span>
    {#if pane?.agent}<span class="secondary">{pane.name ? `${pane.name} · ${pane.agent}` : pane.agent}</span>{/if}
    <span class="spacer"></span>
    {#if pane?.agent}<span class="state {pane.agentState}">{stateLabel(pane.agentState)}</span>{/if}
    {#if selected}
      {#if pane?.agent === "claude"}
        <button class="flat" title={t("conversationFromClaude")} onclick={openConversation}>💬</button>
      {/if}
      <button class="flat" title={t("copyPaneText")} disabled={!pane_model?.content} onclick={copyText}>
        {copied ? "✓" : "⧉"}
      </button>
      <button class="flat" title={t("findInPane")} onclick={() => find.show()}>⌕</button>
      <button class="flat" title={t("openInVSCode")} onclick={() => openFolderInEditor(hostId, { paneId })}>&lt;/&gt;</button>
    {/if}
  </header>
  {#if selected && find.open}
    <SearchBar {find} {matches} />
  {/if}
  <div class="screen">
    {#if pane_model}
      <Terminal
        model={pane_model}
        history={selected}
        {fitColumns}
        {matches}
        current={find.current(matches)}
        scrollRequest={find.scrollRequest}
      />
    {/if}
    {#if pane_model?.error && pane_model.content}
      <div class="banner">⚠ {pane_model.error}</div>
    {:else if !live && pane_model?.content}
      <div class="banner">{t("connectionLostStale")}</div>
    {/if}
  </div>
</div>

<style>
  .tile {
    display: flex;
    flex-direction: column;
    height: 100%;
    min-height: 0;
    min-width: 0;
    box-sizing: border-box;
  }
  .framed {
    border: 1px solid color-mix(in srgb, var(--secondary) 35%, transparent);
    border-radius: 4px;
    overflow: hidden;
  }
  .framed.selected {
    border: 2px solid var(--accent);
  }
  header {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 12px;
    border-bottom: 1px solid var(--line);
    background: var(--sidebar);
    min-width: 0;
  }
  header.compact {
    padding: 3px 8px;
    font-size: 12px;
  }
  .selected header {
    background: color-mix(in srgb, var(--accent) 20%, var(--sidebar));
  }
  .title {
    font-weight: 600;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .secondary {
    color: var(--secondary);
    white-space: nowrap;
  }
  .spacer {
    flex: 1;
  }
  .state {
    white-space: nowrap;
  }
  .state.blocked {
    color: var(--blocked);
  }
  .state.working {
    color: var(--working);
  }
  .state.done {
    color: var(--done);
  }
  .flat {
    border: none;
    background: none;
    padding: 0 4px;
  }
  .screen {
    position: relative;
    flex: 1;
    min-height: 0;
  }
  .banner {
    position: absolute;
    top: 8px;
    left: 50%;
    transform: translateX(-50%);
    background: var(--bg);
    border: 1px solid var(--line);
    border-radius: 999px;
    padding: 3px 10px;
    font-size: 12px;
    user-select: text;
  }
</style>
