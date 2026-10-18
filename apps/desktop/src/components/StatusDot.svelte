<script lang="ts">
  import type { AgentState } from "../lib/types";

  let { state }: { state: AgentState | null } = $props();
</script>

<span class="dot {state ?? 'none'}" aria-hidden="true"></span>

<style>
  .dot {
    display: inline-block;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex: none;
    background: transparent;
  }
  .blocked {
    background: #ff9500;
  }
  .working {
    background: #0a84ff;
  }
  .done {
    background: #30d158;
  }
  .idle,
  .unknown {
    background: var(--secondary);
    opacity: 0.5;
  }
</style>
