<script lang="ts">
  import { t } from "../lib/i18n.svelte";
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
    placeholder={t("findInPanePlaceholder")}
    spellcheck="false"
  />
  {#if find.query}
    <span class="count">{at === null ? t("noMatches") : t("matchOf", { at: at + 1, n: matches.length })}</span>
  {/if}
  <button title={t("previousMatch")} disabled={!matches.length} onclick={() => find.step(-1, matches)}>↑</button>
  <button title={t("nextMatch")} disabled={!matches.length} onclick={() => find.step(1, matches)}>↓</button>
  <button title={t("closeFind")} onclick={() => find.close()}>✕</button>
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
