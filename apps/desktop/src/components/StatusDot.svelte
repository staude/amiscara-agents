<script lang="ts">
  import { stateLabel } from "../lib/spaces";
  import type { AgentState } from "../lib/types";

  /** `null` for a plain shell: an empty ring. */
  let { state }: { state: AgentState | null } = $props();
</script>

<span class="dot {state ?? 'shell'}" role="img" aria-label={state ? stateLabel(state) : "Shell"}></span>

<style>
  .dot {
    display: inline-block;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex: none;
    box-sizing: border-box;
  }
  .blocked {
    background: var(--blocked);
  }
  .working {
    background: var(--working);
  }
  .done {
    background: var(--done);
  }
  .idle {
    background: var(--secondary);
  }
  .unknown {
    background: var(--secondary);
    opacity: 0.5;
  }
  .shell {
    border: 1px solid var(--secondary);
  }
</style>
