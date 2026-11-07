//! Client keys: generate, load from text, describe. The work is done by
//! `amiscara-ssh`; these wrappers keep the error type of this crate.

use russh::keys::{PrivateKey, PublicKey};

pub use amiscara_ssh::keys::GeneratedKey;

use crate::TransportError;

/// Generates an ed25519 key pair.
pub fn generate_ed25519(comment: &str) -> Result<GeneratedKey, TransportError> {
    Ok(amiscara_ssh::keys::generate_ed25519(comment)?)
}

/// Parses an unencrypted OpenSSH private key.
pub fn parse_private(private_openssh: &str) -> Result<PrivateKey, TransportError> {
    Ok(amiscara_ssh::keys::parse_private(private_openssh)?)
}

/// Parses one OpenSSH public key line (`ssh-ed25519 AAAA... comment`).
/// Anything spanning more than one line is refused.
pub fn parse_public(public_openssh: &str) -> Result<PublicKey, TransportError> {
    Ok(amiscara_ssh::keys::parse_public(public_openssh)?)
}

/// `SHA256:...` of a public key, as `ssh-keygen -lf` prints it.
pub fn fingerprint(key: &PublicKey) -> String {
    amiscara_ssh::keys::fingerprint(key)
}

/// Text forms of an existing key.
pub fn describe(key: &PrivateKey) -> Result<GeneratedKey, TransportError> {
    Ok(amiscara_ssh::keys::describe(key)?)
}
