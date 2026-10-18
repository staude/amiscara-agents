//! Live herdr sessions for the apps, independent of how they are shown.
//!
//! The Swift apps reach this through `herdr-ffi`, the desktop app directly.

pub mod access;
pub mod session;
pub mod view;

pub use access::authorized_keys_line;
pub use session::{
    Endpoint, PaneFollow, PaneSink, Session, SessionError, TranscriptCursor, TranscriptEntry,
    TranscriptKind, TranscriptPage, UPLOAD_DIR,
};
