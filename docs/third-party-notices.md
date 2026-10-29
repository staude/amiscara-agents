# Third-party notices

Amiscara Agents is licensed under MIT or Apache-2.0. The apps bundle
third-party code under their own licenses, which a binary release has to
credit. All dependencies allow that:

- Rust (`Cargo.lock`): mostly MIT, Apache-2.0, BSD, ISC, Zlib and Unicode;
  MPL-2.0 for `uniffi*`, `cssparser`, `selectors`, `option-ext` and
  `dtoa-short`; CDLA-Permissive-2.0 for `webpki-roots`. No GPL or AGPL.
- npm (`apps/desktop/package-lock.json`): MIT, Apache-2.0, ISC, BSD and
  MPL-2.0 (`lightningcss`, build only).
- Android (Gradle): AndroidX, kotlinx and ZXing under Apache-2.0; JNA under
  LGPL-2.1 or Apache-2.0, used under Apache-2.0.
- Swift packages (Mac): Sparkle and KeyboardShortcuts under MIT.

MPL-2.0 is copyleft per file only: the crates are used unchanged, so a
notice is enough.

herdr itself is not part of this repository or of any app; the apps only
talk to its socket API.

## Generating the notices

Not checked in, since they change with every dependency update. Generate
them for a release:

```sh
# Rust: an HTML or Markdown list of all crates and their license texts
cargo install cargo-about --locked
cargo about init                      # once: writes about.toml and about.hbs
cargo about generate about.hbs > target/THIRD-PARTY-RUST.html

# Desktop front end
cd apps/desktop
npx license-checker --production --summary
npx license-checker --production --plainVertical > ../../target/THIRD-PARTY-NPM.txt

# Android: the OSS Licenses Gradle plugin or AboutLibraries can show the
# licenses in the app itself; until then the Gradle dependency report lists them
cd apps/android && ./gradlew :app:dependencies --configuration releaseRuntimeClasspath
```

`about.toml` should accept the licenses listed above
(`accepted = ["MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC",
"Zlib", "Unicode-3.0", "MPL-2.0", "CDLA-Permissive-2.0", "CC0-1.0"]`), so
a new dependency under another license stops the generation and gets a look.
