<script lang="ts">
  import * as core from "../lib/core";
  import { prefs } from "../lib/prefs.svelte";
  import { arrange, blocks, sortedAgents, stateLabel } from "../lib/spaces";
  import { model } from "../lib/state.svelte";
  import type { HostConfig, HostStatus, SessionUpdate, WorkspaceItem } from "../lib/types";
  import StatusDot from "./StatusDot.svelte";

  let { addHost, addLink }: { addHost: () => void; addLink: () => void } = $props();

  function hostState(status: HostStatus | undefined): { css: string; label: string } {
    switch (status?.kind) {
      case "live":
        return { css: "live", label: "" };
      case "retrying":
        return { css: "warn", label: "versucht erneut" };
      case "hostKeyUnknown":
      case "hostKeyChanged":
        return { css: "warn", label: "Host-Key" };
      case "failed":
        return { css: "bad", label: "abgelehnt" };
      default:
        return { css: "wait", label: "verbinde …" };
    }
  }

  function isSpace(hostId: string, workspaceId: string) {
    const sel = model.selection;
    return sel?.hostId === hostId && sel.workspaceId === workspaceId && sel.paneId === null;
  }

  function isAgent(hostId: string, paneId: string) {
    const sel = model.selection;
    return sel?.hostId === hostId && sel.paneId === paneId;
  }

  function spaceTitle(workspace: WorkspaceItem, nested: boolean) {
    return nested ? (workspace.branch ?? workspace.worktreeName ?? workspace.label) : workspace.name;
  }

  function waitingIn(update: SessionUpdate, ids: string[]) {
    return update.board.filter((a) => a.agentState === "blocked" && ids.includes(a.workspaceId)).length;
  }

  function onHostKey(event: KeyboardEvent, host: HostConfig) {
    if (event.key === "Enter") model.select(host.id);
  }
</script>

