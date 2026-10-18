<script lang="ts">
  import { untrack } from "svelte";
  import * as core from "../lib/core";
  import { model } from "../lib/state.svelte";
  import type { AddHostLink } from "../lib/types";

  // `url`: an opened link; without it the user pastes one.
  let { url, close }: { url: string | null; close: () => void } = $props();

  let text = $state(untrack(() => url) ?? "");
  let link = $state<AddHostLink | null>(null);
  let error = $state<string | null>(null);
  let fingerprint = $state<string | null>(null);

  $effect(() => {
    link = null;
    error = null;
    const value = text.trim();
    if (!value) return;
    core
      .decodeLink(value)
      .then((decoded) => (link = decoded))
      .catch((err) => (error = core.errorText(err)));
  });

  async function add() {
    if (!link) return;
    try {
      const host = await core.addFromLink(link);
      model.replace(host);
      await core.connect(host.id);
      close();
    } catch (err) {
      error = core.errorText(err);
    }
  }

  $effect(() => {
    fingerprint = null;
    if (link) {
      core
        .keyFingerprint(link.hostKey)
        .then((value) => (fingerprint = value))
        .catch((err) => (error = core.errorText(err)));
    }
  });
</script>

<div class="backdrop" role="presentation" onclick={(e) => e.target === e.currentTarget && close()}>
  <div class="sheet">
    <h2>Host aus Link hinzufügen</h2>
    {#if !url}
      <p class="small">
        Den Link „amiscara-agents://add-host?…“ einfügen, z. B. aus „Host teilen“ der Mac-App.
      </p>
      <textarea bind:value={text} rows="4" placeholder="amiscara-agents://add-host?v=1&…"></textarea>
    {/if}
    {#if link}
      <dl>
        <dt>Name</dt>
        <dd>{link.name || link.host}</dd>
        <dt>Host</dt>
        <dd>{link.user}@{link.host}:{link.port}</dd>
        <dt>Socket</dt>
        <dd>{link.socketPath || "Standard"}</dd>
        <dt>Host-Key</dt>
        <dd class="mono">{fingerprint}</dd>
      </dl>
      <p class="small">
        Der Host-Key aus dem Link gilt als bestätigt, wenn der Link vom eigenen Gerät stammt. Danach die Schlüsselzeile dieses Geräts auf dem
        Rechner eintragen.
      </p>
    {/if}
    {#if error}<p class="error">{error}</p>{/if}
    <div class="buttons">
      <button onclick={close}>Abbrechen</button>
      <button class="primary" disabled={!link} onclick={add}>Hinzufügen</button>
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
    padding: 20px;
    width: min(520px, calc(100vw - 32px));
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  h2 {
    margin: 0;
    font-size: 16px;
  }
  textarea {
    font-family: ui-monospace, "Cascadia Mono", Consolas, monospace;
    font-size: 12px;
  }
  dl {
    display: grid;
    grid-template-columns: 80px 1fr;
    gap: 4px 10px;
    margin: 0;
  }
  dt {
    color: var(--secondary);
  }
  dd {
    margin: 0;
    word-break: break-all;
  }
  .mono {
    font-family: ui-monospace, "Cascadia Mono", Consolas, monospace;
    font-size: 12px;
  }
  .small {
    font-size: 12px;
    color: var(--secondary);
    margin: 0;
  }
  .error {
    color: #d70015;
    margin: 0;
  }
  .buttons {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
  }
</style>
