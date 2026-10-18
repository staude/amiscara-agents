<script lang="ts">
  import { onMount } from "svelte";
  import { prepare, release, shellQuoted, type Attachment } from "../lib/attachments";
  import * as core from "../lib/core";
  import { nav, type KeySender } from "../lib/nav.svelte";
  import { model } from "../lib/state.svelte";
  import type { HostConfig, PaneItem } from "../lib/types";
  import QuickReplyEditor from "./QuickReplyEditor.svelte";

  // Under the pane screen: one-click answers while an agent waits, quick
  // replies, a key bar, attachments and the composer (InputBar.swift).
  let { host, pane }: { host: HostConfig; pane: PaneItem } = $props();

  let text = $state("");
  let sending = $state(false);
  let error = $state<string | null>(null);
  let attachments = $state<Attachment[]>([]);
  let replies = $state<string[]>([]);
  let editingReplies = $state(false);
  let dropping = $state(false);
  let filePicker: HTMLInputElement | undefined = $state();

  let isAgent = $derived(pane.agent !== null);
  let isBlocked = $derived(isAgent && pane.agentState === "blocked");
  let live = $derived(model.isLive(host.id));
  let uploadAllowed = $derived(host.kind === "local" || (host.allowUpload ?? false));
  let canSend = $derived(text.trim().length > 0 || attachments.length > 0);

  onMount(() => {
    core.quickReplies().then((list) => (replies = list));
    return () => attachments.forEach(release);
  });

  async function perform(action: () => Promise<void>) {
    sending = true;
    error = null;
    try {
      await action();
    } catch (err) {
      error = core.errorText(err);
    } finally {
      sending = false;
    }
  }

  const sendKeys = (keys: string[]) => perform(() => core.sendKeys(host.id, pane.paneId, keys));

  // Keyboard shortcuts for the key bar and answers, see App.svelte.
  $effect(() => {
    if (!live) return;
    const sender: KeySender = { send: (keys) => void sendKeys(keys), blocked: isBlocked };
    nav.keySender = sender;
    return () => {
      if (nav.keySender === sender) nav.keySender = null;
    };
  });
  const sendReply = (reply: string) => perform(() => core.submit(host.id, pane.paneId, reply, isAgent));

  function submit() {
    const prompt = text.trim();
    if (!prompt && attachments.length === 0) return;
    const pending = attachments;
    perform(async () => {
      const paths: string[] = [];
      for (const item of pending) {
        paths.push(
          await core.upload(host.id, item.data, item.fileName ? { name: item.fileName } : { extension: item.extension }),
        );
      }
      // In a shell the paths become arguments: quoted, so no name adds a command.
      const shown = isAgent ? paths : paths.map(shellQuoted);
      const full = [prompt, ...shown].filter(Boolean).join(isAgent ? "\n" : " ");
      await core.submit(host.id, pane.paneId, full, isAgent);
      text = "";
      pending.forEach(release);
      attachments = attachments.filter((a) => !pending.includes(a));
    });
  }

  function onComposerKey(event: KeyboardEvent) {
    // Enter sends, Shift+Enter starts a new line.
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      submit();
    }
  }

  const uploadOff = () =>
    (error = `Dateien hochladen ist für ${host.name} aus. Einschalten unter „Bearbeiten“ › „Dateien hochladen (SFTP)“.`);

  async function add(files: File[]) {
    if (files.length === 0) return;
    if (!uploadAllowed) {
      uploadOff();
      return;
    }
    error = null;
    for (const file of files) {
      try {
        attachments.push(await prepare(file));
      } catch (err) {
        error = err instanceof Error ? err.message : String(err);
      }
    }
  }

  function onPaste(event: ClipboardEvent) {
    const files = Array.from(event.clipboardData?.files ?? []);
    if (files.length === 0) return; // Text: the composer takes it.
    event.preventDefault();
    void add(files);
  }

  function onDrop(event: DragEvent) {
    event.preventDefault();
    dropping = false;
    void add(Array.from(event.dataTransfer?.files ?? []));
  }

  function onDragOver(event: DragEvent) {
    if (!event.dataTransfer?.types.includes("Files")) return;
    event.preventDefault();
    dropping = true;
  }

  function removeAttachment(item: Attachment) {
    release(item);
    attachments = attachments.filter((a) => a !== item);
  }

  async function saveReplies(list: string[]) {
    await core.saveQuickReplies(list);
    replies = await core.quickReplies();
  }

  const KEYS: [string, string, string][] = [
    ["Esc", "esc", "Escape (Strg+.)"],
    ["Tab", "tab", "Tab"],
    ["⌃C", "ctrl+c", "Strg+C"],
    ["↑", "up", "Pfeil nach oben (Strg+Alt+↑)"],
    ["↓", "down", "Pfeil nach unten (Strg+Alt+↓)"],
    ["←", "left", "Pfeil nach links (Strg+Alt+←)"],
    ["→", "right", "Pfeil nach rechts (Strg+Alt+→)"],
    ["↩", "enter", "Enter (Strg+Umschalt+Enter)"],
  ];
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="input"
  class:dropping
  ondragover={onDragOver}
  ondragleave={() => (dropping = false)}
  ondrop={onDrop}
