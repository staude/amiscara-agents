<script lang="ts">
  import type { Snippet } from "svelte";

  // A modal sheet: title, content, buttons; Esc and a click outside close it.
  let {
    title,
    close,
    width = 460,
    children,
    buttons,
  }: { title: string; close: () => void; width?: number; children: Snippet; buttons?: Snippet } = $props();

  function onKey(event: KeyboardEvent) {
    if (event.key === "Escape") {
      event.stopPropagation();
      close();
    }
  }
</script>

<svelte:window onkeydown={onKey} />

<div class="backdrop" role="presentation" onclick={(e) => e.target === e.currentTarget && close()}>
  <div class="sheet" role="dialog" aria-modal="true" aria-label={title} style="width: min({width}px, calc(100vw - 32px))">
    <h2>{title}</h2>
    {@render children()}
    {#if buttons}<div class="buttons">{@render buttons()}</div>{/if}
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
    z-index: 20;
  }
  .sheet {
    background: var(--bg);
    border: 1px solid var(--line);
    border-radius: 10px;
    padding: 20px;
    max-height: calc(100vh - 32px);
    overflow: auto;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  h2 {
    margin: 0 0 4px;
    font-size: 16px;
  }
  .buttons {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 6px;
  }
  .sheet :global(.field) {
    display: grid;
    grid-template-columns: 110px 1fr;
    align-items: center;
    gap: 10px;
  }
  .sheet :global(.field > span) {
    color: var(--secondary);
  }
  .sheet :global(.hint) {
    font-size: 12px;
    color: var(--secondary);
    margin: 0;
  }
  .sheet :global(.error) {
    color: var(--danger);
    margin: 0;
    user-select: text;
  }
</style>
