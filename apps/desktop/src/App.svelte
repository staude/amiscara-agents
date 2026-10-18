<script lang="ts">
  import { onMount } from "svelte";
  import { appInfo, type AppInfo } from "./lib/core";

  let info = $state<AppInfo | null>(null);
  let error = $state<string | null>(null);

  onMount(async () => {
    try {
      info = await appInfo();
    } catch (err) {
      error = String(err);
    }
  });
</script>

<div class="layout">
  <aside class="sidebar">
    <h2>Hosts</h2>
    <p class="empty">Noch keine Hosts</p>
  </aside>
  <main class="detail">
    <div class="placeholder">
      <h1>Amiscara Agents</h1>
      <p>Fügen Sie einen Host hinzu, um seine Agents zu sehen.</p>
      {#if info}
        <p class="meta">Version {info.version}, herdr-Protokoll {info.protocol}</p>
      {:else if error}
        <p class="meta">{error}</p>
      {/if}
    </div>
  </main>
</div>

<style>
  .layout {
    display: grid;
    grid-template-columns: 260px 1fr;
    height: 100%;
  }

  .sidebar {
    background: var(--sidebar);
    border-right: 1px solid var(--line);
    padding: 12px 16px;
  }

  h2 {
    font-size: 12px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--secondary);
    margin: 4px 0 12px;
  }

  .empty {
    color: var(--secondary);
  }

  .detail {
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .placeholder {
    text-align: center;
  }

  h1 {
    font-size: 20px;
    margin: 0 0 8px;
  }

  .placeholder p {
    color: var(--secondary);
    margin: 4px 0;
  }

  .meta {
    font-size: 12px;
  }
</style>
