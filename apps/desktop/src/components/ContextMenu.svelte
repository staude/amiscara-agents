<script lang="ts">
  import type { MenuItem } from "../lib/manage.svelte";

  // A right-click menu at the pointer; closes on any click outside or Esc.
  let { x, y, items, close }: { x: number; y: number; items: (MenuItem | null)[]; close: () => void } = $props();
  let menu: HTMLDivElement | undefined = $state();
  let left = $state(0);
  let top = $state(0);

  // Kept inside the window.
  $effect(() => {
    if (!menu) return;
    left = Math.min(x, window.innerWidth - menu.offsetWidth - 8);
    top = Math.min(y, window.innerHeight - menu.offsetHeight - 8);
  });
</script>

<svelte:window
  onmousedown={(e) => menu && !menu.contains(e.target as Node) && close()}
  onkeydown={(e) => e.key === "Escape" && close()}
  onblur={close}
/>

<div class="menu" role="menu" bind:this={menu} style="left: {left}px; top: {top}px">
  {#each items as item, index (index)}
    {#if item}
      <button
        role="menuitem"
        class:danger={item.danger}
        disabled={item.disabled}
        onclick={() => {
          close();
          item.action();
        }}>{item.label}</button
      >
    {:else}
      <hr />
    {/if}
  {/each}
</div>

<style>
  .menu {
    position: fixed;
    z-index: 30;
    background: var(--bg);
    border: 1px solid var(--line);
    border-radius: 8px;
    box-shadow: 0 6px 24px rgb(0 0 0 / 0.18);
    padding: 4px;
    min-width: 200px;
    display: flex;
    flex-direction: column;
  }
  button {
    border: none;
    background: none;
    text-align: left;
    padding: 6px 10px;
    border-radius: 5px;
  }
  button:hover:not(:disabled) {
    background: color-mix(in srgb, var(--accent) 18%, transparent);
  }
  .danger {
    color: var(--danger);
  }
  hr {
    border: none;
    border-top: 1px solid var(--line);
    margin: 4px 2px;
  }
</style>
