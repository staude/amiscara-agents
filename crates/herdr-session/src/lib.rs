//! Live herdr sessions for the apps, independent of how they are shown.
//!
//! The Swift apps reach this through `herdr-ffi`, the desktop app directly.

pub mod access;
pub mod link;
pub mod session;
pub mod view;

pub use access::authorized_keys_line;
pub use link::{
    ADD_HOST_PREFIX, ADD_HOST_VERSION, AddHostLink, decode_add_host_link, encode_add_host_link,
    public_key_fingerprint,
};
pub use session::{
    Endpoint, PaneFollow, PaneSink, Session, SessionError, SshIdentity, TranscriptCursor,
    TranscriptEntry, TranscriptKind, TranscriptPage, UPLOAD_DIR,
};
