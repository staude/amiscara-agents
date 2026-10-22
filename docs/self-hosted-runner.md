# Self-hosted Mac runner

The screenshots (#199, #205) and, optionally, the Apple releases run on a
Mac of the maintainer as a GitHub Actions runner with the label
`amiscara-mac`. It has what the GitHub-hosted runners have to set up on
every run: herdr, Xcode with the simulators, the Android emulator and the
permission to capture windows.

The repository is public, so the runner must never run code from a pull
request. Only workflows started by a tag or by hand use it, and they check
that again (see [Rules for workflows](#rules-for-workflows)).

## Checklist

### 1. macOS user

- [ ] A separate standard user, e.g. `github-runner`, without admin rights.
      It must not see the maintainer's files, SSH keys, keychain or herdr
      sessions.
- [ ] Automatic login for this user (System Settings › Users & Groups ›
      Automatic login), or a session that stays logged in: the screenshots
      need a window server.
- [ ] Display sleep off for this user, screen saver off (System Settings ›
      Lock Screen: "Turn display off" never; "Require password" off for this
      session). A locked screen captures black windows.
- [ ] Remote Login on (System Settings › General › Sharing) and allowed for
      `github-runner`: the Android emulator reaches the demo session over SSH
      at 10.0.2.2 with a throwaway key that `scripts/screenshots.sh` adds to
      and removes from that user's `~/.ssh/authorized_keys`.

### 2. Tools (as `github-runner`)

- [ ] Xcode 27.1 in `/Applications/Xcode.app`, first launch done
      (`sudo xcodebuild -runFirstLaunch` by an admin), license accepted.
- [ ] Simulator runtimes iOS 27, tvOS 27 (and watchOS 27 for later), with
      the devices the script looks for: "iPhone 18 Pro", "iPad Pro 13-inch
      (M5)", "Apple TV 4K (3rd generation)" (or set `IPHONE_SIM`, `IPAD_SIM`,
      `TV_SIM` in the runner's `.env`). Check: `xcrun simctl list devices`.
- [ ] Homebrew, then `brew install xcodegen gh`.
- [ ] Rust via rustup (stable) with the targets
      `aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-tvos aarch64-apple-tvos-sim aarch64-linux-android x86_64-linux-android`,
      and `cargo install cargo-ndk`.
- [ ] Node 22 or later (`brew install node`).
- [ ] JDK 17 (`brew install --cask temurin@17`).
- [ ] Android SDK (Android Studio or the command-line tools) with
      `platforms;android-37.0`, `ndk;29.0.14206865`, `emulator`,
      `platform-tools` and the system image
      `system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a`;
      an AVD named `Pixel_9` on it (or `ANDROID_AVD` in `.env`).
      `ANDROID_HOME` set in the runner's `.env`.
- [ ] herdr, the version the apps support (`herdr --version`, currently
      0.9.5). The runner user gets no herdr session of its own besides the
      demo session `amiscara-screenshots` the script starts and stops.

### 3. Runner

- [ ] Repository › Settings › Actions › Runners › "New self-hosted runner",
      macOS, ARM64; follow the commands as `github-runner` in
      `~/actions-runner`.
- [ ] Labels: `self-hosted`, `macOS`, `ARM64`, `amiscara-mac`.
- [ ] Install it as a LaunchAgent of the logged-in user, not as a daemon:
      `./svc.sh install` and `./svc.sh start` run in that user's GUI session
      (a LaunchDaemon has no window server).
- [ ] `.env` in `~/actions-runner` with `ANDROID_HOME` and, if needed, the
      simulator and AVD overrides; `PATH` with Homebrew, cargo and the
      Android tools.

### 4. Permissions (once, in the runner user's session)

- [ ] Screen Recording for the runner (System Settings › Privacy &
      Security › Screen & System Audio Recording): add
      `~/actions-runner/bin/Runner.Listener`, or run
      `scripts/screenshots.sh --platform mac` once in Terminal as that user
      and allow the prompt for the process that asks.
- [ ] Accessibility is not needed; the apps are steered by launch arguments.
- [ ] First simulator and emulator start by hand once, so their first-run
      dialogs are gone.

### 5. Check

```sh
# as github-runner, in a checkout of the repository
scripts/screenshots.sh --platform mac
scripts/screenshots.sh --platform ios --platform tvos
scripts/screenshots.sh --platform android
herdr session list   # amiscara-screenshots stopped again
```

Then start the screenshot workflow by hand once and compare its artifact
with a local run.

## Rules for workflows

- Jobs on this runner use `runs-on: [self-hosted, amiscara-mac]` and only run
  on `push` of tags and on `workflow_dispatch`; never on `pull_request` or
  `pull_request_target`. Each such job also checks
  `github.event_name != 'pull_request'` and that the commit is on `main`.
- The screenshot job gets no signing secrets. Release jobs on this runner
  keep using the protected environments (`apple-release`,
  `desktop-release`) and clean up their temporary keychain.
- Settings › Actions › General: "Require approval for all external
  contributors" stays on.
- The runner user's `~/.ssh/authorized_keys` holds nothing but the
  temporary demo line during a run.
