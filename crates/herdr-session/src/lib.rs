//! Live herdr sessions for the apps, independent of how they are shown.
//!
//! The Swift apps reach this through `herdr-ffi`, the desktop app directly.

pub mod access;
mod forward;
pub mod link;
pub mod secrets;
pub mod session;
pub mod sessions;
pub mod view;

pub use access::authorized_keys_line;
pub use herdr_core::browse::{Directory, DirectoryEntry, EntryKind, FileContent, FilePreview};
pub use herdr_core::daily::{DailyItem, DailyItemKind, DailyLog};
pub use herdr_core::diff::{
    DiffFile, DiffFileStatus, DiffHunk, DiffLine, DiffLineKind, WorkingTreeDiff,
};
pub use herdr_core::github::GitHubRepo;
pub use herdr_core::spaces::SpaceSort;
pub use link::{
    ADD_HOST_PREFIX, ADD_HOST_VERSION, AddHostLink, LinkError, decode_add_host_link,
    encode_add_host_link, public_key_fingerprint,
};
pub use secrets::{ENV_DIR, is_reserved_env_name, is_valid_env_name};
pub use session::{
    ClaudeSessionItem, Endpoint, PaneFollow, PaneSink, ScrollStep, Session, SessionError,
    SshIdentity, TranscriptCursor, TranscriptEntry, TranscriptKind, TranscriptPage, UPLOAD_DIR,
};
#[cfg(unix)]
pub use sessions::local_herdr_sessions;
pub use sessions::{
    HerdrSessionEntry, is_valid_session_name, session_name_of_socket, session_socket_path,
};
