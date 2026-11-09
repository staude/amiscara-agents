# Orca backend spike (#384)

Can Amiscara Agents show and operate agents running in Orca (onorca.dev, `stablyai/orca`) through its CLI over SSH?

**Recommendation: build the CLI backend.** All three criteria fixed before the measurement are met. The limits below belong in its design, above all the reliance on undocumented JSON and on Orca's agent hooks.

## Setup

- Orca 1.4.255 on macOS (arm64), Claude Code 2.1.319 as the agent, model Sonnet.
- A separate server with its own profile, never the running app: `ORCA_USER_DATA_PATH=<spike>/profile orca serve --port 6790 --bind 127.0.0.1 --no-pairing --json`. It ran as its own process (`--user-data-dir=<spike>/profile`).
- The running app's `orca-runtime.json` (mtime and hash) and `~/.claude/settings.json` were identical before and after.
- SSH used a throwaway key restricted with `from="127.0.0.1,::1"`.

**Limits of the measurement**

- SSH ran over loopback only. Real network latency comes on top.
- Version comparison is source only, see question 5: running the downloaded 1.4.250 build was not permitted in the spike session.
- Claude ran with `--dangerously-skip-permissions`, as Orca launched it here, so no permission prompt occurred. The `waiting` state was produced by an `AskUserQuestion` instead. `blocked` as an `agents[].state` was not observed.
- A restart of `orca serve` was tested, with the agent already `done`. A restart while an agent is `working` or `waiting`, a host reboot, and the CLI against the desktop app instead of `orca serve` were not.

## Question 1: Does the CLI report an agent's state?

Yes. `orca worktree ps --json` carries `result.worktrees[].agents[]`, one row per agent:

```json
{
  "paneKey": "792fe5fe-…:8ca2b295-…",
  "parentPaneKey": null,
  "state": "working",
  "agentType": "claude",
  "prompt": "Create a file named hello.txt …",
  "conversationName": "Hello.txt file creation",
  "lastAssistantMessage": null,
  "toolName": "Bash",
  "toolInput": "date",
  "interrupted": false,
  "mainAgent": { "state": "working", "stateStartedAt": 1794230477071 },
  "stateStartedAt": 1794230477071,
  "updatedAt": 1794230485612,
  "hasLivePty": true,
  "programStatus": { "state": "working", "message": "Printing current date", "observedAt": 1794230483755 }
}
```

Transitions from polling every 2 s on the host itself, without SSH (`state`, `toolName`, `programStatus.state`, `programStatus.kind`):

```text
14:21:16 done     -                working
14:21:18 working  -                working
14:21:25 working  Bash             working
14:21:29 done     Bash             done
14:21:53 working  -                working
14:21:55 waiting  AskUserQuestion  blocked  question
14:22:17 working  AskUserQuestion  working
14:22:19 done     AskUserQuestion  done
```

A second run with a different prompt, polled over SSH, showed `working`, `working Bash`, then `waiting AskUserQuestion blocked question`. That log stopped while the agent was waiting, so `done` was only observed in the local poll.

- `done` appeared once for 2 s right after launch, before the first turn, with `lastAssistantMessage` empty and `programStatus.state` still `working`. Seen in one launch only. A client should use those two fields to tell it from a finished turn, since it may connect after the launch.
- While waiting, `programStatus.message` holds the question (`answer: Red or blue? (Red · Blue)`), enough for a notification.
- `agents[].paneKey` is `<tabId>:<leafId>` and joins `terminal list --json`.
- `terminal list` and `terminal show` report `agentIdentity` but no state. `terminal show` carries `agentWait` (null here), and `worktree ps --agent-wait` adds the same field per agent row.

**Dependency.** `agents[].state` comes from agent hooks. Orca writes them to the global `~/.claude/settings.json` (entries calling `~/.orca/agent-hooks/claude-hook.sh`) and keeps per-pane data under `<profile>/agent-hooks/hook-metadata/`. A host without them was not tested. By the contract, `agentWait` has non-hook sources too (`RuntimeTerminalInteractiveWaitSource`: `hook`, `prompt-text`, `title`), so waiting might still be detected there. `state` is a required field of an agent row, so without hooks the row itself is the likely thing to be missing. A backend has to report a terminal with `agentIdentity` but no agent row as "status unavailable" rather than show it as idle.

