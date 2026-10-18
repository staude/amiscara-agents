//! The "add host" link that a QR code carries from a device that knows a
//! host to one that does not yet, so nothing is typed and the host key
//! needs no manual fingerprint check.
//!
//! Format, version 1 (one line, fields in any order, each at most once):
//!
//! ```text
//! amiscara-agents://add-host?v=1&name=work&host=work.staude.internal&port=22
//!     &user=frank&socket=/Users/frank/.config/herdr/herdr.sock
//!     &key=ssh-ed25519%20AAAAC3Nz...
//! ```
//!
//! - `v` (required): format version. A newer version is refused with a hint
//!   to update the app instead of being half understood.
//! - `name` (optional): display name, defaults to `host`.
//! - `host`, `user`, `key` (required): SSH host name or IP, login and the
//!   server's OpenSSH public host key line.
//! - `port` (optional): SSH port, defaults to 22.
//! - `socket` (optional): absolute path of `herdr.sock` on the server;
//!   missing means the app's default for the user.
//!
//! Values are percent-encoded (RFC 3986). `+` is a literal plus, never a
//! space: base64 in the key uses it. Unknown fields are refused, because a
//! code is a trust anchor and must mean exactly what the scanning app shows.
//! The link is also registered as a URL scheme, so it can be opened directly.
//! The scheme was `herdr-remote://` before the app became Amiscara Agents;
//! such links are refused, there were no users to keep them working for.

use herdr_transport::keys;

use crate::FfiError;

/// Scheme and path of the link; the query follows.
pub const ADD_HOST_PREFIX: &str = "amiscara-agents://add-host?";
/// The only format version this build understands.
pub const ADD_HOST_VERSION: u32 = 1;

/// Upper bound for the whole link. A QR code at error correction level M
/// holds about 2300 bytes; RSA host keys push links past 700 bytes.
const MAX_LINK_LEN: usize = 4096;
const MAX_NAME_CHARS: usize = 64;
const MAX_HOST_LEN: usize = 253;
const MAX_USER_LEN: usize = 64;
/// `sun_path` holds 104 bytes on macOS and 108 on Linux, NUL included.
const MAX_SOCKET_LEN: usize = 107;
const MAX_KEY_LEN: usize = 2048;

/// What a scanned code says about a host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
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
    let link = validate(link)?;
    let mut out = format!("{ADD_HOST_PREFIX}v={ADD_HOST_VERSION}");
    let mut push = |key: &str, value: &str| {
        out.push('&');
        out.push_str(key);
        out.push('=');
        out.push_str(&percent_encode(value));
    };
    push("name", &link.name);
    push("host", &link.host);
    push("port", &link.port.to_string());
    push("user", &link.user);
    if !link.socket_path.is_empty() {
        push("socket", &link.socket_path);
    }
    push("key", &link.host_key);
    Ok(out)
}

/// Reads a scanned code or opened link. Anything that is not exactly a
/// valid version 1 link is refused with a German message for the user.
#[uniffi::export]
pub fn decode_add_host_link(text: String) -> Result<AddHostLink, FfiError> {
    let text = text.trim();
    if text.len() > MAX_LINK_LEN {
        return Err(invalid("Der Code ist zu lang."));
    }
    let query = text
        .get(..ADD_HOST_PREFIX.len())
        .filter(|prefix| prefix.eq_ignore_ascii_case(ADD_HOST_PREFIX))
        .and_then(|_| text.get(ADD_HOST_PREFIX.len()..))
        .ok_or_else(|| invalid("Das ist kein Amiscara-Agents-Code zum Hinzufügen eines Hosts."))?;

    let mut version = None;
    let mut name = None;
    let mut host = None;
    let mut port = None;
    let mut user = None;
    let mut socket = None;
    let mut key = None;
    for pair in query.split('&') {
        let (field, raw) = pair
            .split_once('=')
            .ok_or_else(|| invalid("Der Code ist beschädigt."))?;
        let value = percent_decode(raw)?;
        let slot = match field {
            "v" => &mut version,
            "name" => &mut name,
            "host" => &mut host,
            "port" => &mut port,
            "user" => &mut user,
            "socket" => &mut socket,
            "key" => &mut key,
            _ => {
                return Err(invalid(&format!(
                    "Der Code enthält ein unbekanntes Feld „{}“.",
                    printable(field)
                )));
            }
        };
        if slot.replace(value).is_some() {
            return Err(invalid(&format!(
                "Das Feld „{field}“ steht mehrfach im Code."
            )));
        }
    }

    let version: u32 = version
        .ok_or_else(|| invalid("Dem Code fehlt die Versionsangabe."))?
        .parse()
        .map_err(|_| invalid("Die Versionsangabe im Code ist ungültig."))?;
    if version > ADD_HOST_VERSION {
        return Err(invalid(
            "Der Code stammt von einer neueren App-Version. Bitte aktualisieren Sie Amiscara Agents.",
        ));
    }
    if version != ADD_HOST_VERSION {
        return Err(invalid("Die Versionsangabe im Code ist ungültig."));
    }
    let port = match port {
        None => 22,
        Some(port) => parse_port(&port)?,
    };
    validate(AddHostLink {
        name: name.unwrap_or_default(),
        host: host.ok_or_else(|| invalid("Im Code fehlt der Host."))?,
        port,
        user: user.ok_or_else(|| invalid("Im Code fehlt der Benutzer."))?,
        socket_path: socket.unwrap_or_default(),
        host_key: key.ok_or_else(|| invalid("Im Code fehlt der Host-Key."))?,
    })
}

