# Screenshots

Screenshots for the README, the App Store, Google Play and the releases
come from a seeded demo instead of real projects, so every round shows the
same spaces, agents and text (#199).

```sh
scripts/screenshots.sh                       # all platforms this Mac can run
scripts/screenshots.sh --platform mac --platform android
scripts/screenshots.sh --appearance light    # default: dark
scripts/screenshots.sh --keep                # leave the demo session running
```

The PNGs land in `target/screenshots/<platform>/<view>.png`.
`scripts/screenshots/publish.sh` copies them scaled down into
`docs/screenshots/<platform>/`, which the README shows; commit those after
a new round. The Apple Watch is not captured yet (it needs a paired iPhone
and Watch simulator).

| Platform | How | Views |
|---|---|---|
| `mac` | debug build, window captured with `screencapture -l` | spaces with a waiting, working and finished agent, split tab, worktree, shell, search, Claude conversation, quick switcher, add host, overview, host dashboard, file browser, a dimmed pane after going offline, settings |
| `ios`, `ipad` | iPhone 18 Pro and iPad Pro 13-inch (M5) simulators, `simctl io screenshot`, status bar at 9:41 | the same without settings; the iPhone also its start screen |
| `duo` | iPhone Duo simulator, folded: the outer display (`--display=primary`) | like the iPhone |
| `duo-open` | iPhone Duo simulator, unfolded beforehand in Device Hub (buttons under the device; simctl cannot fold it): the inner display (`--display=primary-1`) | like the iPad |
| `tvos` | Apple TV 4K (3rd generation) simulator | overview, waiting agent, split tab, finished agent |
| `android` | emulator (AVD `Pixel_9`, started headless if none runs), `adb exec-out screencap`, demo status bar | start screen, the shared views without search and conversation, settings |
| `desktop` | the Windows/Linux app as a debug build against the vite dev server | the same as the Mac without overview, dashboard, file browser and offline pane |

Overview, dashboard, file browser and the offline pane exist only in the
Apple apps (`apple_views` in the script). A waiting agent in `space-waiting`
shows Claude Code's options as buttons on Mac, iPhone and iPad. The
summary of new output is not captured: it needs Apple Intelligence and
real output.

Other simulators or an AVD: `IPHONE_SIM`, `DUO_SIM`, `IPAD_SIM`, `TV_SIM` (UDIDs) and
`ANDROID_AVD`.

## The demo

`scripts/screenshots/demo.json` describes it; `scripts/screenshots/seed.py`
builds it:

- a herdr session of its own, `amiscara-screenshots`, never the default
  one; `seed.py --stop` (or the end of `screenshots.sh`) stops it and
  removes `/tmp/amiscara-demo`;
- fictional git repositories under `/tmp/amiscara-demo` with a fixed
  author and fixed dates, so commit hashes repeat, and a linked worktree;
- spaces such as `Shop/Web`, `Shop/API`, `Lab/WeatherStation`, `Blog` and
  `csvtool`, with tabs and a split tab;
- agents drawn by `scripts/screenshots/fake-agent.py`: fixed Claude Code and
  Codex screens. herdr cannot detect an agent in that script, so `seed.py`
  reports the states with `pane.report_agent`: waiting (an approval
  dialog), working, finished and idle;
- a neutral shell prompt (`ZDOTDIR` of the demo) instead of the user's own;
- Claude Code session files for the conversation view in
  `/tmp/amiscara-demo/home/.claude`, the home the apps get in the demo,
  never the real `~/.claude`.

## Demo mode of the apps

Debug builds only; release builds ignore all of it.

- **Apple apps** (`Model/DemoMode.swift`): launch arguments
  `-demoSocket`, `-demoSpace`, `-demoPane`, `-demoView`, `-demoSearch`,
  `-demoWindow`, `-demoHome` (the home for files and Claude conversations;
  the simulators ignore `SIMCTL_CHILD_HOME`, so the app sets `HOME`
  itself). `-demoView` also takes `overview` and `dashboard`
  (instead of a space), `files` (the pane's file browser; the script then
  sets the home to the demo root, so the browser opens the repository
  instead of falling back to the home) and `offline` (stops the session after 3 s, so the pane shows
  its last screen dimmed). The only host is the demo session's socket, kept in memory;
  nothing is saved, no notifications, widgets or iCloud records. The
  simulators reach the Mac's sockets directly, so they need no SSH.
- **Android** (`model/Demo.kt`): intent extras `demoHost`, `demoUser`,
  `demoSocket`, `demoKey`, `demoHostKey`, `demoPane`, `demoView`. The
  emulator reaches the Mac over SSH at 10.0.2.2 with a throwaway key; the
  script appends its line to `~/.ssh/authorized_keys` (restricted to the
  demo socket, no SFTP), removes it at the end and checks the file against
  its backup. Without SFTP there is no conversation view on Android.
- **Desktop** (`lib/demo.svelte.ts`, `demo_target`): `AMISCARA_DEMO` as
  JSON, and a `hosts.json` with only the demo host in the demo home.

## Not covered yet

- Apple Watch: its board comes from the iPhone over WatchConnectivity and
  needs a paired iPhone and Watch simulator.
- Notifications, widgets, the Mac menu bar extra, the Android widget and
  the desktop tray.
- The iPad status bar still shows the current date next to 9:41.
- Pixel-exact repeats: content, layout and text repeat; the Mac's
  translucent sidebar picks up what is behind the window, so two runs
  differ in a few tenths of a percent of the pixels.

## In CI

The release workflows are to regenerate the screenshots on a self-hosted
Mac runner (#205); its setup is in
[docs/self-hosted-runner.md](self-hosted-runner.md).
