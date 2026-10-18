//! The "add host" link of a QR code, see `herdr_session::link` for the
//! format.

pub use herdr_session::{ADD_HOST_PREFIX, ADD_HOST_VERSION, AddHostLink};

use crate::FfiError;

/// What a scanned code says about a host.
#[uniffi::remote(Record)]
pub struct AddHostLink {
    pub name: String,
    pub host: String,
    pub port: u16,
    pub user: String,
    /// Empty means the default socket for `user`.
    pub socket_path: String,
    /// The server's host key as one OpenSSH public key line.
    pub host_key: String,
}

/// Builds the link for a QR code. Validates like [`decode_add_host_link`],
/// so a code this app shows is always one it would accept.
#[uniffi::export]
pub fn encode_add_host_link(link: AddHostLink) -> Result<String, FfiError> {
    Ok(herdr_session::encode_add_host_link(link)?)
}

/// Reads a scanned code or opened link. Anything that is not exactly a
/// valid version 1 link is refused with a German message for the user.
#[uniffi::export]
pub fn decode_add_host_link(text: String) -> Result<AddHostLink, FfiError> {
    Ok(herdr_session::decode_add_host_link(text)?)
}

/// `SHA256:...` of an OpenSSH public key line, e.g. a pinned host key.
#[uniffi::export]
pub fn public_key_fingerprint(public_openssh: String) -> Result<String, FfiError> {
    Ok(herdr_session::public_key_fingerprint(public_openssh)?)
}
