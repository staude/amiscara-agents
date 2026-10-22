<script lang="ts">
  import * as core from "../lib/core";
  import { ui } from "../lib/manage.svelte";
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
      ? "Mit „Bereich/Name“ landet der Space in der Gruppe „Bereich“. herdr selbst zeigt den vollen Namen."
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

  /** herdr's refusals of an agent name, in German. */
  function renameMessage(text: string): string {
    if (text.includes("invalid_agent_name")) {
      return "Nur Kleinbuchstaben, Ziffern, - und _ sind erlaubt, am Anfang ein Buchstabe.";
    }
    if (text.includes("agent_name_taken")) return "Diesen Namen trägt schon ein anderer Agent.";
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
          throw new Error(`Angelegt, aber der Agent startete nicht: ${core.errorText(err)}`);
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
        ? "Darin arbeitet noch ein Agent. Schließen beendet ihn und alles, was in den Panes läuft."
        : d.agentState === "blocked"
          ? "Darin wartet ein Agent auf eine Antwort. Schließen beendet ihn und alles, was in den Panes läuft."
          : "Schließen beendet alles, was in den Panes läuft.";
    if (d.worktrees === 1) {
      return `Der Worktree-Space darunter wird mit geschlossen, sein Verzeichnis bleibt. ${state}`;
    }
    return d.worktrees > 1
      ? `Die ${d.worktrees} Worktree-Spaces darunter werden mit geschlossen, die Verzeichnisse bleiben. ${state}`
      : state;
  }

</script>