>
  <fieldset disabled={sending || !live}>
    {#if isBlocked}
      <div class="answers">
        <span class="waiting">✋ Wartet auf Antwort</span>
        <span class="spacer"></span>
        {#each ["1", "2", "3"] as key (key)}
          <button title="Option {key} wählen (Strg+Alt+{key})" onclick={() => sendKeys([key])}>{key}</button>
        {/each}
        <button class="confirm" title="Strg+Umschalt+Enter" onclick={() => sendKeys(["enter"])}>↩ Bestätigen</button>
        <button onclick={() => sendKeys(["esc"])}>Abbrechen</button>
      </div>
    {/if}

    <div class="row scroll">
      {#each replies as reply, index (index)}
        <button class="small" title="Senden: {reply}" onclick={() => sendReply(reply)}>{reply}</button>
      {/each}
      <button class="small" title="Schnellantworten bearbeiten" onclick={() => (editingReplies = true)}>
        {replies.length ? "✎" : "Schnellantworten"}
      </button>
    </div>

    <div class="row scroll">
      {#each KEYS as [label, key, help], index (key)}
        {#if index === 3}<span class="sep"></span>{/if}
        <button class="small" title={help} onclick={() => sendKeys([key])}>{label}</button>
      {/each}
    </div>

    {#if attachments.length}
      <div class="row scroll attachments">
        {#each attachments as item (item.id)}
          <div class="thumb">
            {#if item.preview}
              <img src={item.preview} alt="" />
            {:else}
              <span class="file">📄<br />{item.fileName}</span>
            {/if}
            <button class="remove" title="Entfernen" onclick={() => removeAttachment(item)}>✕</button>
          </div>
        {/each}
      </div>
    {/if}

    <div class="composer">
      <button
        class="attach"
        title={uploadAllowed ? "Datei anhängen (auch per Drag & Drop oder Einfügen)" : "Dateien hochladen ist für diesen Host aus"}
        onclick={() => (uploadAllowed ? filePicker?.click() : uploadOff())}>📎</button
      >
      <input
        bind:this={filePicker}
        type="file"
        multiple
        hidden
        onchange={(e) => {
          void add(Array.from(e.currentTarget.files ?? []));
          e.currentTarget.value = "";
        }}
      />
      <textarea
        bind:value={text}
        rows={Math.min(8, Math.max(1, text.split("\n").length))}
        placeholder={isAgent ? `Prompt an ${pane.agent}` : "Befehl"}
        onkeydown={onComposerKey}
        onpaste={onPaste}
      ></textarea>
      <button class="primary" disabled={!canSend} onclick={submit}>{isAgent ? "Senden" : "Ausführen"}</button>
    </div>
  </fieldset>
  {#if error}<p class="error">⚠ {error}</p>{/if}
</div>

{#if editingReplies}
  <QuickReplyEditor {replies} save={saveReplies} close={() => (editingReplies = false)} />
{/if}

<style>
  .input {
    border-top: 1px solid var(--line);
    padding: 8px 10px;
    position: relative;
  }
  .dropping {
    outline: 2px solid var(--accent);
    outline-offset: -4px;
    background: color-mix(in srgb, var(--accent) 8%, transparent);
  }
  fieldset {
    border: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 6px;
    min-width: 0;
  }
  .answers {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
  }
  .waiting {
    color: var(--blocked);
    font-weight: 500;
  }
  .confirm {
    background: var(--blocked);
    border-color: var(--blocked);
    color: #fff;
  }
  .spacer {
    flex: 1;
  }
  .row {
    display: flex;
    gap: 4px;
    align-items: center;
  }
  .scroll {
    overflow-x: auto;
    scrollbar-width: none;
  }
  .small {
    padding: 2px 9px;
    font-size: 12px;
    white-space: nowrap;
    max-width: 220px;
    overflow: hidden;
    text-overflow: ellipsis;
    flex: none;
  }
  .sep {
    width: 1px;
    height: 16px;
    background: var(--line);
    margin: 0 4px;
    flex: none;
  }
  .attachments {
    gap: 8px;
  }
  .thumb {
    position: relative;
    width: 56px;
    height: 56px;
    border-radius: 6px;
    overflow: hidden;
    background: var(--sidebar);
    flex: none;
  }
  .thumb img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  .file {
    display: block;
    font-size: 10px;
    text-align: center;
    padding: 4px;
    overflow: hidden;
    word-break: break-all;
    color: var(--secondary);
  }
  .remove {
    position: absolute;
    top: 2px;
    right: 2px;
    padding: 0 4px;
    font-size: 10px;
    border-radius: 50%;
    background: rgb(0 0 0 / 0.6);
    color: #fff;
    border: none;
  }
  .composer {
    display: flex;
    gap: 8px;
    align-items: flex-end;
  }
  .composer textarea {
    flex: 1;
    resize: none;
    line-height: 1.35;
  }
  .attach {
    border: none;
    background: none;
    padding: 4px;
  }
  .error {
    color: var(--danger);
    margin: 6px 0 0;
    user-select: text;
  }
</style>
