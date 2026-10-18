<script lang="ts">
  import * as core from "../lib/core";
  import { spanStyle, stateLabel } from "../lib/term";
  import type { HostConfig, PaneContent, PaneItem } from "../lib/types";
  import StatusDot from "./StatusDot.svelte";

  let { host, pane }: { host: HostConfig; pane: PaneItem } = $props();

  let content = $state<PaneContent | null>(null);
  let error = $state<string | null>(null);
  let prompt = $state("");
  let screen: HTMLElement | undefined = $state();

  // One follower per shown pane; switching panes stops the old one.
  $effect(() => {
    const hostId = host.id;
    const paneId = pane.paneId;
    content = null;
    error = null;
    let stop: (() => void) | null = null;
    let gone = false;
    core
      .followPane(hostId, paneId, true, (event) => {
        if (event.kind === "content") {
          content = event.data;
          error = null;
        } else {
          error = event.data;
        }
      })
      .then((fn) => (gone ? fn() : (stop = fn)))
      .catch((err) => (error = core.errorText(err)));
    return () => {
      gone = true;
      stop?.();
    };
  });

  $effect(() => {
    if (content && screen) screen.scrollTop = screen.scrollHeight;
  });

  async function send(event: SubmitEvent) {
    event.preventDefault();
    const text = prompt.trim();
    if (!text) return;
    try {
      await core.sendPrompt(host.id, pane.paneId, text);
      prompt = "";
    } catch (err) {
      error = core.errorText(err);
    }
  }

  async function key(name: string) {
    try {
      await core.sendKeys(host.id, pane.paneId, [name]);
    } catch (err) {
      error = core.errorText(err);
    }
  }
</script>

<section class="pane">
  <header>
    <StatusDot state={pane.agent ? pane.agentState : null} />
    <strong>{pane.title || pane.paneId}</strong>
    {#if pane.agent}<span class="secondary">{pane.name ?? pane.agent}</span>{/if}
    <span class="spacer"></span>
    {#if pane.agent}<span class="state {pane.agentState}">{stateLabel[pane.agentState]}</span>{/if}
    <span class="secondary">{host.name}</span>
  </header>
  {#if error}<div class="banner">{error}</div>{/if}
  <div class="screen" bind:this={screen}>
    {#if content}
      {#each content.lines as line, index (index)}
        <div class="line">{#each line.spans as span, spanIndex (spanIndex)}<span style={spanStyle(span)}>{span.text}</span>{/each}</div>
      {/each}
    {:else if !error}
      <p class="secondary">Lade …</p>
    {/if}
  </div>
  {#if host.allowInput ?? true}
    <form class="input" onsubmit={send}>
      <button type="button" onclick={() => key("esc")} title="Escape">Esc</button>
      <button type="button" onclick={() => key("1")} title="Option 1 wählen">1</button>
      <button type="button" onclick={() => key("enter")} title="Enter">⏎</button>
      <input bind:value={prompt} placeholder="Prompt an den Agent" />
      <button type="submit" class="primary" disabled={!prompt.trim()}>Senden</button>
    </form>
  {/if}
</section>

<style>
  .pane {
    display: flex;
    flex-direction: column;
    height: 100%;
    min-height: 0;
  }
  header {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    border-bottom: 1px solid var(--line);
  }
  .spacer {
    flex: 1;
  }
  .secondary {
    color: var(--secondary);
  }
  .state.blocked {
    color: #ff9500;
  }
  .state.working {
    color: #0a84ff;
  }
  .state.done {
    color: #30d158;
  }
  .banner {
    background: #ff950022;
    padding: 6px 12px;
    font-size: 12px;
  }
  .screen {
    flex: 1;
    overflow: auto;
    background: var(--term-bg);
    color: var(--term-fg);
    font-family: ui-monospace, "Cascadia Mono", Consolas, "DejaVu Sans Mono", monospace;
    font-size: 13px;
    line-height: 1.3;
    padding: 8px 10px;
    user-select: text;
  }
  .line {
    white-space: pre;
    min-height: 1.3em;
  }
  .input {
    display: flex;
    gap: 6px;
    padding: 8px 12px;
    border-top: 1px solid var(--line);
  }
  .input input {
    flex: 1;
  }
</style>
