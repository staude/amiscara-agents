<script lang="ts">
  import { t } from "../lib/i18n.svelte";
  import * as core from "../lib/core";

  // Which agent to start in a new space, tab or worktree: none, or one of
  // the kinds the host's herdr can start. The choice is remembered per
  // dialog (`storageKey`), so whoever always starts claude picks it once.
  let { hostId, storageKey, kind = $bindable(null) }: { hostId: string; storageKey: string; kind?: string | null } =
    $props();

  let kinds = $state<string[]>([]);

  $effect(() => {
    try {
      kind = localStorage.getItem(storageKey) || null;
    } catch {
      kind = null;
    }
    core.agentKinds(hostId).then((list) => (kinds = list)).catch(() => {});
  });

  function remember(value: string | null) {
    kind = value;
    try {
      if (value) localStorage.setItem(storageKey, value);
      else localStorage.removeItem(storageKey);
    } catch {
      // Not remembered; the choice still applies now.
    }
  }

  // The remembered choice stays selectable before the list has arrived.
  let options = $derived(kind && !kinds.includes(kind) ? [kind, ...kinds] : kinds);
</script>

<label class="field">
  <span>{t("startAgent")}</span>
  <select value={kind ?? ""} onchange={(e) => remember(e.currentTarget.value || null)}>
    <option value="">{t("noAgentShellOnly")}</option>
    {#each options as option (option)}
      <option value={option}>{option}</option>
    {/each}
  </select>
</label>
