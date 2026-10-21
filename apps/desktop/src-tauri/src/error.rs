use herdr_session::SessionError;
use serde::ser::{Serialize, SerializeStruct, Serializer};

/// What a command reports to the frontend, as `{ kind, message }`.
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error(transparent)]
    Session(#[from] SessionError),
    /// The host list could not be read or written.
    #[error("{0}")]
    Store(String),
    /// The OS key store refused (locked, no Secret Service, ...).
    #[error("{0}")]
    KeyStore(String),
    #[error("unknown host {0}")]
    NoHost(String),
    /// A host's configuration cannot be used as is; German, for the user.
    #[error("{0}")]
    Config(String),
}

impl AppError {
    fn kind(&self) -> &'static str {
        match self {
            Self::Session(err) => match err {
                SessionError::Key(_) => "key",
                SessionError::Unsupported(_) => "unsupported",
                SessionError::NotConnected(_) => "notConnected",
                SessionError::AgentBlocked(_) => "agentBlocked",
                SessionError::Rejected(_) => "rejected",
                SessionError::Upload(_) => "upload",
                SessionError::InvalidLink(_) => "invalidLink",
                SessionError::Files(_) => "files",
                SessionError::AgentWorking(_) => "agentWorking",
            },
            Self::Store(_) => "store",
            Self::KeyStore(_) => "keyStore",
            Self::NoHost(_) => "noHost",
            Self::Config(_) => "config",
        }
    }
}

impl Serialize for AppError {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut out = serializer.serialize_struct("AppError", 2)?;
        out.serialize_field("kind", self.kind())?;
        out.serialize_field("message", &self.to_string())?;
        out.end()
    }
}

impl From<keyring::Error> for AppError {
    fn from(err: keyring::Error) -> Self {
        Self::KeyStore(err.to_string())
    }
}
