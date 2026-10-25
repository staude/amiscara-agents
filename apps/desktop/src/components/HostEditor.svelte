<script lang="ts">
  import { t } from "../lib/i18n.svelte";
  import { onMount, untrack } from "svelte";
  import * as core from "../lib/core";
  import { defaultSocket, errorText } from "../lib/core";
  import { model } from "../lib/state.svelte";
  import type { HerdrSession, HostConfig } from "../lib/types";

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
      spaceSort: null,
      spaceOrder: null,
    };
  }

  // A copy of the host as opened: nothing changes until it is saved.
  const initial = untrack(() => (host ? structuredClone($state.snapshot(host)) : null));
  let draft = $state<HostConfig>(initial ?? blank());
  let macHost = $state(!initial || initial.socketPath.startsWith("/Users/"));
  let error = $state<string | null>(null);
  let saving = $state(false);
  let socketTouched = $state(initial !== null);
  // The named herdr session (#213); it only sets the socket path.
  let sessionName = $state("");
  let sessionError = $state<string | null>(null);
  let sessions = $state<HerdrSession[]>([]);
  let localDefault: string | null = null;

  $effect(() => {
    if (!socketTouched && draft.kind === "ssh") {
      draft.socketPath = draft.user ? defaultSocket(draft.user, macHost) : "";
      if (draft.user) untrack(() => void applySession());
    }
  });

  onMount(async () => {
    localDefault = await core.localDefaultSocket().catch(() => null);
    await readSession();
    // Sessions to pick from: this machine's, or a connected host's (needs SFTP).
    const listed =
      draft.kind === "local"
        ? core.localSessions()
        : initial?.id && model.isLive(initial.id)
          ? core.hostSessions(initial.id)
          : Promise.resolve([]);
    sessions = await listed.catch(() => []);
  });

  /** The socket the session field starts from: the path or its default. */
  function baseSocket(): string {
    if (draft.socketPath) return draft.socketPath;
    return draft.kind === "local" ? (localDefault ?? "") : draft.user ? defaultSocket(draft.user, macHost) : "";
  }

  /** The field from the socket path, e.g. after typing a path. */
  async function readSession() {
    const base = baseSocket();
    sessionName = (base && (await core.sessionOfSocket(base).catch(() => null))) || "";
    sessionError = null;
  }

  /** The socket path from the field. */
  async function applySession() {
    const name = sessionName.trim();
    if (name && !(await core.validSessionName(name))) {
      sessionError = t("sessionNameInvalid");
      return;
    }
    sessionError = null;
    const base = baseSocket();
    if (!base) return;
    try {
      const path = await core.sessionSocket(base, name);
      // Local hosts keep the default as an empty path.
      draft.socketPath = draft.kind === "local" && path === localDefault ? "" : path;
    } catch (err) {
      sessionError = errorText(err);
    }
  }

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

{#snippet sessionField()}
  <label class="row">
    <span>Session</span>
    <input
      bind:value={sessionName}
      oninput={() => void applySession()}
      placeholder={t("sessionDefault")}
      list="herdr-sessions"
      autocomplete="off"
      spellcheck="false"
    />
  </label>
  <datalist id="herdr-sessions">
    {#each sessions as session (session.name)}
      <option value={session.name}>{session.running ? "" : t("sessionStopped")}</option>
    {/each}
  </datalist>
  {#if sessionError}<p class="error">{sessionError}</p>{/if}
{/snippet}

<div class="backdrop" role="presentation" onclick={(e) => e.target === e.currentTarget && close()}>
  <form class="sheet" onsubmit={save}>
    <h2>{host?.id ? t("editHost") : t("addHost")}</h2>

    {#if model.info?.localSocket}
      <label class="row">
        <span>{t("hostKind")}</span>
        <select bind:value={draft.kind}>
          <option value="ssh">SSH</option>
          <option value="local">{t("thisComputerLocal")}</option>
        </select>
      </label>
    {/if}

    <label class="row">
      <span>{t("name")}</span>
      <input bind:value={draft.name} placeholder={draft.kind === "local" ? t("thisComputer") : t("hostNameExample")} />
    </label>

    {#if draft.kind === "ssh"}
      <label class="row">
        <span>Host</span>
        <input bind:value={draft.host} placeholder={t("hostAddressExample")} required />
      </label>
      <label class="row">
        <span>Port</span>
        <input type="number" min="1" max="65535" bind:value={draft.port} />
      </label>
      <label class="row">
        <span>{t("user")}</span>
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
        <input
          bind:value={draft.socketPath}
          oninput={() => {
            socketTouched = true;
            void readSession();
          }}
          required
        />
      </label>
      {@render sessionField()}
      <label class="row">
        <span>{t("login")}</span>
        <select bind:value={draft.auth}>
          <option value="key">{t("ownKeyRecommended")}</option>
          <option value="agent">SSH-Agent</option>
        </select>
      </label>
      {#if draft.auth === "agent"}
        <p class="hint">
          {t("sshAgentHint", { agent: model.info?.os === "windows" ? t("windowsOpenSshAgent") : "SSH_AUTH_SOCK" })}
        </p>
      {/if}
      <label class="check">
        <input
          type="checkbox"
          checked={draft.allowUpload ?? false}
          onchange={(e) => (draft.allowUpload = e.currentTarget.checked)}
        />
        {t("allowUpload")}
      </label>
    {:else}
      <label class="row">
        <span>Socket</span>
        <input bind:value={draft.socketPath} placeholder="~/.config/herdr/herdr.sock" oninput={() => void readSession()} />
      </label>
      {@render sessionField()}
    {/if}

    <label class="check">
      <input
        type="checkbox"
        checked={draft.allowInput ?? true}
        onchange={(e) => (draft.allowInput = e.currentTarget.checked)}
      />
      {t("allowInput")}
    </label>
    <label class="check">
      <input
        type="checkbox"
        checked={draft.notify ?? true}
        onchange={(e) => (draft.notify = e.currentTarget.checked)}
      />
      {t("notifyHost")}
    </label>

    {#if error}<p class="error">{error}</p>{/if}

    <div class="buttons">
      <button type="button" onclick={close}>{t("cancel")}</button>
      <button type="submit" class="primary" disabled={saving || sessionError !== null}>{t("save")}</button>
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
