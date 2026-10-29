//! Chains (#300): when an agent finishes or starts waiting, a saved prompt
//! goes to another agent or to the same one. A chain lives on the host as
//! metadata of the pane that triggers it, so every connected device sees
//! it and it ends with the pane.
//!
//! Tokens under the source [`CHAINS_SOURCE`], per chain `<id>` (six
//! characters `[0-9a-f]`):
//!
//! - `chain_<id>` = `<d|w><o|r><a|f><s|n>|<target pane id>`: trigger done
//!   or waiting, once or repeating, active or failed, and whether a space
//!   joins the two text parts.
//! - `chain_<id>_0`, `chain_<id>_1`: the prompt in parts of at most 80
//!   characters. herdr cuts every value to 80 characters and trims spaces
//!   at both ends, so the text never splits next to a space; a space at the
//!   split is left out and noted in the first token instead.
//!
//! A value of `null` removes a token, see [`clear_tokens`].

use std::collections::BTreeMap;

use herdr_proto::{AgentStatus, PaneInfo};

use crate::SessionState;

/// The metadata source chains are stored under.
pub const CHAINS_SOURCE: &str = "amiscara-agents-chains";
/// At most this many chains per pane: herdr keeps 32 tokens per pane, and
/// open and editor requests need theirs too.
pub const MAX_CHAINS_PER_PANE: usize = 3;
/// The longest prompt in characters (two tokens of 80).
pub const MAX_CHAIN_TEXT: usize = 160;
const PART: usize = 80;
const PREFIX: &str = "chain_";
const ID_LEN: usize = 6;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ChainTrigger {
    /// The agent finished a turn.
    Done,
    /// The agent waits for an answer.
    Blocked,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chain {
    pub id: String,
    pub trigger: ChainTrigger,
    /// Runs on every matching change; otherwise removed once it sent.
    pub repeat: bool,
    /// The target was gone or refused the prompt; the chain stays to show
    /// that and never runs again.
    pub failed: bool,
    pub target_pane_id: String,
    pub text: String,
}

/// Whether `id` has the shape of a chain id.
pub fn is_chain_id(id: &str) -> bool {
    id.len() == ID_LEN && id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// A fresh id that none of `taken` has.
pub fn new_chain_id(taken: &[Chain]) -> String {
    use std::hash::BuildHasher;
    let state = std::collections::hash_map::RandomState::new();
    (0u64..)
        .map(|n| format!("{:06x}", state.hash_one(n) & 0xff_ffff))
        .find(|id| taken.iter().all(|chain| &chain.id != id))
        .unwrap_or_default()
}

/// The prompt as a chain keeps it: whitespace runs (line breaks too) become
/// one space, the ends trimmed. `None` when it is empty, longer than
/// [`MAX_CHAIN_TEXT`] or holds other control characters.
pub fn normalize_text(text: &str) -> Option<String> {
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    (!text.is_empty()
        && text.chars().count() <= MAX_CHAIN_TEXT
        && !text.chars().any(char::is_control))
    .then_some(text)
}

/// The chains of a pane, in id order; tokens that do not read as one are
/// skipped.
pub fn chains_of(pane: &PaneInfo) -> Vec<Chain> {
    pane.tokens
        .iter()
        .filter_map(|(key, value)| {
            let id = key.strip_prefix(PREFIX).filter(|id| is_chain_id(id))?;
            let (flags, target) = value.split_once('|')?;
            let flags = flags.as_bytes();
            if flags.len() != 4 || target.is_empty() {
                return None;
            }
            let trigger = match flags[0] {
                b'd' => ChainTrigger::Done,
                b'w' => ChainTrigger::Blocked,
                _ => return None,
            };
            let repeat = flag(flags[1], b'r', b'o')?;
            let failed = flag(flags[2], b'f', b'a')?;
            let joined = flag(flags[3], b's', b'n')?;
            let first = pane.tokens.get(&format!("{key}_0"))?;
            let text = match pane.tokens.get(&format!("{key}_1")) {
                Some(second) if joined => format!("{first} {second}"),
                Some(second) => format!("{first}{second}"),
                None => first.clone(),
            };
            let text = normalize_text(&text)?;
            Some(Chain {
                id: id.to_owned(),
                trigger,
                repeat,
                failed,
                target_pane_id: target.to_owned(),
                text,
            })
        })
        .collect()
}

fn flag(byte: u8, yes: u8, no: u8) -> Option<bool> {
    match byte {
        b if b == yes => Some(true),
        b if b == no => Some(false),
        _ => None,
    }
}

/// The tokens that write `chain`; an unused second text part is removed.
/// Expects text from [`normalize_text`].
pub fn chain_tokens(chain: &Chain) -> BTreeMap<String, Option<String>> {
    let chars: Vec<char> = chain.text.chars().collect();
    let (first, second, joined) = if chars.len() <= PART {
        (chain.text.clone(), None, false)
    } else {
        // Single spaces only: one step back leaves no space before the split.
        let mut split = PART;
        if chars[split - 1] == ' ' {
            split -= 1;
        }
        let joined = chars[split] == ' ';
        let rest = if joined { split + 1 } else { split };
        (
            chars[..split].iter().collect(),
            Some(chars[rest..].iter().collect::<String>()),
            joined,
        )
    };
    let key = format!("{PREFIX}{}", chain.id);
    let flags = [
        if chain.trigger == ChainTrigger::Done {
            'd'
        } else {
            'w'
        },
        if chain.repeat { 'r' } else { 'o' },
        if chain.failed { 'f' } else { 'a' },
        if joined { 's' } else { 'n' },
    ];
    let flags: String = flags.iter().collect();
    BTreeMap::from([
        (
            key.clone(),
            Some(format!("{flags}|{}", chain.target_pane_id)),
        ),
        (format!("{key}_0"), Some(first)),
        (format!("{key}_1"), second),
    ])
}

/// The tokens that remove the chain `id`.
pub fn clear_tokens(id: &str) -> BTreeMap<String, Option<String>> {
    let key = format!("{PREFIX}{id}");
    BTreeMap::from([
        (format!("{key}_0"), None),
        (format!("{key}_1"), None),
        (key, None),
    ])
}

/// The metadata source a device claims one run of chain `id` under: one
/// per chain, so herdr's `seq` check orders the claims of that chain only.
pub fn claim_source(id: &str) -> String {
    format!("{CHAINS_SOURCE}-{id}")
}

/// The token of that claim; its value names the device and the change.
pub fn claim_token(id: &str) -> String {
    format!("{PREFIX}{id}_by")
}

/// Agent panes whose state changed from `before` to `now` in a way chains
/// react to: newly `blocked`, or from `working` to `done` or `idle` (herdr
/// sets a pane someone looks at straight to `idle`). Panes unknown before
/// stay quiet, as after a reconnect.
pub fn fired(before: &SessionState, now: &SessionState) -> Vec<(String, ChainTrigger)> {
    now.panes
        .iter()
        .filter(|pane| pane.agent.is_some())
        .filter_map(|pane| {
            let old = before.pane(&pane.pane_id)?.agent_status;
            let trigger = match pane.agent_status {
                AgentStatus::Blocked if old != AgentStatus::Blocked => ChainTrigger::Blocked,
                AgentStatus::Done | AgentStatus::Idle if old == AgentStatus::Working => {
                    ChainTrigger::Done
                }
                _ => return None,
            };
            Some((pane.pane_id.clone(), trigger))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pane(tokens: &BTreeMap<String, Option<String>>) -> PaneInfo {
        let mut pane: PaneInfo = serde_json::from_value(serde_json::json!({
            "pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "agent": "claude"
        }))
        .expect("pane");
        for (key, value) in tokens {
            if let Some(value) = value {
                pane.tokens.insert(key.clone(), value.clone());
            }
        }
        pane
    }

    fn chain(text: &str) -> Chain {
        Chain {
            id: "0a1b2c".into(),
            trigger: ChainTrigger::Done,
            repeat: false,
            failed: false,
            target_pane_id: "w1:p2".into(),
            text: normalize_text(text).expect("valid text"),
        }
    }

    /// What herdr keeps of a value: 80 characters, trimmed.
    fn stored(tokens: &BTreeMap<String, Option<String>>) -> BTreeMap<String, Option<String>> {
        tokens
            .iter()
            .map(|(key, value)| {
                let value = value
                    .as_ref()
                    .map(|v| v.chars().take(80).collect::<String>().trim().to_owned());
                (key.clone(), value)
            })
            .collect()
    }

    fn round_trip(chain: &Chain) -> Vec<Chain> {
        chains_of(&pane(&stored(&chain_tokens(chain))))
    }

    #[test]
    fn a_chain_reads_back() {
        let mut original = chain("/issue-approve 300");
        assert_eq!(round_trip(&original), std::slice::from_ref(&original));
        original.trigger = ChainTrigger::Blocked;
        original.repeat = true;
        original.failed = true;
        assert_eq!(round_trip(&original), std::slice::from_ref(&original));
        assert_eq!(
            chain_tokens(&original)["chain_0a1b2c"].as_deref(),
            Some("wrfn|w1:p2")
        );
        assert_eq!(chain_tokens(&original)["chain_0a1b2c_1"], None);
    }

    #[test]
    fn umlauts_and_full_length_read_back() {
        let umlauts = chain(&"ä".repeat(MAX_CHAIN_TEXT));
        assert_eq!(round_trip(&umlauts), std::slice::from_ref(&umlauts));
        let tokens = chain_tokens(&umlauts);
        assert_eq!(
            tokens["chain_0a1b2c_0"]
                .as_deref()
                .map(|t| t.chars().count()),
            Some(80)
        );
        let words = chain(&"wort ".repeat(32));
        assert_eq!(words.text.chars().count(), 159);
        assert_eq!(round_trip(&words), std::slice::from_ref(&words));
    }

    #[test]
    fn a_space_at_the_split_survives_the_trim() {
        for at in 76..=82 {
            let text = format!("{} {}", "a".repeat(at), "b".repeat(150 - at));
            let original = chain(&text);
            assert_eq!(
                round_trip(&original),
                std::slice::from_ref(&original),
                "space after {at}"
            );
        }
        let single = chain(&"a b ".repeat(40));
        assert_eq!(single.text.chars().count(), 159);
        assert_eq!(round_trip(&single), std::slice::from_ref(&single));
    }

    #[test]
    fn text_is_normalized_and_bounded() {
        assert_eq!(
            normalize_text("  weiter\n  bitte\t ").as_deref(),
            Some("weiter bitte")
        );
        assert_eq!(normalize_text(" \n "), None);
        assert_eq!(normalize_text(&"x".repeat(MAX_CHAIN_TEXT + 1)), None);
        assert!(normalize_text(&"x".repeat(MAX_CHAIN_TEXT)).is_some());
        assert_eq!(normalize_text("a\u{7}b"), None);
    }

    #[test]
    fn broken_tokens_are_skipped() {
        let good = chain("ok");
        let mut tokens = chain_tokens(&good);
        for (key, value) in [
            ("chain_zzzzzz", "dona|w1:p2"),
            ("chain_123456", "xona|w1:p2"),
            ("chain_234567", "don|w1:p2"),
            ("chain_345678", "dona|"),
            ("chain_456789", "dona|w1:p2"),
            ("chain_56789a", "dona"),
        ] {
            tokens.insert(key.into(), Some(value.into()));
            tokens.insert(format!("{key}_0"), Some("text".into()));
        }
        // No text part at all.
        tokens.remove("chain_456789_0");
        tokens.insert("chain_0a1b2c_by".into(), Some("device:3".into()));
        assert_eq!(chains_of(&pane(&tokens)), [good]);
    }

    #[test]
    fn clearing_removes_every_token() {
        let tokens = clear_tokens("0a1b2c");
        assert_eq!(tokens.len(), 3);
        assert!(tokens.values().all(Option::is_none));
        assert!(
            chain_tokens(&chain("x"))
                .keys()
                .all(|key| tokens.contains_key(key))
        );
    }

    #[test]
    fn ids_are_fresh_hex() {
        let taken = vec![chain("x")];
        let id = new_chain_id(&taken);
        assert!(is_chain_id(&id), "{id}");
        assert_ne!(id, "0a1b2c");
        assert!(!is_chain_id("0A1B2C") && !is_chain_id("0a1b2") && !is_chain_id("0a1b2c3"));
    }

    fn state(statuses: &[(&str, &str)]) -> SessionState {
        let panes: Vec<_> = statuses
            .iter()
            .map(|(id, status)| {
                serde_json::json!({
                    "pane_id": id, "workspace_id": "w1", "tab_id": "w1:t1",
                    "agent": "claude", "agent_status": status
                })
            })
            .collect();
        SessionState::from_snapshot(
            serde_json::from_value(serde_json::json!({
                "version": "0.9.5", "protocol": 22,
                "workspaces": [], "tabs": [], "panes": panes
            }))
            .expect("snapshot"),
        )
    }

    #[test]
    fn changes_that_fire() {
        let before = state(&[
            ("p1", "working"),
            ("p2", "working"),
            ("p3", "idle"),
            ("p4", "blocked"),
            ("p5", "working"),
        ]);
        let now = state(&[
            ("p1", "done"),
            ("p2", "idle"),
            ("p3", "done"),
            ("p4", "blocked"),
            ("p5", "blocked"),
            ("p6", "done"),
        ]);
        assert_eq!(
            fired(&before, &now),
            [
                ("p1".to_owned(), ChainTrigger::Done),
                ("p2".to_owned(), ChainTrigger::Done),
                ("p5".to_owned(), ChainTrigger::Blocked),
            ]
        );
        assert!(fired(&now, &now).is_empty());
    }
}