## Question 2: How fast is `terminal read --screen` over SSH?

Fast enough. Serial runs, loopback, `terminal read --terminal <h> --screen --json`:

| Path | Runs | Min | Median | p95 |
|---|---|---|---|---|
| Local, no SSH | 50 | 144 ms | 150 ms | 154 ms |
| SSH, new connection | 50 | 281 ms | 296 ms | 321 ms |
| SSH, `ControlMaster` | 50 | 151 ms | 157 ms | 164 ms |
| Baseline `ssh … true`, new connection | 50 | 112 ms | 126 ms | 209 ms |
| Baseline `ssh … true`, `ControlMaster` | 50 | 11 ms | 15 ms | 18 ms |

`worktree ps --json` costs the same: 307 ms median on a new connection, 159 ms with `ControlMaster` (20 runs each).

The target was a median under 1 s (`Pacing::default().quiet`, `crates/herdr-client/src/pane.rs`). An earlier new-connection series measured 512 ms median under other load, also within the target.

- Each call starts Electron in Node mode: about 165 ms of client CPU on the host per local call. `follow_paced` reads and then sleeps, so a cycle is the read plus the interval. At the quiet interval of 1 s that is about 14 % of one core per polled pane.
- A pane with continuous output runs at `busy: 150 ms`: a cycle of about 300 ms with `ControlMaster`, so about 55 % of a core per pane (about 37 % with a new connection each time, whose cycle is about 450 ms). Polling is good enough for a quiet or slowly changing pane and expensive for one streaming output. A backend should use a slower busy interval for Orca, poll only the visible pane, and use one shared `worktree ps` for state.
- The server side comes on top. `ps` showed 0.6 % average CPU over the server's lifetime; the cost per call on the server and `sshd` was not isolated.
- `tail` is `string[]`, text only, no colours. Live panes would be plain text: the same as herdr-core panes, a visible step down from herdr server panes.
- `tailRows` gives wrap metadata per line, and the result's `source` says whether a rendered screen came back (`screen`, `stream`, `screen-unavailable`).
- `draft` is UI-only composer text. It held text nobody typed in this run, so it must not be shown as input.

## Question 3: How do worktrees and terminals map, and are handles stable?

`terminal list --include-visual-layouts --json` gives the layout as a tree. The run below had one tab with one terminal, so only that shape was observed. By the 1.4.255 contract both levels are recursive: `root` is `group` or `split` (`RuntimeTerminalVisualLayoutNode`), and `tabs[].panes` is `terminal` or `pane-split` (`RuntimeTerminalVisualPaneNode`). A parser has to walk both.

| Amiscara | Orca | Key |
|---|---|---|
| Space | Worktree | `worktreeId` (`<repoId>::<path>`) |
| Tab | Tab of a group | `tabId` |
| Pane | Terminal leaf | `leafId`, `handle` |

```json
{
  "worktreeId": "e86987f5-…::<spike>/repo",
  "root": {
    "type": "group",
    "activeTabId": "792fe5fe-…",
    "tabs": [{
      "tabId": "792fe5fe-…",
      "title": "Terminal",
      "activeLeafId": "8ca2b295-…",
      "panes": { "type": "terminal", "handle": "term_984a8bd7-…", "tabId": "792fe5fe-…", "leafId": "8ca2b295-…", "connected": true, "active": true }
    }]
  }
}
```

The server was stopped with SIGINT and started again:

| Field | Before | After |
|---|---|---|
| `handle` | `term_984a8bd7-…` | same |
| `ptyId` | `e86987f5-…@@e8e96bdc` | same |
| `incarnationId` | `8395237d-…` | same |
| `tabId`, `leafId` | `792fe5fe-…`, `8ca2b295-…` | same |
| `runtimeId` (`_meta`) | `7e85bc27-…` | `af32de89-…` |

The agent process and its screen survived, and the old handle still read the screen. `runtimeId` signals a restart. `state` and `lastAssistantMessage` survived; `programStatus` and `conversationName` were absent afterwards, so a question held in `programStatus.message` would be lost.

Only `done` was seen across the restart, because the agent had already finished. An agent changing state during the roughly 14 s outage was not tested, and its hook would have no server to report to. The contract has an uncommented `restoredUnconfirmed?: boolean` on agent rows, but it was not set in this restart, so it cannot be relied on. A backend should treat a state read right after a `runtimeId` change as unconfirmed.