/// `SHA256:...` of an OpenSSH public key line, e.g. a pinned host key.
#[uniffi::export]
pub fn public_key_fingerprint(public_openssh: String) -> Result<String, FfiError> {
    let key =
        keys::parse_public(public_openssh.trim()).map_err(|err| FfiError::Key(err.to_string()))?;
    Ok(keys::fingerprint(&key))
}

/// Checks every field and returns them normalized (name trimmed, key
/// re-encoded). Other fields are taken as they are: stray whitespace or a
/// line break in a code is an error, not something to repair silently.
fn validate(link: AddHostLink) -> Result<AddHostLink, FfiError> {
    let host = link.host;
    if host.is_empty() {
        return Err(invalid("Im Code fehlt der Host."));
    }
    // A leading "-" could be read as an ssh option elsewhere; brackets,
    // spaces and the like have no place in a host name or IP address.
    if host.len() > MAX_HOST_LEN
        || host.starts_with(['-', '.'])
        || !host
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | ':'))
    {
        return Err(invalid(&format!(
            "Der Host „{}“ im Code ist ungültig.",
            printable(&host)
        )));
    }

    if link.port == 0 {
        return Err(invalid("Der Port im Code ist ungültig."));
    }

    let user = link.user;
    if user.is_empty() {
        return Err(invalid("Im Code fehlt der Benutzer."));
    }
    if user.len() > MAX_USER_LEN
        || user.starts_with('-')
        || !user
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
    {
        return Err(invalid(&format!(
            "Der Benutzer „{}“ im Code ist ungültig.",
            printable(&user)
        )));
    }

    let socket_path = link.socket_path;
    if !socket_path.is_empty()
        && (!socket_path.starts_with('/')
            || socket_path.len() > MAX_SOCKET_LEN
            || socket_path.chars().any(char::is_control)
            || socket_path.split('/').any(|part| part == ".."))
    {
        return Err(invalid(
            "Der Socket-Pfad im Code ist ungültig. Erwartet wird ein absoluter Pfad.",
        ));
    }

    let host_key = link.host_key.as_str();
    if host_key.contains(['\n', '\r']) {
        return Err(invalid("Der Host-Key im Code muss genau eine Zeile sein."));
    }
    if host_key.len() > MAX_KEY_LEN {
        return Err(invalid("Der Host-Key im Code ist zu lang."));
    }
    let bad_key = || invalid("Der Host-Key im Code ist kein gültiger OpenSSH-Schlüssel.");
    let host_key = keys::parse_public(host_key)
        .map_err(|_| bad_key())?
        .to_openssh()
        .map_err(|_| bad_key())?;

    let name = link.name.trim();
    let name = if name.is_empty() {
        host.clone()
    } else {
        name.to_owned()
    };
    if name.chars().count() > MAX_NAME_CHARS || name.chars().any(char::is_control) {
        return Err(invalid("Der Name im Code ist ungültig."));
    }

    Ok(AddHostLink {
        name,
        host,
        port: link.port,
        user,
        socket_path,
        host_key,
    })
}

