<script lang="ts">
  import type { FindState } from "../lib/find.svelte";
  import type { SearchMatch } from "../lib/search";

  let { find, matches }: { find: FindState; matches: SearchMatch[] } = $props();
  let field: HTMLInputElement | undefined = $state();

  $effect(() => {
    void find.focusRequest;
    field?.focus();
    field?.select();
  });

  function onKey(event: KeyboardEvent) {
    if (event.key === "Enter") {
      event.preventDefault();
      find.step(event.shiftKey ? -1 : 1, matches);
    } else if (event.key === "Escape") {
      event.preventDefault();
      find.close();
    }
  }

  let at = $derived(find.current(matches));
</script>

<div class="bar">
  <span aria-hidden="true">⌕</span>
  <input
    bind:this={field}
    value={find.query}
    oninput={(e) => find.setQuery(e.currentTarget.value)}
    onkeydown={onKey}
    placeholder="In der Pane suchen"
    spellcheck="false"
  />
  {#if find.query}
    <span class="count">{at === null ? "Keine Treffer" : `${at + 1} von ${matches.length}`}</span>
  {/if}
  <button title="Vorheriger Treffer (Umschalt+F3)" disabled={!matches.length} onclick={() => find.step(-1, matches)}>↑</button>
  <button title="Nächster Treffer (F3)" disabled={!matches.length} onclick={() => find.step(1, matches)}>↓</button>
  <button title="Suche schließen (Esc)" onclick={() => find.close()}>✕</button>
</div>

<style>
  .bar {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    border-bottom: 1px solid var(--line);
    background: var(--sidebar);
  }
  input {
    flex: 1;
  }
  .count {
    font-size: 12px;
    color: var(--secondary);
    white-space: nowrap;
  }
  button {
    padding: 2px 8px;
  }
</style>
