//! Client keys: generate, load from text, describe.

use russh::keys::ssh_key::LineEnding;
use russh::keys::ssh_key::rand_core::UnwrapErr;
use russh::keys::{Algorithm, HashAlg, PrivateKey};
use ssh_key::getrandom::SysRng;

use crate::TransportError;

/// A freshly generated key in OpenSSH text form.
#[derive(Clone)]
pub struct GeneratedKey {
    /// Unencrypted OpenSSH private key. Store it somewhere safe, e.g. the Keychain.
    pub private_openssh: String,
    /// One `authorized_keys` style line: `ssh-ed25519 AAAA... comment`.
    pub public_openssh: String,
    /// `SHA256:...`
    pub fingerprint: String,
}

/// Generates an ed25519 key pair.
pub fn generate_ed25519(comment: &str) -> Result<GeneratedKey, TransportError> {
    let mut rng = UnwrapErr(SysRng);
    let mut key = PrivateKey::random(&mut rng, Algorithm::Ed25519).map_err(key_error)?;
    key.set_comment(comment);
    describe(&key)
}

/// Parses an unencrypted OpenSSH private key.
pub fn parse_private(private_openssh: &str) -> Result<PrivateKey, TransportError> {
    PrivateKey::from_openssh(private_openssh).map_err(key_error)
}

/// Text forms of an existing key.
pub fn describe(key: &PrivateKey) -> Result<GeneratedKey, TransportError> {
    let public = key.public_key();
    Ok(GeneratedKey {
        private_openssh: key
            .to_openssh(LineEnding::LF)
            .map_err(key_error)?
            .to_string(),
        public_openssh: public.to_openssh().map_err(key_error)?,
        fingerprint: public.fingerprint(HashAlg::Sha256).to_string(),
    })
}

fn key_error(err: impl std::fmt::Display) -> TransportError {
    TransportError::Key(err.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_key_round_trips() -> Result<(), TransportError> {
        let generated = generate_ed25519("herdr-remote-test")?;
        assert!(generated.public_openssh.starts_with("ssh-ed25519 "));
        assert!(generated.public_openssh.ends_with(" herdr-remote-test"));
        assert!(generated.fingerprint.starts_with("SHA256:"));
        let parsed = parse_private(&generated.private_openssh)?;
        assert_eq!(describe(&parsed)?.fingerprint, generated.fingerprint);
        Ok(())
    }
}
