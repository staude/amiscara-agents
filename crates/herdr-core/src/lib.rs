//! Client-side state of one herdr server.
//!
//! [`SessionState`] is the pure model: built from `session.snapshot`, kept
//! current by events, no I/O. [`sync`] drives it against a live server and
//! publishes every change through a `watch` channel the apps can observe.

mod state;
pub mod sync;

pub use state::{Applied, BoardEntry, SessionState};
pub use sync::{SyncState, SyncStatus};
