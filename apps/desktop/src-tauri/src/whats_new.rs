//! "What's New" after an update (#341): the desktop part of
//! `apps/whats-new.json`, built into the app. The webview decides when to
//! show it and in which language; this side picks the versions.

use serde::{Deserialize, Serialize};

/// The notes file the Mac app bundles too; a release stops without notes
/// for its version (`scripts/whats-new.py`).
const FILE: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../whats-new.json"));

/// The notes of one version.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WhatsNewEntry {
    pub version: String,
    pub de: Vec<String>,
    pub en: Vec<String>,
}

/// With `since` (the version seen last) the versions after it up to the
/// installed one, else all up to the installed one; newest first.
#[tauri::command]
pub fn whats_new(since: Option<String>) -> Vec<WhatsNewEntry> {
    let entries = entries(FILE);
    let current = env!("CARGO_PKG_VERSION");
    match since {
        Some(seen) => pending(&entries, &seen, current),
        None => history(&entries, current),
    }
}

/// The desktop entries it can read; none when the file is broken.
fn entries(file: &str) -> Vec<WhatsNewEntry> {
    let Ok(serde_json::Value::Object(mut apps)) = serde_json::from_str(file) else {
        return Vec::new();
    };
    let Some(serde_json::Value::Array(list)) = apps.remove("desktop") else {
        return Vec::new();
    };
    list.into_iter()
        .filter_map(|item| serde_json::from_value(item).ok())
        .collect()
}

/// "1.2.3" as three numbers, which compare in order (0.9.0 < 0.10.0).
fn parse(version: &str) -> Option<[u64; 3]> {
    let mut parts = version.split('.');
    let mut numbers = [0; 3];
    for number in &mut numbers {
        let part = parts.next()?;
        if part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        *number = part.parse().ok()?;
    }
    parts.next().is_none().then_some(numbers)
}

/// The versions after `seen` up to `current`, newest first.
fn pending(entries: &[WhatsNewEntry], seen: &str, current: &str) -> Vec<WhatsNewEntry> {
    let (Some(seen), Some(current)) = (parse(seen), parse(current)) else {
        return Vec::new();
    };
    select(entries, |v| seen < v && v <= current)
}

/// All versions up to `current`, newest first.
fn history(entries: &[WhatsNewEntry], current: &str) -> Vec<WhatsNewEntry> {
    let Some(current) = parse(current) else {
        return Vec::new();
    };
    select(entries, |v| v <= current)
}

fn select(entries: &[WhatsNewEntry], keep: impl Fn([u64; 3]) -> bool) -> Vec<WhatsNewEntry> {
    let mut chosen: Vec<_> = entries
        .iter()
        .filter_map(|entry| parse(&entry.version).map(|v| (v, entry)))
        .filter(|(v, _)| keep(*v))
        .collect();
    chosen.sort_by_key(|(v, _)| std::cmp::Reverse(*v));
    chosen.into_iter().map(|(_, entry)| entry.clone()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(version: &str) -> WhatsNewEntry {
        WhatsNewEntry {
            version: version.into(),
            de: vec![format!("de {version}")],
            en: vec![format!("en {version}")],
        }
    }

    fn versions(entries: &[WhatsNewEntry]) -> Vec<&str> {
        entries.iter().map(|e| e.version.as_str()).collect()
    }

    fn all() -> Vec<WhatsNewEntry> {
        ["0.1.0", "0.3.0", "0.2.0", "0.10.0", "kaputt"]
            .into_iter()
            .map(entry)
            .collect()
    }

    #[test]
    fn versions_compare_as_numbers() {
        assert!(parse("0.9.0") < parse("0.10.0"));
        assert_eq!(parse("1.2.3"), Some([1, 2, 3]));
        assert_eq!(parse("1.2"), None);
        assert_eq!(parse("1.2.3.4"), None);
        assert_eq!(parse("1.2.x"), None);
        assert_eq!(parse("1.2.+3"), None);
    }

    #[test]
    fn pending_shows_the_new_versions_newest_first() {
        let all = all();
        assert_eq!(versions(&pending(&all, "0.2.0", "0.3.0")), ["0.3.0"]);
        assert_eq!(
            versions(&pending(&all, "0.1.0", "0.10.0")),
            ["0.10.0", "0.3.0", "0.2.0"]
        );
        assert!(pending(&all, "0.3.0", "0.3.0").is_empty());
        assert!(pending(&all, "0.3.0", "0.2.0").is_empty(), "downgrade");
        assert!(pending(&all, "?", "0.3.0").is_empty());
        assert!(pending(&all, "0.3.0", "0.4.0").is_empty(), "no notes");
    }

    #[test]
    fn history_lists_everything_up_to_the_installed_version() {
        let all = all();
        assert_eq!(
            versions(&history(&all, "0.3.0")),
            ["0.3.0", "0.2.0", "0.1.0"]
        );
        assert!(history(&all, "x").is_empty());
    }

    #[test]
    fn unreadable_entries_and_files_are_skipped() {
        let file = r#"{"desktop": [{"version": "0.2.0", "de": ["a"]}, {"version": "0.1.0", "de": ["b"], "en": ["c"]}, 7]}"#;
        assert_eq!(versions(&entries(file)), ["0.1.0"]);
        assert!(entries("{").is_empty());
        assert!(entries(r#"{"mac": []}"#).is_empty());
    }

    #[test]
    fn the_built_in_file_has_notes_for_this_version() {
        let current = env!("CARGO_PKG_VERSION");
        let built_in = entries(FILE);
        assert!(
            built_in
                .iter()
                .any(|e| e.version == current && !e.de.is_empty() && !e.en.is_empty()),
            "apps/whats-new.json has no desktop notes for {current}"
        );
        assert_eq!(versions(&whats_new(None))[0], current);
        assert!(whats_new(Some(current.into())).is_empty());
    }
}
