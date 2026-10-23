//! Named herdr sessions (#213). `herdr --session <name> server` runs a
//! separate server whose socket is `sessions/<name>/herdr.sock` next to the
//! default `herdr.sock`. A host entry points at one session through its
//! socket path, so the apps offer the name and derive the path from it.

pub use herdr_transport::HerdrSessionEntry;

use crate::session::SessionError;

/// Longest session name the apps accept; the socket path has to stay
/// within `sun_path` (104 bytes on macOS) anyway.
const MAX_NAME_LEN: usize = 64;
/// `sun_path` holds 104 bytes on macOS, NUL included.
const MAX_SOCKET_LEN: usize = 103;

/// Whether `name` can be a session: letters, digits, `-`, `_` and `.`,
/// not starting with a dot.
pub fn is_valid_session_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_NAME_LEN
        && !name.starts_with('.')
        && name
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.'))
}

/// The socket of session `name` for a host whose default socket is
/// `default_socket` (e.g. `/Users/frank/.config/herdr/herdr.sock`). An
/// empty name is the default session. `default_socket` may also be the
/// socket of another session; the result then sits next to it.
pub fn session_socket_path(default_socket: &str, name: &str) -> Result<String, SessionError> {
    let default_socket = default_socket.trim();
    let base;
    let default_socket = match session_name_of_socket(default_socket) {
        Some(other) => {
            base = default_socket
                .strip_suffix(&format!("/sessions/{other}/herdr.sock"))
                .map(|dir| format!("{dir}/herdr.sock"))
                .unwrap_or_default();
            base.as_str()
        }
        None => default_socket,
    };
    let name = name.trim();
    if name.is_empty() {
        return Ok(default_socket.to_owned());
    }
    if !is_valid_session_name(name) {
        return Err(SessionError::Key(format!(
            "unsuitable session name {name:?}"
        )));
    }
    let dir = default_socket
        .rsplit_once('/')
        .map(|(dir, _)| dir)
        .filter(|dir| !dir.is_empty())
        .ok_or_else(|| SessionError::Key(format!("unsuitable socket path {default_socket:?}")))?;
    let path = format!("{dir}/sessions/{name}/herdr.sock");
    if path.len() > MAX_SOCKET_LEN {
        return Err(SessionError::Key(format!("socket path too long: {path}")));
    }
    Ok(path)
}

/// The session a socket path belongs to: the name in
/// `…/sessions/<name>/herdr.sock`, `None` for any other path (the default
/// session or a socket somewhere else).
pub fn session_name_of_socket(socket_path: &str) -> Option<String> {
    let rest = socket_path.trim().strip_suffix("/herdr.sock")?;
    let (parent, name) = rest.rsplit_once('/')?;
    (parent.ends_with("/sessions") && is_valid_session_name(name)).then(|| name.to_owned())
}

/// The named herdr sessions on this machine, running or stopped.
#[cfg(unix)]
pub async fn local_herdr_sessions() -> Result<Vec<HerdrSessionEntry>, SessionError> {
    herdr_transport::local_herdr_sessions()
        .await
        .map_err(|err| SessionError::Files(err.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const DEFAULT: &str = "/Users/frank/.config/herdr/herdr.sock";

    #[test]
    fn socket_of_a_named_session() {
        assert_eq!(
            session_socket_path(DEFAULT, "herdr-remote-test").expect("path"),
            "/Users/frank/.config/herdr/sessions/herdr-remote-test/herdr.sock"
        );
        assert_eq!(session_socket_path(DEFAULT, " ").expect("path"), DEFAULT);
        // From another session's socket, back to the default or sideways.
        let other = session_socket_path(DEFAULT, "a").expect("path");
        assert_eq!(session_socket_path(&other, "").expect("path"), DEFAULT);
        assert_eq!(
            session_socket_path(&other, "b").expect("path"),
            "/Users/frank/.config/herdr/sessions/b/herdr.sock"
        );
    }

    #[test]
    fn refuses_unsuitable_names() {
        for name in [
            "../x",
            "a/b",
            ".hidden",
            "a b",
            "a\"b",
            "$HOME",
            &"x".repeat(65),
        ] {
            assert!(session_socket_path(DEFAULT, name).is_err(), "{name:?}");
        }
        assert!(session_socket_path("herdr.sock", "work").is_err());
        assert!(
            session_socket_path(
                &format!("/{}/herdr.sock", "d".repeat(60)),
                "x".repeat(40).as_str()
            )
            .is_err()
        );
    }

    #[test]
    fn name_from_a_socket_path() {
        let path = session_socket_path(DEFAULT, "work.2").expect("path");
        assert_eq!(session_name_of_socket(&path).as_deref(), Some("work.2"));
        assert_eq!(session_name_of_socket(DEFAULT), None);
        assert_eq!(session_name_of_socket(""), None);
        assert_eq!(session_name_of_socket("/srv/herdr.sock"), None);
        assert_eq!(session_name_of_socket("/x/sessions/.a/herdr.sock"), None);
        assert_eq!(session_name_of_socket("/x/other/a/herdr.sock"), None);
    }
}
