//! Keys and `authorized_keys` lines for the hosts.

use herdr_transport::{TransportError, keys};

use crate::session::SessionError;

/// The `authorized_keys` line for a client key (#132): no forwarding at all
/// (`restrict`), and a forced command that connects every session to the
/// herdr socket. With `allow_sftp`, an SFTP request runs `sftp-server`
/// instead (uploads, history), which can read and write all files of the
/// user; without it SFTP is refused. With `allow_web`, `amiscara-tcp <port>`
/// connects to `localhost:<port>` on the host (#247: pages of dev servers
/// that an agent opens), after printing `amiscara-tcp` so the app can tell
/// it from a line without that case (`amiscara-tcp-closed` when nothing
/// listens there). The apps reach herdr through a session
/// running `herdr` once sshd refuses their streamlocal channel.
///
/// `socket_path`: the host's `herdr.sock` when it is not the default
/// `$HOME/.config/herdr/herdr.sock`; absolute, without quotes or `$`.
///
/// Lines from before used `restrict,port-forwarding` for streamlocal, which
/// also allowed TCP forwarding (`permitopen` cannot narrow it, it refuses
/// streamlocal too); they keep working.
pub fn authorized_keys_line(
    public_openssh: &str,
    allow_sftp: bool,
    allow_web: bool,
    socket_path: Option<&str>,
) -> Result<String, SessionError> {
    let key = keys::parse_public(public_openssh.trim()).map_err(key_error)?;
    let line = key
        .to_openssh()
        .map_err(|err| SessionError::Key(err.to_string()))?;
    Ok(format!(
        "{} {line}",
        gate_options(allow_sftp, allow_web, socket_path)?
    ))
}

/// The options part of an `authorized_keys` line, see
/// [`authorized_keys_line`].
pub(crate) fn gate_options(
    allow_sftp: bool,
    allow_web: bool,
    socket_path: Option<&str>,
) -> Result<String, SessionError> {
    let socket = match socket_path.map(str::trim).filter(|path| !path.is_empty()) {
        None => "$HOME/.config/herdr/herdr.sock",
        Some(path)
            if path.starts_with('/')
                && !path
                    .chars()
                    .any(|ch| matches!(ch, '"' | '\\' | '$' | '`' | '\'') || ch.is_control()) =>
        {
            path
        }
        Some(path) => {
            return Err(SessionError::Key(format!(
                "unsuitable socket path {path:?}"
            )));
        }
    };
    let files = if allow_sftp {
        "exec /usr/libexec/sftp-server"
    } else {
        "exit 1"
    };
    // Only digits reach `nc`, so the port needs no quotes.
    let web = if allow_web {
        " amiscara-tcp*) p=${SSH_ORIGINAL_COMMAND#amiscara-tcp }; case $p in ''|*[!0-9]*) exit 1 ;; esac; nc -z localhost $p || { echo amiscara-tcp-closed; exit 1; }; echo amiscara-tcp; exec nc localhost $p ;;"
    } else {
        ""
    };
    Ok(format!(
        "restrict,command=\"case \\\"$SSH_ORIGINAL_COMMAND\\\" in *sftp*) {files} ;;{web} *) exec nc -U \\\"{socket}\\\" ;; esac\""
    ))
}

pub(crate) fn key_error(err: TransportError) -> SessionError {
    SessionError::Key(err.to_string())
}

#[cfg(test)]
mod tests {
    use super::authorized_keys_line;

    #[test]
    fn key_lines_allow_only_the_herdr_socket() {
        let key = herdr_transport::keys::generate_ed25519("t")
            .expect("key")
            .public_openssh;
        let line = authorized_keys_line(&key, false, false, None).expect("line");
        assert!(line.starts_with(r#"restrict,command="case \"$SSH_ORIGINAL_COMMAND\" in *sftp*) exit 1 ;; *) exec nc -U \"$HOME/.config/herdr/herdr.sock\" ;; esac" ssh-ed25519 "#), "{line}");
        assert!(!line.contains("port-forwarding"));
        assert!(!line.contains("amiscara-tcp"));
        let files = authorized_keys_line(&key, true, false, Some("/srv/herdr.sock")).expect("line");
        assert!(
            files.contains("*sftp*) exec /usr/libexec/sftp-server ;;")
                && files.contains(r#"nc -U \"/srv/herdr.sock\""#),
            "{files}"
        );
        for bad in ["relative.sock", "/a\"b", "/$HOME/x", "/a`id`"] {
            assert!(
                authorized_keys_line(&key, false, false, Some(bad)).is_err(),
                "{bad}"
            );
        }
    }

    #[test]
    fn web_forwarding_adds_only_the_localhost_case() {
        let key = herdr_transport::keys::generate_ed25519("t")
            .expect("key")
            .public_openssh;
        let line = authorized_keys_line(&key, false, true, None).expect("line");
        assert!(
            line.contains(r#"*sftp*) exit 1 ;; amiscara-tcp*) p=${SSH_ORIGINAL_COMMAND#amiscara-tcp }; case $p in ''|*[!0-9]*) exit 1 ;; esac; nc -z localhost $p || { echo amiscara-tcp-closed; exit 1; }; echo amiscara-tcp; exec nc localhost $p ;; *) exec nc -U \"$HOME/.config/herdr/herdr.sock\" ;; esac" ssh-ed25519 "#),
            "{line}"
        );
        assert!(line.starts_with("restrict,command=") && !line.contains("port-forwarding"));
    }
}
