//! Live herdr sessions for the apps, independent of how they are shown.
//!
//! The Swift apps reach this through `herdr-ffi`, the desktop app directly.

pub mod access;
pub mod link;
pub mod session;
pub mod sessions;
pub mod view;

pub use access::authorized_keys_line;
pub use herdr_core::diff::{DiffFile, DiffFileStatus, DiffHunk, DiffLine, DiffLineKind};
pub use link::{
    ADD_HOST_PREFIX, ADD_HOST_VERSION, AddHostLink, LinkError, decode_add_host_link,
    encode_add_host_link, public_key_fingerprint,
};
pub use session::{
    Endpoint, PaneFollow, PaneSink, ScrollStep, Session, SessionError, SshIdentity,
    TranscriptCursor, TranscriptEntry, TranscriptKind, TranscriptPage, UPLOAD_DIR,
};
#[cfg(unix)]
pub use sessions::local_herdr_sessions;
pub use sessions::{
    HerdrSessionEntry, is_valid_session_name, session_name_of_socket, session_socket_path,
};
