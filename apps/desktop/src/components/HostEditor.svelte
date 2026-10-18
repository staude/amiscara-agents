<script lang="ts">
  import { untrack } from "svelte";
  import { defaultSocket, errorText } from "../lib/core";
  import { model } from "../lib/state.svelte";
  import type { HostConfig } from "../lib/types";

  let { host, close }: { host: HostConfig | null; close: () => void } = $props();

  function blank(): HostConfig {
    return {
      id: "",
      name: "",
      kind: "ssh",
      host: "",
      port: 22,
      user: "",
      socketPath: "",
      pinnedHostKey: null,
      publicKey: null,
      auth: "key",
      allowInput: null,
      allowUpload: null,
      notify: null,
      groupSpaces: null,
    };
  }

  // A copy of the host as opened: nothing changes until "Sichern".
  const initial = untrack(() => (host ? structuredClone($state.snapshot(host)) : null));
  let draft = $state<HostConfig>(initial ?? blank());
  let macHost = $state(!initial || initial.socketPath.startsWith("/Users/"));
  let error = $state<string | null>(null);
  let saving = $state(false);
  let socketTouched = $state(initial !== null);

  $effect(() => {
    if (!socketTouched && draft.kind === "ssh") {
      draft.socketPath = draft.user ? defaultSocket(draft.user, macHost) : "";
    }
  });

  async function save(event: SubmitEvent) {
    event.preventDefault();
    saving = true;
    error = null;
    try {
      await model.save(draft);
      close();
    } catch (err) {
      error = errorText(err);
    } finally {
      saving = false;
    }
  }
</script>

<div class="backdrop" role="presentation" onclick={(e) => e.target === e.currentTarget && close()}>
  <form class="sheet" onsubmit={save}>
    <h2>{host ? "Host bearbeiten" : "Host hinzufügen"}</h2>

    {#if model.info?.localSocket}
      <label class="row">
        <span>Art</span>
        <select bind:value={draft.kind}>
          <option value="ssh">SSH</option>
          <option value="local">Dieser Rechner (lokaler Socket)</option>
        </select>
      </label>
    {/if}

    <label class="row">
      <span>Name</span>
      <input bind:value={draft.name} placeholder={draft.kind === "local" ? "Dieser Rechner" : "z. B. work"} />
    </label>

    {#if draft.kind === "ssh"}
      <label class="row">
        <span>Host</span>
        <input bind:value={draft.host} placeholder="work.staude.internal oder IP" required />
      </label>
      <label class="row">
        <span>Port</span>
        <input type="number" min="1" max="65535" bind:value={draft.port} />
      </label>
      <label class="row">
        <span>Benutzer</span>
        <input bind:value={draft.user} required autocomplete="off" />
      </label>
      <label class="row">
        <span>System</span>
        <select bind:value={macHost} onchange={() => (socketTouched = false)}>
          <option value={true}>macOS</option>
          <option value={false}>Linux</option>
        </select>
      </label>
      <label class="row">
        <span>Socket</span>
        <input bind:value={draft.socketPath} oninput={() => (socketTouched = true)} required />
      </label>
      <label class="row">
        <span>Anmeldung</span>
        <select bind:value={draft.auth}>
          <option value="key">Eigener Schlüssel (empfohlen)</option>
          <option value="agent">SSH-Agent</option>
        </select>
      </label>
      {#if draft.auth === "agent"}
        <p class="hint">
          Nutzt die Schlüssel des SSH-Agents ({model.info?.os === "windows"
            ? "OpenSSH-Agent von Windows"
            : "SSH_AUTH_SOCK"}). Ohne Einschränkung in authorized_keys hat dieser Schlüssel vollen
          Zugriff auf den Rechner.
        </p>
      {/if}
      <label class="check">
        <input
          type="checkbox"
          checked={draft.allowUpload ?? false}
          onchange={(e) => (draft.allowUpload = e.currentTarget.checked)}
        />
        Dateien hochladen (SFTP, Zugriff auf alle Dateien des Benutzers)
      </label>
    {:else}
      <label class="row">
        <span>Socket</span>
        <input bind:value={draft.socketPath} placeholder="~/.config/herdr/herdr.sock" />
      </label>
    {/if}

    <label class="check">
      <input
        type="checkbox"
        checked={draft.allowInput ?? true}
        onchange={(e) => (draft.allowInput = e.currentTarget.checked)}
      />
      Eingaben an Agents senden (Prompts, Tasten, Anlegen und Schließen)
    </label>
    <label class="check">
      <input
        type="checkbox"
        checked={draft.notify ?? true}
        onchange={(e) => (draft.notify = e.currentTarget.checked)}
      />
      Benachrichtigen, wenn ein Agent wartet oder fertig ist
    </label>

    {#if error}<p class="error">{error}</p>{/if}

    <div class="buttons">
      <button type="button" onclick={close}>Abbrechen</button>
      <button type="submit" class="primary" disabled={saving}>Sichern</button>
    </div>
  </form>
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
    width: min(480px, calc(100vw - 32px));
    max-height: calc(100vh - 32px);
    overflow: auto;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  h2 {
    margin: 0 0 6px;
    font-size: 16px;
  }
  .row {
    display: grid;
    grid-template-columns: 100px 1fr;
    align-items: center;
    gap: 10px;
  }
  .row span {
    color: var(--secondary);
  }
  .check {
    display: flex;
    gap: 8px;
    align-items: center;
  }
  .hint {
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
    margin-top: 6px;
  }
</style>
