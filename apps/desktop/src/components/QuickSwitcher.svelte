<script lang="ts">
  import { t } from "../lib/i18n.svelte";
  import { stateLabel } from "../lib/spaces";
  import { model } from "../lib/state.svelte";
  import { entries, filter } from "../lib/switcher";
  import StatusDot from "./StatusDot.svelte";

  // Ctrl+K: search spaces and agents on all hosts and jump there. Arrow
  // keys move the highlight, Enter opens it, Esc closes.
  let { close }: { close: () => void } = $props();

  let query = $state("");
  let index = $state(0);
  let list: HTMLUListElement | undefined = $state();
  let all = $derived(entries(model.hosts, model.updates));
  let shown = $derived(filter(all, query));
  let severalHosts = $derived(new Set(all.map((e) => e.hostId)).size > 1);

  $effect(() => {
    void query;
    index = 0;
  });

  $effect(() => {
    list?.querySelector(`[data-index="${index}"]`)?.scrollIntoView({ block: "nearest" });
  });

  function open(at: number) {
    const entry = shown[at];
    if (!entry) return;
    model.select(entry.hostId, entry.workspaceId, entry.paneId);
    close();
  }

  function onKey(event: KeyboardEvent) {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      index = Math.min(index + 1, shown.length - 1);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      index = Math.max(index - 1, 0);
    } else if (event.key === "Enter") {
      event.preventDefault();
      open(index);
    } else if (event.key === "Escape") {
      event.preventDefault();
      close();
    }
  }
</script>

<div class="backdrop" role="presentation" onclick={(e) => e.target === e.currentTarget && close()}>
  <div class="switcher" role="dialog" aria-label={t("quickSwitch")}>
    <!-- svelte-ignore a11y_autofocus -->
    <input bind:value={query} onkeydown={onKey} placeholder={t("findSpaceOrAgent")} autofocus spellcheck="false" />
    <ul bind:this={list}>
      {#each shown as entry, at (entry.id)}
        <li>
          <button
            class:current={at === index}
            data-index={at}
            onmousemove={() => (index = at)}
            onclick={() => open(at)}
          >
            <StatusDot state={entry.state} />
            <span class="text">
              <span class="title">{entry.title}{#if entry.kind === "agent" && entry.state && entry.state !== "idle"}<span class="state {entry.state}">{stateLabel(entry.state)}</span>{/if}</span>
              {#if entry.subtitle}<span class="sub">{entry.subtitle}</span>{/if}
            </span>
            <span class="kind">{entry.kind === "space" ? "Space" : "Agent"}{severalHosts ? ` · ${entry.hostName}` : ""}</span>
          </button>
        </li>
      {:else}
        <li class="none">{t("nothingFound")}</li>
      {/each}
    </ul>
  </div>
</div>

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgb(0 0 0 / 0.25);
    z-index: 25;
    display: flex;
    justify-content: center;
    align-items: flex-start;
    padding-top: 12vh;
  }
  .switcher {
    width: min(560px, calc(100vw - 32px));
    background: var(--bg);
    border: 1px solid var(--line);
    border-radius: 12px;
    box-shadow: 0 12px 40px rgb(0 0 0 / 0.25);
    overflow: hidden;
  }
  input {
    width: 100%;
    box-sizing: border-box;
    border: none;
    border-bottom: 1px solid var(--line);
    border-radius: 0;
    padding: 12px 14px;
    font-size: 16px;
    outline: none;
  }
  ul {
    list-style: none;
    margin: 0;
    padding: 4px;
    max-height: 50vh;
    overflow: auto;
  }
  button {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    text-align: left;
    border: none;
    background: none;
    border-radius: 6px;
    padding: 6px 10px;
  }
  .current {
    background: color-mix(in srgb, var(--accent) 20%, transparent);
  }
  .text {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-width: 0;
  }
  .title,
  .sub {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .sub,
  .kind {
    font-size: 12px;
    color: var(--secondary);
  }
  .state {
    font-size: 12px;
    margin-left: 6px;
  }
  .state.blocked {
    color: var(--blocked);
  }
  .state.working {
    color: var(--working);
  }
  .state.done {
    color: var(--done);
  }
  .none {
    padding: 12px;
    color: var(--secondary);
  }
</style>