<aside class="sidebar">
  <div class="top">
    <span class="app">Amiscara Agents</span>
    <span class="tools">
      <button class="icon" title="Host aus Link hinzufügen" onclick={addLink}>⧉</button>
      <button class="icon" title="Host hinzufügen" onclick={addHost}>+</button>
    </span>
  </div>

  {#if model.hosts.length === 0}
    <div class="empty">
      <p>Keine Hosts</p>
      <p class="small">Fügen Sie einen Rechner hinzu, auf dem herdr läuft.</p>
      <button class="primary" onclick={addHost}>Host hinzufügen</button>
    </div>
  {/if}

  {#each model.hosts as host (host.id)}
    {@const update = model.updates[host.id]}
    {@const state = hostState(update?.status)}
    <section>
      <div
        class="host"
        class:selected={model.selection?.hostId === host.id && model.selection.workspaceId === null}
        role="button"
        tabindex="0"
        onclick={() => model.select(host.id)}
        onkeydown={(e) => onHostKey(e, host)}
        title="Einstellungen und Verbindung"
      >
        <span class="glyph">{host.kind === "local" ? "▣" : "⇄"}</span>
        <span class="name">{host.name}</span>
        {#if state.label}<span class="small {state.css}-text">{state.label}</span>{/if}
        <span class="conn {state.css}"></span>
      </div>

      {#if update}
        {@const spacesFolded = prefs.isCollapsed(host.id, "spaces")}
        <button class="section" onclick={() => prefs.toggle(host.id, "spaces")}>
          <span class="chevron" class:open={!spacesFolded}>›</span> spaces
          {#if spacesFolded}<span class="small">{update.workspaces.length}</span>{/if}
        </button>
        {#if !spacesFolded}
          {#each blocks(arrange(update)) as block (block.kind === "space" ? block.entry.workspace.workspaceId : `group/${block.name}`)}
            {#if block.kind === "group"}
              {@const key = `group/${block.name}`}
              {@const folded = prefs.isCollapsed(host.id, key)}
              {@const waiting = waitingIn(update, block.entries.map((e) => e.workspace.workspaceId))}
              <button class="row group" onclick={() => prefs.toggle(host.id, key)}>
                <span class="chevron" class:open={!folded}>›</span>
                <span class="label">{block.name}</span>
                {#if waiting > 0}<span class="small blocked-text">{waiting} wartet</span>{/if}
                <span class="small">{block.entries.length}</span>
              </button>
            {/if}
            {#each block.kind === "space" ? [block.entry] : prefs.isCollapsed(host.id, `group/${block.name}`) ? [] : block.entries as entry (entry.workspace.workspaceId)}
              <button
                class="row space"
                class:grouped={block.kind === "group"}
                class:selected={isSpace(host.id, entry.workspace.workspaceId)}
                onclick={() => model.select(host.id, entry.workspace.workspaceId)}
              >
                {#if entry.nested}<span class="nest">└</span>{/if}
                <StatusDot state={entry.workspace.agentState} />
                <span class="lines">
                  <span class="label">{spaceTitle(entry.workspace, entry.nested)}</span>
                  {#if !entry.nested && entry.workspace.branch}
                    <span class="sub mono">{entry.workspace.branch}</span>
                  {/if}
                  {#if entry.workspace.tokens.length > 0}
                    <span class="sub">{entry.workspace.tokens.map((t) => t.value).join(" · ")}</span>
                  {/if}
                </span>
              </button>
            {/each}
          {/each}
        {/if}

        {#if update.board.length > 0}
          {@const agentsFolded = prefs.isCollapsed(host.id, "agents")}
          {@const waiting = update.board.filter((a) => a.agentState === "blocked").length}
          <div class="section-row">
            <button class="section" onclick={() => prefs.toggle(host.id, "agents")}>
              <span class="chevron" class:open={!agentsFolded}>›</span> agents
              {#if agentsFolded}
                <span class="small" class:blocked-text={waiting > 0}>
                  {update.board.length}{waiting > 0 ? `, ${waiting} wartet` : ""}
                </span>
              {/if}
            </button>
            <button class="order" onclick={() => prefs.toggleAgentOrder()} title="Sortierung umschalten">
              {prefs.agentOrder === "grouped" ? "grouped" : "nach Status"}
            </button>
          </div>
          {#if !agentsFolded}
            {#each sortedAgents(update, prefs.agentOrder) as entry (entry.agent.paneId)}
              <button
                class="row agent"
                class:selected={isAgent(host.id, entry.agent.paneId)}
                onclick={() => model.select(host.id, entry.agent.workspaceId, entry.agent.paneId)}
              >
                <StatusDot state={entry.agent.agentState} />
                <span class="lines">
                  <span class="label">
                    {entry.tabNumber ? `${entry.agent.workspaceName} · ${entry.tabNumber}` : entry.agent.workspaceName}
                    {#if entry.agent.workspaceGroup}<span class="small">{entry.agent.workspaceGroup}</span>{/if}
                    {#if entry.agent.agentState !== "idle"}
                      <span class="small {entry.agent.agentState}-text">{stateLabel[entry.agent.agentState]}</span>
                    {/if}
                  </span>
                  <span class="sub">
                    {entry.agent.name ? `${entry.agent.name} · ${entry.agent.agent}` : entry.agent.agent}
                  </span>
                </span>
              </button>
            {/each}
          {/if}
        {/if}
      {:else}
        <button class="row retry" onclick={() => core.connect(host.id)}>Jetzt verbinden</button>
      {/if}
    </section>
  {/each}
</aside>

<style>
  .sidebar {
    background: var(--sidebar);
    border-right: 1px solid var(--line);
    padding: 8px 8px 16px;
    overflow: auto;
    height: 100%;
    box-sizing: border-box;
  }
  .top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 2px 4px 8px;
  }
  .app {
    font-weight: 600;
  }
  .icon {
    border: none;
    background: none;
    font-size: 16px;
    padding: 2px 6px;
    color: var(--secondary);
  }
  .empty {
    padding: 24px 8px;
    text-align: center;
  }
  section {
    margin-bottom: 10px;
  }
  .host {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px;
    border-radius: 6px;
    font-weight: 600;
  }
  .host .name {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .glyph {
    color: var(--secondary);
  }
  .conn {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex: none;
  }
  .conn.live {
    background: var(--done);
  }
  .conn.warn {
    background: var(--blocked);
  }
  .conn.bad {
    background: var(--danger);
  }
  .conn.wait {
    background: var(--secondary);
    opacity: 0.5;
  }
  button.section,
  button.order {
    border: none;
    background: none;
    padding: 6px 6px 2px;
    font-size: 12px;
    font-weight: 600;
    color: var(--secondary);
  }
  button.order {
    font-weight: 400;
  }
  .section-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .chevron {
    display: inline-block;
    width: 10px;
    transition: transform 0.15s;
  }
  .chevron.open {
    transform: rotate(90deg);
  }
  .row {
    display: flex;
    align-items: flex-start;
    gap: 6px;
    width: 100%;
    text-align: left;
    border: none;
    background: none;
    border-radius: 6px;
    padding: 4px 6px;
    color: var(--text);
  }
  .row :global(.dot) {
    margin-top: 5px;
  }
  .row.group {
    align-items: center;
    font-weight: 500;
  }
  .row.group .label {
    flex: 1;
  }
  .row.grouped {
    padding-left: 22px;
  }
  .nest {
    color: var(--secondary);
    opacity: 0.6;
    padding-left: 8px;
  }
  .lines {
    display: flex;
    flex-direction: column;
    min-width: 0;
  }
  .label,
  .sub {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .sub {
    font-size: 12px;
    color: var(--secondary);
  }
  .mono {
    font-family: ui-monospace, "Cascadia Mono", Consolas, monospace;
  }
  .small {
    font-size: 12px;
    color: var(--secondary);
    font-weight: 400;
  }
  .selected {
    background: color-mix(in srgb, var(--accent) 18%, transparent);
  }
  .retry {
    color: var(--accent);
  }
  .blocked-text,
  .warn-text {
    color: var(--blocked) !important;
  }
  .working-text {
    color: var(--working) !important;
  }
  .done-text {
    color: var(--done) !important;
  }
  .bad-text {
    color: var(--danger) !important;
  }
</style>
