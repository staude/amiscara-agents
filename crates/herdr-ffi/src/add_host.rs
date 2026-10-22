//! The "add host" link of a QR code, see `herdr_session::link` for the
//! format.

pub use herdr_session::{ADD_HOST_PREFIX, ADD_HOST_VERSION, AddHostLink};

use herdr_session::LinkError;

use crate::FfiError;

/// Why a code or link was refused; the apps put it in words in the user's
/// language. Values from the code are shortened and free of control
/// characters.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum AddHostLinkError {
    #[error("the code is too long")]
    TooLong,
    #[error("not an Amiscara Agents code for adding a host")]
    NotALink,
    #[error("the code is damaged")]
    Damaged,
    #[error("unknown field {field:?} in the code")]
    UnknownField { field: String },
    #[error("field {field:?} appears more than once in the code")]
    DuplicateField { field: String },
    #[error("the code has no version")]
    MissingVersion,
    #[error("the version in the code is invalid")]
    BadVersion,
    /// From a newer app version; updating the app helps.
    #[error("the code comes from a newer app version")]
    NewerVersion,
    #[error("the code has no host")]
    MissingHost,
    #[error("invalid host {host:?} in the code")]
    BadHost { host: String },
    #[error("invalid port in the code")]
    BadPort,
    #[error("the code has no user")]
    MissingUser,
    #[error("invalid user {user:?} in the code")]
    BadUser { user: String },
    /// Not an absolute path, too long, or with `..` or control characters.
    #[error("invalid socket path in the code")]
    BadSocket,
    #[error("the code has no host key")]
    MissingKey,
    #[error("the host key in the code is not one line")]
    KeyNotOneLine,
    #[error("the host key in the code is too long")]
    KeyTooLong,
    #[error("the host key in the code is not a valid OpenSSH key")]
    BadKey,
    #[error("invalid name in the code")]
    BadName,
}

impl From<LinkError> for AddHostLinkError {
    fn from(err: LinkError) -> Self {
        match err {
            LinkError::TooLong => Self::TooLong,
            LinkError::NotALink => Self::NotALink,
            LinkError::Damaged => Self::Damaged,
            LinkError::UnknownField { field } => Self::UnknownField { field },
            LinkError::DuplicateField { field } => Self::DuplicateField { field },
            LinkError::MissingVersion => Self::MissingVersion,
            LinkError::BadVersion => Self::BadVersion,
            LinkError::NewerVersion => Self::NewerVersion,
            LinkError::MissingHost => Self::MissingHost,
            LinkError::BadHost { host } => Self::BadHost { host },
            LinkError::BadPort => Self::BadPort,
            LinkError::MissingUser => Self::MissingUser,
            LinkError::BadUser { user } => Self::BadUser { user },
            LinkError::BadSocket => Self::BadSocket,
            LinkError::MissingKey => Self::MissingKey,
            LinkError::KeyNotOneLine => Self::KeyNotOneLine,
            LinkError::KeyTooLong => Self::KeyTooLong,
            LinkError::BadKey => Self::BadKey,
            LinkError::BadName => Self::BadName,
        }
    }
}

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
pub fn encode_add_host_link(link: AddHostLink) -> Result<String, AddHostLinkError> {
    Ok(herdr_session::encode_add_host_link(link)?)
}

/// Reads a scanned code or opened link. Anything that is not exactly a
/// valid version 1 link is refused with the reason.
#[uniffi::export]
pub fn decode_add_host_link(text: String) -> Result<AddHostLink, AddHostLinkError> {
    Ok(herdr_session::decode_add_host_link(text)?)
}

/// `SHA256:...` of an OpenSSH public key line, e.g. a pinned host key.
#[uniffi::export]
pub fn public_key_fingerprint(public_openssh: String) -> Result<String, FfiError> {
    Ok(herdr_session::public_key_fingerprint(public_openssh)?)
}
