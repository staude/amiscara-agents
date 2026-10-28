//! Secrets for the host (#291): environment variables such as tokens that
//! the apps write as files into [`ENV_DIR`], one file per variable, so that
//! new shells in herdr panes export them and running agents read them with
//! `amiscara-env <NAME>`. Values never go through pane input; errors and
//! logs never contain them.

use crate::session::SessionError;

/// Where secrets land, relative to the login's home directory.
pub const ENV_DIR: &str = ".amiscara-agents/env";

/// Longest variable name the apps accept.
const MAX_NAME_LEN: usize = 128;
/// Largest value the apps send.
const MAX_VALUE_LEN: usize = 16 * 1024;

/// Whether `name` can be an environment variable: `[A-Z_][A-Z0-9_]*`, up to
/// 128 characters.
pub fn is_valid_env_name(name: &str) -> bool {
    let mut chars = name.chars();
    name.len() <= MAX_NAME_LEN
        && chars
            .next()
            .is_some_and(|ch| ch.is_ascii_uppercase() || ch == '_')
        && chars.all(|ch| ch.is_ascii_uppercase() || ch.is_ascii_digit() || ch == '_')
}

/// Refuses an unsuitable variable name.
pub(crate) fn check_name(name: &str) -> Result<(), SessionError> {
    if is_valid_env_name(name) {
        Ok(())
    } else {
        Err(SessionError::Upload("invalid variable name".into()))
    }
}

/// Refuses a value no shell can hold; the message never repeats it.
pub(crate) fn check_value(value: &str) -> Result<(), SessionError> {
    if value.is_empty() {
        Err(SessionError::Upload("empty value".into()))
    } else if value.contains('\0') {
        Err(SessionError::Upload(
            "value contains a NUL character".into(),
        ))
    } else if value.len() > MAX_VALUE_LEN {
        Err(SessionError::Upload("value longer than 16 KiB".into()))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{check_value, is_valid_env_name};

    #[test]
    fn names_are_shell_variables() {
        for name in ["NB_TOKEN", "_X", "A1", "_"] {
            assert!(is_valid_env_name(name), "{name}");
        }
        for name in ["", "nb", "1A", "A-B", "NB TOKEN", "Ä", "nb_TOKEN"] {
            assert!(!is_valid_env_name(name), "{name:?}");
        }
        assert!(is_valid_env_name(&"A".repeat(128)));
        assert!(!is_valid_env_name(&"A".repeat(129)));
    }

    #[test]
    fn values_are_checked_without_echoing_them() {
        assert!(check_value("s3cr3t").is_ok());
        assert!(check_value(&"x".repeat(16 * 1024)).is_ok());
        for value in [String::new(), "s3cr3t\0".to_owned(), "s3cr3t".repeat(3000)] {
            let message = check_value(&value).expect_err("refused").to_string();
            assert!(!message.contains("s3cr3t"), "{message}");
        }
    }
}
