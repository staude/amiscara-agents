//! Client-side state of one herdr server.
//!
//! [`SessionState`] is the pure model: built from `session.snapshot`, kept
//! current by events, no I/O. [`sync`] drives it against a live server and
//! publishes every change through a `watch` channel the apps can observe.
//! [`terminal`] turns pane content into styled lines, [`pane`] keeps one
//! open pane current. [`spaces`] orders the sidebar and groups spaces by
//! name.

pub mod actions;
pub mod pane;
pub mod spaces;
mod state;
pub mod sync;
pub mod terminal;

pub use state::{Applied, BoardEntry, SessionState};
pub use sync::{SyncState, SyncStatus};
