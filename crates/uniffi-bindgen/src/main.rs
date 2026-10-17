//! Generates the Swift bindings for `herdr-ffi` (`scripts/build-ffi.sh`).
//! A crate of its own, so the generator never ends up in the app library.

fn main() {
    uniffi::uniffi_bindgen_main()
}