fn parse_port(text: &str) -> Result<u16, FfiError> {
    // Digits only: `u16::from_str` would also take a leading "+".
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
        return Err(invalid("Der Port im Code ist ungültig."));
    }
    match text.parse::<u16>() {
        Ok(port) if port != 0 => Ok(port),
        _ => Err(invalid("Der Port im Code ist ungültig.")),
    }
}

/// Keeps RFC 3986 unreserved characters plus `/` and `:` (readable paths
/// and IPv6 addresses); everything else becomes `%XX`, `+` included.
fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~' | b'/' | b':') {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn percent_decode(value: &str) -> Result<String, FfiError> {
    let damaged = || invalid("Der Code ist beschädigt.");
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while let Some(&byte) = bytes.get(index) {
        if byte == b'%' {
            let hex = bytes
                .get(index + 1..index + 3)
                .and_then(|hex| std::str::from_utf8(hex).ok())
                .ok_or_else(damaged)?;
            if !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
                return Err(damaged());
            }
            out.push(u8::from_str_radix(hex, 16).map_err(|_| damaged())?);
            index += 3;
        } else {
            out.push(byte);
            index += 1;
        }
    }
    String::from_utf8(out).map_err(|_| damaged())
}

/// A field name or value from an untrusted code, short and without control
/// characters, for an error message.
fn printable(text: &str) -> String {
    let mut out: String = text.chars().filter(|c| !c.is_control()).take(40).collect();
    if text.chars().count() > 40 {
        out.push('…');
    }
    out
}

