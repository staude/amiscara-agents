<script lang="ts">
  import { t } from "../lib/i18n.svelte";
  import { onMount } from "svelte";
  import * as core from "../lib/core";
  import { model } from "../lib/state.svelte";
  import type { HostConfig } from "../lib/types";
  import Sheet from "./Sheet.svelte";

  // Another herdr session on a host the app knows (#213): lists the host's
  // sessions and hands a new host for the chosen one to the editor.
  let { host, close, pick }: { host: HostConfig; close: () => void; pick: (draft: HostConfig) => void } =
    $props();

  interface Choice {
    name: string;
    running: boolean;
  }

  let choices = $state<Choice[] | null>(null);
  let listError = $state(false);
  let typed = $state("");
  let error = $state<string | null>(null);
  let base = "";
  let localDefault: string | null = null;

  onMount(async () => {
    localDefault = await core.localDefaultSocket().catch(() => null);
    base = host.socketPath || localDefault || "";
    try {
      const listed = host.kind === "local" ? await core.localSessions() : await core.hostSessions(host.id);
      const current = await core.sessionOfSocket(base).catch(() => null);
      const all: Choice[] = current ? [{ name: "", running: true }, ...listed] : listed;
      // Sessions that already have an entry for this login stay out.
      const taken = new Set(
        model.hosts
          .filter((other) => other.kind === host.kind && other.host === host.host && other.port === host.port && other.user === host.user)
          .map((other) => other.socketPath || localDefault || ""),
      );
      const free: Choice[] = [];
      for (const choice of all) {
        if (!taken.has(await socketFor(choice.name))) free.push(choice);
      }
      choices = free;
    } catch {
      listError = true;
      choices = [];
    }
  });

  async function socketFor(name: string): Promise<string> {
    return core.sessionSocket(base, name);
  }

  async function choose(name: string) {
    error = null;
    name = name.trim();
    if (name && !(await core.validSessionName(name))) {
      error = t("sessionNameInvalid");
      return;
    }
    try {
      const path = await socketFor(name);
      const draft: HostConfig = {
        ...structuredClone($state.snapshot(host)),
        id: "",
        name: `${host.name} (${name || t("sessionDefault")})`,
        socketPath: host.kind === "local" && path === localDefault ? "" : path,
        // A key line serves one socket: the new entry gets a key of its own.
        publicKey: null,
        allowUpload: null,
      };
      pick(draft);
    } catch (err) {
      error = core.errorText(err);
    }
  }
</script>

<Sheet title={t("addSessionTitle", { host: host.name })} {close}>
  {#if choices === null}
    <p class="hint">{t("sessionsLoading")}</p>
  {:else}
    {#if listError}
      <p class="hint">{t("sessionsNeedSftp")}</p>
    {:else if choices.length === 0}
      <p class="hint">{t("sessionsNone")}</p>
    {:else}
      <div class="list">
        {#each choices as choice (choice.name)}
          <button type="button" class="choice" onclick={() => void choose(choice.name)}>
            <span>{choice.name || t("sessionDefault")}</span>
            {#if !choice.running}<span class="small">{t("sessionStopped")}</span>{/if}
          </button>
        {/each}
      </div>
    {/if}
    <form class="typed" onsubmit={(e) => (e.preventDefault(), void choose(typed))}>
      <input bind:value={typed} placeholder={t("sessionNamePlaceholder")} autocomplete="off" spellcheck="false" />
      <button type="submit" disabled={!typed.trim()}>{t("sessionContinue")}</button>
    </form>
  {/if}
  {#if error}<p class="error">{error}</p>{/if}
  {#snippet buttons()}
    <button type="button" onclick={close}>{t("cancel")}</button>
  {/snippet}
</Sheet>

<style>
  .list {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .choice {
    display: flex;
    justify-content: space-between;
    text-align: left;
  }
  .small {
    color: var(--secondary);
    font-size: 12px;
  }
  .typed {
    display: flex;
    gap: 8px;
    margin-top: 10px;
  }
  .typed input {
    flex: 1;
  }
  .hint {
    font-size: 12px;
    color: var(--secondary);
    margin: 0;
  }
  .error {
    color: var(--danger);
    margin: 0;
  }
</style>
