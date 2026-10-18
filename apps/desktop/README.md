# Amiscara Agents for Windows and Linux

Tauri 2 app with a Svelte and TypeScript frontend. The Rust side
(`src-tauri`, crate `amiscara-desktop`) uses `herdr-session`, the same core
the Swift apps reach through `herdr-ffi`. Plan and phases: #141.

## Setup

Needs Node 22 or newer and the Rust toolchain of the workspace. On Linux
also WebKitGTK and friends:

```sh
sudo apt-get install libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev patchelf
```

On Windows, WebView2 ships with Windows 10 and 11.

```sh
cd apps/desktop
npm install
npx tauri dev       # window with hot reload
npm run check       # svelte-check, TypeScript
npx tauri build     # bundles under target/release/bundle
```

The Mac has the SwiftUI app; `npx tauri dev` works there for development.

## Icon

`icon.svg` is the dark variant of the app icon (`docs/icon/A`) without
glass. `npm run icons` renders it (needs `rsvg-convert`) and writes
`src-tauri/icons`.

## Deploy

CI builds installers on every push: NSIS and MSI for Windows, deb and
AppImage for Linux, as artifacts of the "Desktop app" job. Signed releases
follow in #146.
