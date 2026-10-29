use herdr_session::SessionError;
use serde::ser::{Serialize, SerializeStruct, Serializer};

/// What a command reports to the frontend, as `{ kind, message }`, plus
/// `code` and `host` for a configuration error and `link` for a refused
/// link, so the webview can put them in words.
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
    /// A host's configuration or a request cannot be used as is.
    #[error(transparent)]
    Config(#[from] ConfigError),
}

/// Why a host or a request does not work, as a code the webview words in
/// the user's language; the text here is for logs.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ConfigError {
    #[error("host and user are missing")]
    MissingHostUser,
    #[error("the socket path must be absolute")]
    RelativeSocket,
    #[error("a local herdr socket works only on Linux")]
    LocalSocketUnix,
    #[error("this host has no key of its own")]
    NoOwnKey,
    #[error("the key of this host is missing from the key store")]
    KeyMissing,
    #[error("input is turned off for this host")]
    InputOff,
    #[error("file uploads are off for {host}")]
    UploadOff { host: String },
    /// herdr reports no working directory for the pane (#288).
    #[error("no folder is known for this pane")]
    NoFolder,
    /// Requests the webview never makes, and system errors; not worded.
    #[error("{0}")]
    Other(String),
}

impl ConfigError {
    fn code(&self) -> &'static str {
        match self {
            Self::MissingHostUser => "missingHostUser",
            Self::RelativeSocket => "relativeSocket",
            Self::LocalSocketUnix => "localSocketUnix",
            Self::NoOwnKey => "noOwnKey",
            Self::KeyMissing => "keyMissing",
            Self::InputOff => "inputOff",
            Self::UploadOff { .. } => "uploadOff",
            Self::NoFolder => "noFolder",
            Self::Other(_) => "other",
        }
    }
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
                SessionError::Forward(_) => "forward",
                SessionError::FileChanged(_) => "fileChanged",
                SessionError::SavedNotRead(_) => "savedNotRead",
                SessionError::Health(_) => "health",
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
        let mut out = serializer.serialize_struct("AppError", 4)?;
        out.serialize_field("kind", self.kind())?;
        out.serialize_field("message", &self.to_string())?;
        match self {
            Self::Config(err) => {
                out.serialize_field("code", err.code())?;
                if let ConfigError::UploadOff { host } = err {
                    out.serialize_field("host", host)?;
                }
            }
            Self::Session(SessionError::InvalidLink(link)) => out.serialize_field("link", link)?,
            _ => {}
        }
        out.end()
    }
}

impl From<herdr_session::LinkError> for AppError {
    fn from(err: herdr_session::LinkError) -> Self {
        Self::Session(err.into())
    }
}

impl From<keyring::Error> for AppError {
    fn from(err: keyring::Error) -> Self {
        Self::KeyStore(err.to_string())
    }
}