While the server is down, `terminal list` and `terminal read` fail with exit 1 and `runtime_unavailable` (`ok: false`, message "Start the Orca app first"). Terminals are not lost, so a backend should retry rather than drop panes. Handles are not guaranteed by Orca across a reboot; resolve them from `terminal list` on every (re)connect.

## Question 4: What must hold on the host?

- **Server running.** Only `orca serve` was exercised; the CLI against a running desktop app was not. `orca status --json` over a stopped server exits 0 with `runtime.state: "not_running"`, `reachable: false`, `app.running: false`, and started no process. It is safe as a probe, but a backend has to read `reachable`, because the exit code says nothing about it.
- **Absolute path to `orca`.** A non-interactive SSH session had `PATH=<home>/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin` and no `orca` on it. The backend must call a configured or discovered path (here `/opt/homebrew/bin/orca`), and the forced command must not depend on `PATH`.
- **Hooks installed**, see question 1.
- **Headless:** `orca serve --help` says the packaged macOS app runs Electron and needs a desktop login, and that over SSH with nobody logged in `ORCA_SERVE_RUNTIME=orcad` is required. Not tested.

## Question 5: How does the output change between releases?

Source comparison only (`src/shared/runtime-terminal-contracts.ts`, `src/shared/runtime-worktree-contracts.ts`, `src/cli/specs/core.ts`, tags `v1.4.200` to `v1.4.255`, roughly two months; the state set from `agent-status-types.ts`, which moved to `src/shared/agent-status/contracts/`). No run against an older build.

- The fields a backend reads are present in both: `paneKey`, `state`, `handle`, `ptyId`, `tabId`, `leafId`, `tail`.
- The state set is identical: `working`, `blocked`, `waiting`, `done`.
- For those read paths, changes are additions, optional and commented as absent on old hosts (`mainAgent`, `programStatus`, `hasLivePty`, `conversationName`, `tailRows`, `verdict`).
- Elsewhere the files changed substantially, mostly by moving code: `RuntimeTerminalSend` now lives in its own file (so the write result was not compared here), and the `repo` command specs left `core.ts`. `agentIdentity` also changed type, from `TuiAgent` to `TerminalAgent`, and no longer implies launch support.
- Commands stay at the same paths (`worktree ps`, `terminal list/show/read`).
- The churn is real: 106 to 194 changed lines per file over those two months, and 12 to 83 between 1.4.250 and 1.4.255 alone.

There is no JSON schema and no stability promise, so a backend needs tolerant parsing, a tested version range, and a clear message on an unknown shape.

## Write test

Against the test server only: `terminal send --terminal <h> --text … --enter --wait-submit 10 --json`:

```json
{ "accepted": true, "prompt": { "stages": ["input_accepted", "turn_started"], "provider": "claude", "observation": "supported" } }
```

## Criteria

| Criterion (fixed before measuring) | Result |
|---|---|
| Working, waiting and done distinguishable in a real run | Met (question 1) |
| Screen read over SSH, median under 1 s | Met: 296 ms new connection, 157 ms `ControlMaster`, loopback only (question 2) |
| Terminals found again automatically after an Orca restart | Met: `handle`, `ptyId`, `incarnationId`, `tabId` and `leafId` unchanged (question 3) |

## Recommendation

Build it, read-only first, with its own forced-command case. Design points from this spike:

- One `worktree ps --json` poll for state, `terminal read --screen` only for the visible pane at a longer busy interval than herdr's 150 ms, over one shared SSH connection.
- Walk the recursive layout (`split`, `pane-split`), and treat state read right after a `runtimeId` change as unconfirmed.
- Resolve `orca` by absolute path; never call it through `$SSH_ORIGINAL_COMMAND`.
- An allowlist of subcommands in the forced command, because the CLI can also run `terminal close --all` and `computer`.
- Accept unknown fields, show a terminal with `agentIdentity` but no agent row as "status unavailable", and tell the `done` right after launch from a finished turn by its empty `lastAssistantMessage`.
- Check the desktop-app case and a restart during `working` or `waiting` early, since this spike covered neither.
- Text-only panes for now: Orca's rendered colours are only available through the WebSocket path, which stays out of scope.
