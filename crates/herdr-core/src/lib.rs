//! Client-side state of one herdr server.
//!
//! [`SessionState`] is the pure model: built from `session.snapshot`, kept
//! current by events, no I/O. [`sync`] drives it against a live server and
//! publishes every change through a `watch` channel the apps can observe.
//! [`terminal`] turns pane content into styled lines, [`pane`] keeps one
//! open pane current, [`fullscreen`] looks back in a full-screen agent.
//! [`spaces`] orders the sidebar and groups spaces by
//! name, [`browse`] reads files below the home directory. [`question`]
//! finds an agent's choice question on the screen. [`usage`] sums the
//! tokens of Claude Code from its session files.

pub mod actions;
pub mod browse;
pub mod claude;
pub mod diff;
pub mod fullscreen;
pub mod pane;
pub mod question;
pub mod spaces;
mod state;
pub mod sync;
pub mod terminal;
pub mod usage;

pub use state::{
    Applied, BoardEntry, EDITOR_DONE_TOKEN, EDITOR_ID_TOKEN, EDITOR_PATH_TOKEN_PREFIX,
    EditorRequest, OPEN_DONE_TOKEN, OPEN_ID_TOKEN, OPEN_URL_PARTS, OPEN_URL_TOKEN_PREFIX,
    OpenRequest, SessionState, vscode_url,
};
pub use sync::{SyncState, SyncStatus};
