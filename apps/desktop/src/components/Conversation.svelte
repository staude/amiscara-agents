<script lang="ts">
  import { locale, t } from "../lib/i18n.svelte";
  import { onMount, tick } from "svelte";
  import * as core from "../lib/core";
  import type { TranscriptCursor, TranscriptEntry } from "../lib/types";

  // The conversation of a Claude Code pane from its session file on the
  // host (#102): herdr keeps no scrollback for full-screen programs.
  let { hostId, paneId, close }: { hostId: string; paneId: string; close: () => void } = $props();

  let entries = $state<TranscriptEntry[]>([]);
  let older = $state<TranscriptCursor | null>(null);
  let loading = $state(false);
  let loaded = $state(false);
  let error = $state<string | null>(null);
  let list: HTMLDivElement | undefined = $state();

  async function load(reset: boolean) {
    if (loading) return;
    loading = true;
    const keep = list ? list.scrollHeight - list.scrollTop : 0;
    try {
      const page = await core.claudeHistory(hostId, paneId, reset ? null : older);
      entries = reset ? page.entries : [...page.entries, ...entries];
      older = page.start > 0 ? { sessionPath: page.sessionPath, start: page.start } : null;
      error = null;
      await tick();
      // Newest at the bottom; older entries above keep the view in place.
      if (list) list.scrollTop = reset ? list.scrollHeight : list.scrollHeight - keep;
    } catch (err) {
      error = core.errorText(err);
    } finally {
      loading = false;
      loaded = true;
    }
  }

  onMount(() => void load(true));

  function time(stamp: string | null): string | null {
    if (!stamp) return null;
    const date = new Date(stamp);
    if (Number.isNaN(date.getTime())) return null;
    const today = date.toDateString() === new Date().toDateString();
    return today
      ? date.toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" })
      : date.toLocaleString(locale(), { dateStyle: "medium", timeStyle: "short" });
  }

  async function copyAll() {
    const text = entries
      .map((e) => (e.kind === "user" ? `> ${e.text}` : e.kind === "tool" ? `· ${e.text}` : e.text))
      .join("\n\n");
    await navigator.clipboard.writeText(text);
  }

  function onKey(event: KeyboardEvent) {
    if (event.key === "Escape") close();
  }
</script>

<svelte:window onkeydown={onKey} />

<div class="backdrop" role="presentation" onclick={(e) => e.target === e.currentTarget && close()}>
  <div class="sheet">
    <header>
      <h2>{t("conversation")}</h2>
      <span class="spacer"></span>
      <button disabled={!entries.length} onclick={copyAll}>{t("copyAll")}</button>
      <button disabled={loading} onclick={() => load(true)}>{t("reload")}</button>
      <button class="primary" onclick={close}>{t("done")}</button>
    </header>
    <div class="list" bind:this={list}>
      {#if error && !entries.length}
        <p class="note">{t("conversationUnreadable", { error })}</p>
      {:else if !loaded}
        <p class="note">{t("findingSession")}</p>
      {:else if !entries.length}
        <p class="note">{t("noEntries")}</p>
      {:else}
        <div class="older">
          {#if loading}
            {t("loading")}
          {:else if older}
            <button onclick={() => load(false)}>↑ {t("loadOlderEntries")}</button>
          {:else}
            {t("sessionStart")}
          {/if}
        </div>
        {#each entries as entry, index (index)}
          {#if entry.kind === "user"}
            <div class="user">
              <div class="bubble">{entry.text}</div>
              {#if time(entry.timestamp)}<span class="time">{time(entry.timestamp)}</span>{/if}
            </div>
          {:else if entry.kind === "assistant"}
            <div class="assistant">{entry.text}</div>
          {:else}
            <div class="tool">🔧 {entry.text}</div>
          {/if}
        {/each}
      {/if}
    </div>
  </div>
</div>

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgb(0 0 0 / 0.35);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 10;
  }
  .sheet {
    background: var(--bg);
    border: 1px solid var(--line);
    border-radius: 10px;
    width: min(760px, calc(100vw - 32px));
    height: calc(100vh - 48px);
    display: flex;
    flex-direction: column;
  }
  header {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 12px 16px;
    border-bottom: 1px solid var(--line);
  }
  h2 {
    margin: 0;
    font-size: 16px;
  }
  .spacer {
    flex: 1;
  }
  .list {
    flex: 1;
    overflow: auto;
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    user-select: text;
  }
  .note,
  .older {
    color: var(--secondary);
    text-align: center;
  }
  .user {
    align-self: flex-end;
    max-width: 85%;
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 2px;
  }
  .bubble {
    background: color-mix(in srgb, var(--accent) 18%, transparent);
    border-radius: 12px;
    padding: 8px 12px;
    white-space: pre-wrap;
  }
  .time {
    font-size: 11px;
    color: var(--secondary);
  }
  .assistant {
    white-space: pre-wrap;
    line-height: 1.45;
  }
  .tool {
    font-family: ui-monospace, "Cascadia Mono", Consolas, monospace;
    font-size: 12px;
    color: var(--secondary);
    overflow: hidden;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
  }
</style>
