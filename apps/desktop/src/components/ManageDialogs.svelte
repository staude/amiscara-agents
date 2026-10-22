<script lang="ts">
  import { t } from "../lib/i18n.svelte";
  import * as core from "../lib/core";
  import { ui } from "../lib/manage.svelte";
  import type { LangSetting } from "../lib/i18n.svelte";
  import { prefs, type Theme } from "../lib/prefs.svelte";
  import type { TerminalAppearance, TerminalScheme } from "../lib/term";
  import { model } from "../lib/state.svelte";
  import { updater } from "../lib/update.svelte";
  import AgentPicker from "./AgentPicker.svelte";
  import Sheet from "./Sheet.svelte";

  // The dialog `ui.dialog` asks for: new space or worktree, rename, close,
  // app settings (NewSpaceView, RenameView, CloseView of the Mac app).
  let dialog = $derived(ui.dialog);
  let busy = $state(false);
  let error = $state<string | null>(null);
  /** Set when the space exists but its agent did not start. */
  let createdWithoutAgent = $state(false);

  let name = $state("");
  let directory = $state("~");
  let branch = $state("");
  let base = $state("");
  let agent = $state<string | null>(null);
  let autostart = $state(false);

  // Fresh fields for every dialog.
  $effect(() => {
    const d = ui.dialog;
    error = null;
    busy = false;
    createdWithoutAgent = false;
    name = d?.kind === "rename" ? d.current : "";
    directory = "~";
    branch = "";
    base = "";
    if (d?.kind === "settings") core.autostart().then((on) => (autostart = on));
  });

  const close = () => (ui.dialog = null);
  let hostName = $derived(dialog && "hostId" in dialog ? (model.host(dialog.hostId)?.name ?? "") : "");
  let groupHint = $derived(
    dialog && "hostId" in dialog && (model.host(dialog.hostId)?.groupSpaces ?? true)
      ? t("groupHint")
      : null,
  );

  async function run(action: () => Promise<void>) {
    busy = true;
    error = null;
    try {
      await action();
    } catch (err) {
      error = renameMessage(core.errorText(err));
    } finally {
      busy = false;
    }
  }

  /** herdr's refusals of an agent name, for the user. */
  function renameMessage(text: string): string {
    if (text.includes("invalid_agent_name")) return t("agentNameInvalid");
    if (text.includes("agent_name_taken")) return t("agentNameTaken");
    return text;
  }

  /** Creates, selects the new pane, then starts the agent if one was picked. */
  async function create(hostId: string, make: () => Promise<core.Created>) {
    await run(async () => {
      const created = await make();
      model.select(hostId, created.workspaceId, created.paneId);
      if (agent) {
        try {
          await core.startAgent(hostId, created.paneId, agent);
        } catch (err) {
          // It exists; "Anlegen" again would make a second one.
          createdWithoutAgent = true;
          throw new Error(t("createdAgentFailed", { error: core.errorText(err) }));
        }
      }
      close();
    });
  }

  function submit(event: SubmitEvent) {
    event.preventDefault();
    const d = ui.dialog;
    if (!d || busy) return;
    if (d.kind === "newSpace") {
      void create(d.hostId, () => core.createWorkspace(d.hostId, name, directory));
    } else if (d.kind === "newWorktree") {
      void create(d.hostId, () => core.createWorktree(d.hostId, d.repository.workspaceId, branch, base, name));
    } else if (d.kind === "rename") {
      if (d.target !== "agent" && !name.trim()) return;
      void run(async () => {
        await core.rename(d.hostId, d.target, d.id, name);
        close();
      });
    }
  }

  function closeMessage(d: Extract<NonNullable<typeof dialog>, { kind: "close" }>): string {
    const state =
      d.agentState === "working"
        ? t("closeAgentWorking")
        : d.agentState === "blocked"
          ? t("closeAgentWaiting")
          : t("closeEndsAll");
    if (d.worktrees === 1) {
      return `${t("closeOneWorktree")} ${state}`;
    }
    return d.worktrees > 1
      ? `${t("closeWorktrees", { n: d.worktrees })} ${state}`
      : state;
  }

