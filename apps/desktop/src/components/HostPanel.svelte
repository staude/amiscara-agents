<script lang="ts">
  import { t } from "../lib/i18n.svelte";
  import * as core from "../lib/core";
  import { model } from "../lib/state.svelte";
  import type { HostConfig } from "../lib/types";

  let { host, edit }: { host: HostConfig; edit: () => void } = $props();

  let update = $derived(model.updates[host.id]);
  let status = $derived(update?.status);
  let line = $state<string | null>(null);
  let copied = $state(false);
  let error = $state<string | null>(null);

  $effect(() => {
    line = null;
    if (host.kind === "ssh" && host.auth === "key" && host.publicKey) {
      core
        .keyLine(host.id, host.allowUpload ?? false, host.allowWebForward ?? false)
        .then((text) => (line = text))
        .catch((err) => (error = core.errorText(err)));
    }
  });

  async function copy() {
    if (!line) return;
    await navigator.clipboard.writeText(line);
    copied = true;
    setTimeout(() => (copied = false), 1500);
  }

  async function run(action: () => Promise<unknown>) {
    error = null;
    try {
      await action();
    } catch (err) {
      error = core.errorText(err);
    }
  }

  // Destructive buttons ask on the first click and act on the second.
  let armed = $state<"remove" | "regenerate" | null>(null);

  function confirmThen(which: "remove" | "regenerate", action: () => Promise<unknown>) {
    if (armed === which) {
      armed = null;
      void run(action);
    } else {
      armed = which;
      setTimeout(() => {
        if (armed === which) armed = null;
      }, 4000);
    }
  }

  function summary(): string {
    switch (status?.kind) {
      case undefined:
      case "connecting":
        return t("statusConnecting");
      case "live":
        return update?.serverVersion ? t("statusConnectedVersion", { version: update.serverVersion }) : t("statusConnected");
      case "retrying":
        return t("statusRetrying", { attempt: status.attempt });
      case "hostKeyUnknown":
        return t("statusHostKeyUnknown");
      case "hostKeyChanged":
        return t("statusHostKeyChanged");
      case "failed":
        return t("statusFailed");
    }
  }

  function hint(): string | null {
    if (status?.kind === "failed") {
      return t("hintFailed");
    }
    if (status?.kind !== "retrying") return null;
    const text = status.error.toLowerCase();
    if (["timed out", "timeout", "unreachable", "no route", "lookup", "resolve"].some((s) => text.includes(s))) {
      return t("hintUnreachable");
    }
    if (text.includes("refused")) {
      return t("hintRefused");
    }
    if (text.includes("channel") || text.includes("no such file")) {
      return t("hintSocket");
    }
    return null;
  }
</script>

<section class="panel">
  <header>
    <h1>{host.name}</h1>
    <div class="actions">
      <button onclick={() => run(() => core.connect(host.id))}>{t("connectNow")}</button>
      <button onclick={edit}>{t("edit")}</button>
      <button class:armed={armed === "remove"} onclick={() => confirmThen("remove", () => model.remove(host.id))}>
        {armed === "remove" ? t("reallyRemove") : t("remove")}
      </button>
    </div>
  </header>

  <p class="status">{summary()}</p>
  {#if status?.kind === "retrying" || status?.kind === "failed"}
    <pre class="detail">{status.error}</pre>
  {/if}
  {#if hint()}<p>{hint()}</p>{/if}
  {#if update && !update.protocolSupported}
    <p class="warn">{t("protocolUnknown")}</p>
  {/if}

  {#if status?.kind === "hostKeyUnknown" || status?.kind === "hostKeyChanged"}
    <div class="box" class:danger={status.kind === "hostKeyChanged"}>
      {#if status.kind === "hostKeyChanged"}
        <p>
          <strong>{t("hostKeyChangedTitle", { host: host.host })}</strong>
          {t("hostKeyChangedText")}
        </p>
      {:else}
        <p>{t("firstConnection", { host: host.host })}</p>
      {/if}
      <pre class="detail">{status.fingerprint}</pre>
      <p class="small">{t("onTheComputer")} <code>ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub</code></p>
      <button class="primary" onclick={() => run(() => core.trustHostKey(host.id, status.key))}>
        {t("trustHostKey")}
      </button>
    </div>
  {/if}

  {#if host.kind === "ssh" && host.auth === "key"}
    <div class="box">
      <h2>{t("deviceKey")}</h2>
      <p class="small">
        {t("keyLineBefore", { host: host.host })} <code>~/.ssh/authorized_keys</code>{host.allowUpload
          ? t("keyLineAfterSftp")
          : t("keyLineAfter")}
        {#if host.allowWebForward}{t("keyLineWeb")}{/if}
      </p>
      {#if line}
        <pre class="detail key">{line}</pre>
        <div class="actions">
          <button onclick={copy}>{copied ? t("copied") : t("copyLine")}</button>
          <button
            class:armed={armed === "regenerate"}
            title={t("newKeyHint")}
            onclick={() =>
              confirmThen("regenerate", async () => model.replace(await core.regenerateKey(host.id)))}
          >
            {armed === "regenerate" ? t("invalidateOldLine") : t("newKey")}
          </button>
        </div>
      {/if}
    </div>
  {/if}

  {#if error}<p class="error">{error}</p>{/if}
</section>

<style>
  .panel {
    padding: 20px 24px;
    max-width: 760px;
  }
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    flex-wrap: wrap;
  }
  h1 {
    font-size: 20px;
    margin: 0;
  }
  h2 {
    font-size: 14px;
    margin: 0 0 6px;
  }
  .actions {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }
  .status {
    font-weight: 600;
  }
  .detail {
    font-family: ui-monospace, "Cascadia Mono", Consolas, "DejaVu Sans Mono", monospace;
    font-size: 12px;
    background: var(--sidebar);
    border: 1px solid var(--line);
    border-radius: 6px;
    padding: 8px 10px;
    white-space: pre-wrap;
    word-break: break-all;
    user-select: text;
  }
  .box {
    border: 1px solid var(--line);
    border-radius: 8px;
    padding: 12px 14px;
    margin: 16px 0;
  }
  .danger {
    border-color: #d70015;
  }
  .small {
    font-size: 12px;
    color: var(--secondary);
  }
  .armed {
    color: #d70015;
    border-color: #d70015;
  }
  .warn,
  .error {
    color: #d70015;
  }
</style>
