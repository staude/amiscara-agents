<script lang="ts">
  import { t } from "../lib/i18n.svelte";
  import { untrack } from "svelte";
  import { errorText } from "../lib/core";

  // Add, edit, reorder and delete quick replies; "Done" saves, blank
  // entries are dropped.
  let {
    replies,
    save,
    close,
  }: { replies: string[]; save: (list: string[]) => Promise<void>; close: () => void } = $props();

  // As the Rust side starts the list (hosts.rs), in the current language.
  const defaults = () => [t("replyContinue"), "/compact", t("replyCommit"), t("replyCommitPr")];
  let list = $state(untrack(() => [...replies]));
  let error = $state<string | null>(null);

  function move(index: number, by: number) {
    const to = index + by;
    if (to < 0 || to >= list.length) return;
    [list[index], list[to]] = [list[to], list[index]];
  }

  async function done() {
    try {
      await save(list);
      close();
    } catch (err) {
      error = errorText(err);
    }
  }
</script>

<div class="backdrop" role="presentation" onclick={(e) => e.target === e.currentTarget && close()}>
  <div class="sheet">
    <h2>{t("quickReplies")}</h2>
    <ul>
      {#each list as _, index (index)}
        <li>
          <textarea bind:value={list[index]} rows="1" placeholder={t("text")}></textarea>
          <button title={t("moveUp")} disabled={index === 0} onclick={() => move(index, -1)}>↑</button>
          <button title={t("moveDown")} disabled={index === list.length - 1} onclick={() => move(index, 1)}>↓</button>
          <button class="delete" title={t("delete")} onclick={() => list.splice(index, 1)}>✕</button>
        </li>
      {/each}
    </ul>
    <p class="small">{t("quickRepliesHint")}</p>
    <div class="buttons">
      <button onclick={() => list.push("")}>+ {t("addQuickReply")}</button>
      <button onclick={() => (list = defaults())}>{t("restoreDefaults")}</button>
      <span class="spacer"></span>
      <button onclick={close}>{t("cancel")}</button>
      <button class="primary" onclick={done}>{t("done")}</button>
    </div>
    {#if error}<p class="error">{error}</p>{/if}
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
    max-height: calc(100vh - 32px);
    overflow: auto;
  }
  h2 {
    margin: 0 0 10px;
    font-size: 16px;
  }
  ul {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  li {
    display: flex;
    gap: 4px;
  }
  textarea {
    flex: 1;
    resize: vertical;
  }
  li button {
    padding: 2px 8px;
  }
  .delete {
    color: var(--danger);
  }
  .small {
    font-size: 12px;
    color: var(--secondary);
  }
  .buttons {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }
  .spacer {
    flex: 1;
  }
  .error {
    color: var(--danger);
  }
</style>