</script>

{#if dialog?.kind === "newSpace"}
  <Sheet title={t("newSpaceOn", { host: hostName })} {close}>
    <form onsubmit={submit} id="manage">
      <label class="field">
        <span>{t("name")}</span>
        <input bind:value={name} placeholder={groupHint ? t("spaceNameGroupExample") : t("spaceNameExample")} />
      </label>
      <label class="field">
        <span>{t("directory")}</span>
        <input bind:value={directory} placeholder={t("directoryExample")} spellcheck="false" autocomplete="off" />
      </label>
      {#if groupHint}<p class="hint">{groupHint}</p>{/if}
      <AgentPicker hostId={dialog.hostId} storageKey="newSpaceAgentKind" bind:kind={agent} />
    </form>
    {#if error}<p class="error">{error}</p>{/if}
    {#snippet buttons()}
      <button onclick={close}>{createdWithoutAgent ? t("close") : t("cancel")}</button>
      <button class="primary" form="manage" type="submit" disabled={busy || createdWithoutAgent}>{t("create")}</button>
    {/snippet}
  </Sheet>
{:else if dialog?.kind === "newWorktree"}
  <Sheet title={t("newWorktreeOf", { repository: dialog.repository.label })} {close}>
    <form onsubmit={submit} id="manage">
      <label class="field">
        <span>Branch</span>
        <input bind:value={branch} placeholder={t("branchExample")} spellcheck="false" autocomplete="off" />
      </label>
      <label class="field">
        <span>{t("base")}</span>
        <input bind:value={base} placeholder="HEAD" spellcheck="false" autocomplete="off" />
      </label>
      <label class="field">
        <span>{t("name")}</span>
        <input bind:value={name} placeholder={branch || t("likeTheBranch")} />
      </label>
      <p class="hint">{t("worktreeHint")}</p>
      <AgentPicker hostId={dialog.hostId} storageKey="newWorktreeAgentKind" bind:kind={agent} />
    </form>
    {#if busy}<p class="hint">{t("worktreeRunning")}</p>{/if}
    {#if error}<p class="error">{error}</p>{/if}
    {#snippet buttons()}
      <button onclick={close}>{createdWithoutAgent ? t("close") : t("cancel")}</button>
      <button class="primary" form="manage" type="submit" disabled={busy || createdWithoutAgent}>{t("create")}</button>
    {/snippet}
  </Sheet>
{:else if dialog?.kind === "rename"}
  <Sheet
    title={dialog.target === "space" ? t("renameSpace") : dialog.target === "tab" ? t("renameTab") : t("nameAgent")}
    {close}
    width={400}
  >
    <form onsubmit={submit} id="manage">
      <!-- svelte-ignore a11y_autofocus -->
      <input
        bind:value={name}
        autofocus
        placeholder={dialog.target === "agent" ? t("agentNameExample") : ""}
        spellcheck={dialog.target !== "agent"}
        style="width: 100%; box-sizing: border-box"
      />
    </form>
    {#if dialog.target === "agent"}
      <p class="hint">{t("agentNameHint")}</p>
    {:else if dialog.target === "space" && groupHint}
      <p class="hint">{groupHint}</p>
    {/if}
    {#if error}<p class="error">{error}</p>{/if}
    {#snippet buttons()}
      <button onclick={close}>{t("cancel")}</button>
      <button
        class="primary"
        form="manage"
        type="submit"
        disabled={busy || (dialog.kind === "rename" && dialog.target !== "agent" && !name.trim())}>{t("save")}</button
      >
    {/snippet}
  </Sheet>
{:else if dialog?.kind === "close"}
  <Sheet title={dialog.target === "space" ? t("closeSpaceQuestion", { name: dialog.name }) : t("closeTabQuestion", { name: dialog.name })} {close} width={420}>
    <p>{closeMessage(dialog)}</p>
    {#if error}<p class="error">{t("closeFailed", { error })}</p>{/if}
    {#snippet buttons()}
      <button onclick={close}>{t("cancel")}</button>
      <button
        class="danger"
        disabled={busy}
        onclick={() => {
          const d = dialog;
          if (d?.kind !== "close") return;
          void run(async () => {
            await core.close(d.hostId, d.target, d.id, d.worktrees > 0);
            close();
          });
        }}>{dialog.target === "space" ? t("closeSpace") : t("closeTab")}</button
      >
    {/snippet}
  </Sheet>
{:else if dialog?.kind === "settings"}
  <Sheet title={t("settings")} {close} width={420}>
    <label class="check">
      <input
        type="checkbox"
        checked={autostart}
        onchange={(e) => {
          const on = e.currentTarget.checked;
          void run(async () => {
            await core.setAutostart(on);
            autostart = on;
          });
        }}
      />
      {t("autostart")}
    </label>
    <label class="field">
      <span>{t("language")}</span>
      <select value={prefs.language} onchange={(e) => prefs.setLanguage(e.currentTarget.value as LangSetting)}>
        <option value="system">{t("languageSystem")}</option>
        <option value="de">Deutsch</option>
        <option value="en">English</option>
      </select>
    </label>
    <label class="field">
      <span>{t("appearance")}</span>
      <select value={prefs.theme} onchange={(e) => prefs.setTheme(e.currentTarget.value as Theme)}>
        <option value="system">{t("asSystem")}</option>
        <option value="light">{t("light")}</option>
        <option value="dark">{t("dark")}</option>
      </select>
    </label>
    <label class="field">
      <span>Terminal</span>
      <select
        value={prefs.terminalAppearance}
        onchange={(e) => prefs.setTerminalAppearance(e.currentTarget.value as TerminalAppearance)}
      >
        <option value="app">{t("asApp")}</option>
        <option value="light">{t("light")}</option>
        <option value="dark">{t("dark")}</option>
      </select>
    </label>
    <label class="field">
      <span>{t("colorScheme")}</span>
      <select
        value={prefs.terminalScheme}
        onchange={(e) => prefs.setTerminalScheme(e.currentTarget.value as TerminalScheme)}
      >
        <option value="standard">Standard</option>
        <option value="solarized">Solarized</option>
        <option value="apple">Terminal (macOS)</option>
      </select>
    </label>
    <label class="check">
      <input type="checkbox" checked={prefs.minContrast} onchange={(e) => prefs.setMinContrast(e.currentTarget.checked)} />
      {t("minContrast")}
    </label>
    <label class="check">
      <input type="checkbox" checked={prefs.wrapLines} onchange={(e) => prefs.setWrapLines(e.currentTarget.checked)} />
      {t("wrapLines")}
    </label>
    <p class="hint">{t("wrapLinesHint")}</p>
    <label class="check">
      <input type="checkbox" checked={prefs.fullscreenScroll} onchange={(e) => prefs.setFullscreenScroll(e.currentTarget.checked)} />
      {t("fullscreenScroll")}
    </label>
    <label class="check">
      <input type="checkbox" checked={updater.automatic} onchange={(e) => updater.setAutomatic(e.currentTarget.checked)} />
      {t("autoUpdates")}
    </label>
    <div class="update-row">
      <span>{t("version", { version: model.info?.version ?? "" })}</span>
      <button disabled={updater.state === "checking"} onclick={() => updater.check()}>{t("checkForUpdates")}</button>
      {#if updater.state === "checking"}<span class="hint">{t("checking")}</span>{/if}
      {#if updater.state === "current"}<span class="hint">{t("upToDate")}</span>{/if}
      {#if updater.available}<span class="hint">{t("versionAvailable", { version: updater.available.version })}</span>{/if}
    </div>
    {#if updater.state === "failed" && updater.error}<p class="error">{updater.error}</p>{/if}
    <p class="hint">{t("trayHint")}</p>
    {#if error}<p class="error">{error}</p>{/if}
    {#snippet buttons()}
      <button class="primary" onclick={close}>{t("done")}</button>
    {/snippet}
  </Sheet>
{/if}

<style>
  form {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .update-row {
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .check {
    display: flex;
    gap: 8px;
    align-items: center;
  }
  .danger {
    background: var(--danger);
    border-color: var(--danger);
    color: #fff;
  }
</style>