{#if dialog?.kind === "newSpace"}
  <Sheet title="Neuer Space auf {hostName}" {close}>
    <form onsubmit={submit} id="manage">
      <label class="field">
        <span>Name</span>
        <input bind:value={name} placeholder={groupHint ? "z. B. Privat/Dorfkino" : "z. B. Dorfkino"} />
      </label>
      <label class="field">
        <span>Verzeichnis</span>
        <input bind:value={directory} placeholder="~/dev/projekt" spellcheck="false" autocomplete="off" />
      </label>
      {#if groupHint}<p class="hint">{groupHint}</p>{/if}
      <AgentPicker hostId={dialog.hostId} storageKey="newSpaceAgentKind" bind:kind={agent} />
    </form>
    {#if error}<p class="error">{error}</p>{/if}
    {#snippet buttons()}
      <button onclick={close}>{createdWithoutAgent ? "Schließen" : "Abbrechen"}</button>
      <button class="primary" form="manage" type="submit" disabled={busy || createdWithoutAgent}>Anlegen</button>
    {/snippet}
  </Sheet>
{:else if dialog?.kind === "newWorktree"}
  <Sheet title="Neuer Worktree von {dialog.repository.label}" {close}>
    <form onsubmit={submit} id="manage">
      <label class="field">
        <span>Branch</span>
        <input bind:value={branch} placeholder="z. B. feature/login" spellcheck="false" autocomplete="off" />
      </label>
      <label class="field">
        <span>Basis</span>
        <input bind:value={base} placeholder="HEAD" spellcheck="false" autocomplete="off" />
      </label>
      <label class="field">
        <span>Name</span>
        <input bind:value={name} placeholder={branch || "wie der Branch"} />
      </label>
      <p class="hint">
        Ohne Branch wählt herdr einen Namen. Einen vorhandenen Branch checkt herdr aus. Der Worktree liegt in herdrs
        Worktree-Verzeichnis.
      </p>
      <AgentPicker hostId={dialog.hostId} storageKey="newWorktreeAgentKind" bind:kind={agent} />
    </form>
    {#if busy}<p class="hint">git worktree add läuft …</p>{/if}
    {#if error}<p class="error">{error}</p>{/if}
    {#snippet buttons()}
      <button onclick={close}>{createdWithoutAgent ? "Schließen" : "Abbrechen"}</button>
      <button class="primary" form="manage" type="submit" disabled={busy || createdWithoutAgent}>Anlegen</button>
    {/snippet}
  </Sheet>
{:else if dialog?.kind === "rename"}
  <Sheet
    title={dialog.target === "space" ? "Space umbenennen" : dialog.target === "tab" ? "Tab umbenennen" : "Agent benennen"}
    {close}
    width={400}
  >
    <form onsubmit={submit} id="manage">
      <!-- svelte-ignore a11y_autofocus -->
      <input
        bind:value={name}
        autofocus
        placeholder={dialog.target === "agent" ? "z. B. reviewer" : ""}
        spellcheck={dialog.target !== "agent"}
        style="width: 100%; box-sizing: border-box"
      />
    </form>
    {#if dialog.target === "agent"}
      <p class="hint">Kleinbuchstaben, Ziffern, - und _, höchstens 32 Zeichen. Leer lassen entfernt den Namen.</p>
    {:else if dialog.target === "space" && groupHint}
      <p class="hint">{groupHint}</p>
    {/if}
    {#if error}<p class="error">{error}</p>{/if}
    {#snippet buttons()}
      <button onclick={close}>Abbrechen</button>
      <button
        class="primary"
        form="manage"
        type="submit"
        disabled={busy || (dialog.kind === "rename" && dialog.target !== "agent" && !name.trim())}>Sichern</button
      >
    {/snippet}
  </Sheet>
{:else if dialog?.kind === "close"}
  <Sheet title={dialog.target === "space" ? `Space „${dialog.name}“ schließen?` : `Tab „${dialog.name}“ schließen?`} {close} width={420}>
    <p>{closeMessage(dialog)}</p>
    {#if error}<p class="error">Schließen fehlgeschlagen: {error}</p>{/if}
    {#snippet buttons()}
      <button onclick={close}>Abbrechen</button>
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
        }}>{dialog.target === "space" ? "Space schließen" : "Tab schließen"}</button
      >
    {/snippet}
  </Sheet>
{:else if dialog?.kind === "settings"}
  <Sheet title="Einstellungen" {close} width={420}>
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
      Mit dem System starten (im Infobereich, ohne Fenster)
    </label>
    <label class="field">
      <span>Erscheinungsbild</span>
      <select value={prefs.theme} onchange={(e) => prefs.setTheme(e.currentTarget.value as Theme)}>
        <option value="system">Wie das System</option>
        <option value="light">Hell</option>
        <option value="dark">Dunkel</option>
      </select>
    </label>
    <label class="field">
      <span>Terminal</span>
      <select
        value={prefs.terminalAppearance}
        onchange={(e) => prefs.setTerminalAppearance(e.currentTarget.value as TerminalAppearance)}
      >
        <option value="app">Wie die App</option>
        <option value="light">Hell</option>
        <option value="dark">Dunkel</option>
      </select>
    </label>
    <label class="field">
      <span>Farbschema</span>
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
      Mindestkontrast: zu schwache Schriftfarben aufhellen oder abdunkeln
    </label>
    <label class="check">
      <input type="checkbox" checked={prefs.wrapLines} onchange={(e) => prefs.setWrapLines(e.currentTarget.checked)} />
      Zeilen umbrechen (experimentell)
    </label>
    <p class="hint">
      Nicht von herdr vorgesehen: herdr liefert die Zeilen in der Breite des Panes auf dem Host. Was das Terminal
      umgebrochen hat, setzt die App wieder zusammen und bricht es an der Fensterbreite um. Vollbild-Agenten wie Claude
      Code brechen selbst um, ihre Zeilen und Rahmen werden nur gekürzt oder ein zweites Mal umgebrochen.
    </p>
    <div class="update-row">
      <span>Version {model.info?.version}</span>
      <button disabled={updater.state === "checking"} onclick={() => updater.check()}>Nach Updates suchen</button>
      {#if updater.state === "checking"}<span class="hint">Suche …</span>{/if}
      {#if updater.state === "current"}<span class="hint">Aktuell</span>{/if}
      {#if updater.available}<span class="hint">Version {updater.available.version} verfügbar</span>{/if}
    </div>
    {#if updater.state === "failed" && updater.error}<p class="error">{updater.error}</p>{/if}
    <p class="hint">
      Das Fenster zu schließen lässt Amiscara Agents im Infobereich weiterlaufen, damit Benachrichtigungen ankommen.
      Beenden über das Symbol im Infobereich. Benachrichtigungen pro Host unter „Bearbeiten“.
    </p>
    {#if error}<p class="error">{error}</p>{/if}
    {#snippet buttons()}
      <button class="primary" onclick={close}>Fertig</button>
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
