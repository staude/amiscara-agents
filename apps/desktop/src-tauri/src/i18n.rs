//! The few texts the Rust side shows itself (tray, notifications, defaults),
//! in German or English (#207). The webview decides the language and tells
//! it with `set_language`; until then the environment's locale counts,
//! English when it is neither.

use std::sync::atomic::{AtomicBool, Ordering};

static GERMAN: AtomicBool = AtomicBool::new(false);

/// Picks the language from `LC_ALL`, `LC_MESSAGES` or `LANG` (Linux); on
/// Windows the webview sets it right after start.
pub fn init_from_env() {
    let tag = ["LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .filter_map(|name| std::env::var(name).ok())
        .find(|value| !value.is_empty());
    set(tag.as_deref().unwrap_or(""));
}

/// `de`, `de-DE` and the like choose German, anything else English.
pub fn set(tag: &str) {
    GERMAN.store(
        tag.to_ascii_lowercase().starts_with("de"),
        Ordering::Relaxed,
    );
}

/// German or English text, whichever is in use.
pub fn tr(german: &'static str, english: &'static str) -> &'static str {
    if GERMAN.load(Ordering::Relaxed) {
        german
    } else {
        english
    }
}

/// Title of a notification: "claude wartet" / "claude is waiting".
pub fn agent_title(agent: &str, blocked: bool) -> String {
    match (GERMAN.load(Ordering::Relaxed), blocked) {
        (true, true) => format!("{agent} wartet"),
        (true, false) => format!("{agent} ist fertig"),
        (false, true) => format!("{agent} is waiting"),
        (false, false) => format!("{agent} is done"),
    }
}

/// Tooltip of the tray icon with the number of waiting agents.
pub fn tray_tooltip(waiting: usize) -> String {
    let german = GERMAN.load(Ordering::Relaxed);
    match (waiting, german) {
        (0, _) => "Amiscara Agents".to_owned(),
        (1, true) => "Amiscara Agents: 1 Agent wartet".to_owned(),
        (1, false) => "Amiscara Agents: 1 agent waiting".to_owned(),
        (n, true) => format!("Amiscara Agents: {n} Agents warten"),
        (n, false) => format!("Amiscara Agents: {n} agents waiting"),
    }
}

/// The quick replies a new list starts with, as in the Apple apps.
pub fn default_quick_replies() -> Vec<String> {
    [
        tr("weiter", "continue"),
        "/compact",
        tr("Bitte committen", "Please commit"),
        tr("Commit und PR erstellen", "Commit and open a PR"),
    ]
    .map(str::to_owned)
    .to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    // One test, since the language is global.
    #[test]
    fn german_and_english() {
        set("de-DE");
        assert_eq!(agent_title("claude", true), "claude wartet");
        assert_eq!(tray_tooltip(2), "Amiscara Agents: 2 Agents warten");
        assert_eq!(default_quick_replies()[0], "weiter");
        set("en-US");
        assert_eq!(agent_title("claude", false), "claude is done");
        assert_eq!(tray_tooltip(1), "Amiscara Agents: 1 agent waiting");
        set("fr");
        assert_eq!(tr("Beenden", "Quit"), "Quit");
    }
}