fn invalid(message: &str) -> FfiError {
    FfiError::InvalidLink(message.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host_key() -> String {
        keys::generate_ed25519("root@work")
            .expect("generate key")
            .public_openssh
    }

    fn sample() -> AddHostLink {
        AddHostLink {
            name: "work".into(),
            host: "work.staude.internal".into(),
            port: 2222,
            user: "frank".into(),
            socket_path: "/Users/frank/.config/herdr/herdr.sock".into(),
            host_key: host_key(),
        }
    }

    fn message(result: Result<AddHostLink, FfiError>) -> String {
        match result {
            Err(FfiError::InvalidLink(message)) => message,
            other => panic!("expected InvalidLink, got {other:?}"),
        }
    }

    /// The sample link with one raw `field=value` pair replaced or added.
    fn with_field(field: &str, raw: Option<&str>) -> String {
        let link = encode_add_host_link(sample()).expect("encode");
        let (prefix, query) = link.split_at(ADD_HOST_PREFIX.len());
        let mut pairs: Vec<String> = query
            .split('&')
            .filter(|pair| !pair.starts_with(&format!("{field}=")))
            .map(str::to_owned)
            .collect();
        if let Some(raw) = raw {
            pairs.push(format!("{field}={raw}"));
        }
        format!("{prefix}{}", pairs.join("&"))
    }

    #[test]
    fn round_trip_keeps_every_field() -> Result<(), FfiError> {
        let link = sample();
        let text = encode_add_host_link(link.clone())?;
        assert!(text.starts_with("amiscara-agents://add-host?v=1&"));
        assert!(!text.contains(' '));
        assert_eq!(decode_add_host_link(text)?, link);
        Ok(())
    }

    #[test]
    fn plus_in_base64_survives() -> Result<(), FfiError> {
        // Generate until the key's base64 contains a "+", which must not be
        // read as a space.
        let link = (0..200)
            .map(|_| AddHostLink {
                host_key: host_key(),
                ..sample()
            })
            .find(|link| link.host_key.contains('+'))
            .expect("a key with '+'");
        let text = encode_add_host_link(link.clone())?;
        assert!(text.contains("%2B"));
        assert_eq!(decode_add_host_link(text)?.host_key, link.host_key);
        Ok(())
    }

    #[test]
    fn defaults_for_optional_fields() -> Result<(), FfiError> {
        let text = format!(
            "{ADD_HOST_PREFIX}v=1&host=10.0.0.5&user=frank&key={}",
            percent_encode(&host_key())
        );
        let link = decode_add_host_link(format!("  {text}\n"))?;
        assert_eq!(link.name, "10.0.0.5");
        assert_eq!(link.port, 22);
        assert_eq!(link.socket_path, "");
        Ok(())
    }

    #[test]
    fn refuses_other_codes() {
        assert!(message(decode_add_host_link("https://example.com".into())).contains("kein"));
        assert!(
            message(decode_add_host_link("amiscara-agents://add-host".into())).contains("kein")
        );
        // The pre-rename scheme with an otherwise valid link.
        let old_scheme = encode_add_host_link(sample()).expect("encode").replacen(
            "amiscara-agents://",
            "herdr-remote://",
            1,
        );
        assert!(message(decode_add_host_link(old_scheme)).contains("kein"));
        assert!(message(decode_add_host_link(String::new())).contains("kein"));
    }

    #[test]
    fn refuses_newer_and_missing_versions() {
        assert!(message(decode_add_host_link(with_field("v", Some("2")))).contains("neueren"));
        assert!(message(decode_add_host_link(with_field("v", None))).contains("Version"));
        assert!(message(decode_add_host_link(with_field("v", Some("0")))).contains("Version"));
    }

    #[test]
    fn refuses_unknown_and_duplicate_fields() {
        assert!(
            message(decode_add_host_link(with_field("proxy", Some("x")))).contains("unbekannt")
        );
        let text = format!(
            "{}&user=root",
            encode_add_host_link(sample()).expect("encode")
        );
        assert!(message(decode_add_host_link(text)).contains("mehrfach"));
    }

    #[test]
    fn refuses_bad_hosts_users_and_ports() {
        for host in ["-oProxyCommand=x", "a b", "host;rm", "", "%0Ahost"] {
            let result = decode_add_host_link(with_field("host", Some(host)));
            assert!(result.is_err(), "host {host:?} was accepted");
        }
        for user in ["-l", "fr ank", "a%2Fb", ""] {
            let result = decode_add_host_link(with_field("user", Some(user)));
            assert!(result.is_err(), "user {user:?} was accepted");
        }
        for port in ["0", "65536", "+22", "22a", ""] {
            assert!(message(decode_add_host_link(with_field("port", Some(port)))).contains("Port"));
        }
    }

    #[test]
    fn refuses_bad_socket_paths() {
        for path in ["relative/herdr.sock", "/a/../b", "/a%0Ab"] {
            let result = decode_add_host_link(with_field("socket", Some(path)));
            assert!(message(result).contains("Socket"), "path {path:?}");
        }
        let long = format!("/{}", "a".repeat(MAX_SOCKET_LEN));
        assert!(
            message(decode_add_host_link(with_field("socket", Some(&long)))).contains("Socket")
        );
    }

    #[test]
    fn refuses_bad_keys() {
        let key = percent_encode(&host_key());
        let two_lines = format!("{key}%0A{key}");
        assert!(
            message(decode_add_host_link(with_field("key", Some(&two_lines)))).contains("Zeile")
        );
        for raw in [
            "ssh-ed25519%20AAAA",
            "hello",
            "-----BEGIN%20OPENSSH%20PRIVATE%20KEY-----",
        ] {
            let result = decode_add_host_link(with_field("key", Some(raw)));
            assert!(message(result).contains("OpenSSH"), "key {raw:?}");
        }
        assert!(message(decode_add_host_link(with_field("key", None))).contains("Host-Key"));
    }

    #[test]
    fn refuses_damaged_encoding() {
        for raw in ["%G1", "%4", "%FF"] {
            let result = decode_add_host_link(with_field("name", Some(raw)));
            assert!(message(result).contains("beschädigt"), "name {raw:?}");
        }
        let text = format!("{ADD_HOST_PREFIX}v=1&host");
        assert!(message(decode_add_host_link(text)).contains("beschädigt"));
    }

    #[test]
    fn encode_validates_too() {
        let link = AddHostLink {
            host: "bad host".into(),
            ..sample()
        };
        assert!(encode_add_host_link(link).is_err());
    }

    #[test]
    fn fingerprint_of_a_host_key() -> Result<(), FfiError> {
        let key = keys::generate_ed25519("x").expect("generate key");
        assert_eq!(public_key_fingerprint(key.public_openssh)?, key.fingerprint);
        Ok(())
    }
}
