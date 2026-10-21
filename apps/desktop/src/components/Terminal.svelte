<script lang="ts">
  import { openUrl } from "@tauri-apps/plugin-opener";
  import type { PaneModel } from "../lib/pane.svelte";
  import { prefs } from "../lib/prefs.svelte";
  import type { SearchMatch } from "../lib/search";
  import { css, spanStyle } from "../lib/term";
  import type { StyledSpan } from "../lib/types";

  // `history`: scrollback controls above the first line (selected pane only).
  // `fitColumns`: shrink the font until this many columns fit (split tabs).
  let {
    model,
    history = true,
    fitColumns = null,
    matches = [],
    current = null,
    scrollRequest = 0,
  }: {
    model: PaneModel;
    history?: boolean;
    fitColumns?: number | null;
    matches?: SearchMatch[];
    current?: number | null;
    scrollRequest?: number;
  } = $props();

  let scroller: HTMLDivElement | undefined = $state();
  let width = $state(0);
  /** Like a terminal: stay at the bottom until the user scrolls up. */
  let atBottom = true;
  let fromBottom = 0;

  let fontSize = $derived.by(() => {
    if (!fitColumns || width === 0) return prefs.fontSize;
    // A monospaced glyph is about 0.6 em wide; 20 is the padding.
    const fitting = Math.floor((width - 20) / (fitColumns * 0.6));
    return Math.min(prefs.fontSize, Math.max(7, fitting));
  });

  let theme = $derived(prefs.terminal);

  let byLine = $derived.by(() => {
    const map = new Map<number, { match: SearchMatch; index: number }[]>();
    matches.forEach((match, index) => {
      const list = map.get(match.line) ?? [];
      list.push({ match, index });
      map.set(match.line, list);
    });
    return map;
  });

  /** A line's spans, cut where matches start and end. */
  function segments(spans: StyledSpan[], lineIndex: number) {
    const marks = byLine.get(lineIndex);
    if (!marks) return spans.map((span) => ({ span, text: span.text, mark: null as string | null }));
    const out: { span: StyledSpan; text: string; mark: string | null }[] = [];
    let offset = 0;
    for (const span of spans) {
      const end = offset + span.text.length;
      const cuts = new Set([offset, end]);
      for (const { match } of marks) {
        for (const at of [match.start, match.start + match.length]) if (at > offset && at < end) cuts.add(at);
      }
      const points = [...cuts].sort((a, b) => a - b);
      for (let i = 0; i < points.length - 1; i++) {
        const from = points[i];
        const hit = marks.find(({ match }) => from >= match.start && from < match.start + match.length);
        out.push({
          span,
          text: span.text.slice(from - offset, points[i + 1] - offset),
          mark: hit ? (hit.index === current ? "current" : "match") : null,
        });
      }
      offset = end;
    }
    return out;
  }

  /** A click on a web address opens it in the browser (#186), unless it ends a text selection. */
  function openLink(event: MouseEvent, link: string) {
    event.preventDefault();
    if (!window.getSelection()?.isCollapsed) return;
    openUrl(link).catch(() => window.open(link, "_blank"));
  }

  function onScroll() {
    if (!scroller) return;
    fromBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;
    atBottom = fromBottom < 4;
    if (history && scroller.scrollTop < 24 && scroller.scrollHeight > scroller.clientHeight) {
      model.loadMoreHistory();
    }
  }

  // New content: keep the bottom in view, or the lines the user looks at
  // when history arrived above them.
  $effect(() => {
    void model.content;
    void fontSize;
    if (!scroller) return;
    scroller.scrollTop = atBottom
      ? scroller.scrollHeight
      : scroller.scrollHeight - scroller.clientHeight - fromBottom;
  });

  $effect(() => {
    void scrollRequest;
    if (!scroller || current === null || !matches[current]) return;
    const line = scroller.querySelector<HTMLElement>(`[data-line="${matches[current].line}"]`);
    line?.scrollIntoView({ block: "center", inline: "nearest" });
  });

  // A new pane starts at the bottom again.
  $effect(() => {
    void model.paneId;
    atBottom = true;
  });
</script>

<div
  class="terminal"
  bind:this={scroller}
  bind:clientWidth={width}
  onscroll={onScroll}
  class:dark={theme.dark}
  style="font-size: {fontSize}px; --term-bg: {css(theme.background)}; --term-fg: {css(theme.foreground)}"
>
  {#if history && model.content}
    <div class="history">
      {#if model.isLoadingHistory}
        <span>Verlauf wird geladen …</span>
      {:else if model.canLoadMoreHistory}
        <button onclick={() => model.loadMoreHistory()}>↑ Älteren Verlauf laden</button>
      {:else if model.hasNoHistory}
        <span>Kein Verlauf: Bei Vollbild-Programmen wie Claude Code speichert herdr keinen.</span>
      {:else if model.content.historyLines > 0 && model.content.truncated}
        <span>Mehr als {model.content.historyLines} Zeilen liefert herdr nicht.</span>
      {:else if model.content.historyLines > 0}
        <span>Anfang des Verlaufs</span>
      {/if}
      {#if model.content.historyLines > 0}
        <button onclick={() => model.hideHistory()}>Nur Bildschirm</button>
      {/if}
    </div>
  {/if}
  {#if model.content}
    {#each model.content.lines as line, index (index)}
      <div class="line" data-line={index}>{#each segments(line.spans, index) as part, partIndex (partIndex)}{#if part.span.link}<a
              href={part.span.link}
              class={part.mark}
              style={part.mark ? "" : spanStyle(part.span, theme)}
              onclick={(event) => openLink(event, part.span.link!)}>{part.text}</a
            >{:else}<span
              class={part.mark}
              style={part.mark ? "" : spanStyle(part.span, theme)}>{part.text}</span
            >{/if}{/each}</div>
    {/each}
  {:else if model.error}
    <p class="note">Pane nicht lesbar: {model.error}</p>
  {:else}
    <p class="note">Lade …</p>
  {/if}
</div>

<style>
  /* Colors from the terminal settings (`prefs.terminal`). */
  .terminal {
    color-scheme: light;
    background: var(--term-bg);
    color: var(--term-fg);
    font-family: ui-monospace, "Cascadia Mono", Consolas, "DejaVu Sans Mono", monospace;
    line-height: 1.25;
    padding: 10px;
    overflow: auto;
    height: 100%;
    box-sizing: border-box;
    user-select: text;
    -webkit-user-select: text;
  }
  .terminal.dark {
    color-scheme: dark;
  }
  .line {
    white-space: pre;
    min-height: 1.25em;
    width: max-content;
  }
  .history {
    display: flex;
    gap: 12px;
    align-items: center;
    margin-bottom: 8px;
    font-family: system-ui, sans-serif;
    font-size: 13px;
    color: color-mix(in srgb, var(--term-fg) 70%, transparent);
    user-select: none;
  }
  .history button {
    background: color-mix(in srgb, var(--term-fg) 8%, transparent);
    border-color: color-mix(in srgb, var(--term-fg) 15%, transparent);
    color: inherit;
  }
  .note {
    font-family: system-ui, sans-serif;
    color: color-mix(in srgb, var(--term-fg) 70%, transparent);
  }
  a {
    color: inherit;
    text-decoration: underline;
  }
  .match {
    background: rgb(242 204 64 / 0.75);
    color: #000;
  }
  .current {
    background: #ff8c1a;
    color: #000;
  }
</style>
