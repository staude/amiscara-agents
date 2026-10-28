//! What happened on a host on one day (#301): Claude Code prompts and
//! finished turns, and the commits of every space. herdr keeps no history
//! of agent states, so the turns come from the Claude Code session files
//! (see [`crate::claude`]); the commits and the list of session files from
//! a small script in a short-lived tab like [`crate::diff::diff_script`].
//! Nothing is stored.

use crate::claude::{Entry, EntryKind};

/// Starts a repository's commits in the script's output: the mark, a
/// space, the folder it was found in.
pub const REPO_MARK: &str = "#amiscara-repo";
/// Starts the Claude Code session files: `<bytes> <path below home>`,
/// newest first.
pub const CLAUDE_MARK: &str = "#amiscara-claude";
/// Longest text of an item.
const TEXT_LEN: usize = 160;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DailyItemKind {
    /// The user gave a Claude agent a task.
    Prompt,
    /// The agent ended its turn with an answer.
    Done,
    Commit,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DailyItem {
    pub kind: DailyItemKind,
    /// Unix milliseconds.
    pub time_ms: u64,
    /// The space it happened in, else the folder's name.
    pub place: String,
    /// First line of the prompt, the answer or the commit message.
    pub text: String,
    /// A commit's author.
    pub author: Option<String>,
}

/// One day of a host, oldest first; `truncated` when not every session
/// file was read to the day's start.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DailyLog {
    pub items: Vec<DailyItem>,
    pub truncated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Commit {
    pub hash: String,
    pub author: String,
    pub time_secs: u64,
    pub subject: String,
    /// The folder its repository was found in.
    pub repo: String,
}

/// A Claude Code session file changed during or after the day.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionFile {
    /// Below the home directory.
    pub path: String,
    pub size: u64,
}

/// A POSIX shell script that writes the commits of all local branches in
/// the repositories of `dirs` between the Unix seconds `since` and `until`,
/// and the Claude Code session files changed in the last `minutes`, to the
/// file `out` next to the script; renamed to `out` + `.done` when complete,
/// errors to `out` + `.err`. Read only, like the diff script. A repository
/// with several worktrees is listed once.
pub fn day_script(out: &str, since: u64, until: u64, minutes: u64, dirs: &[String]) -> String {
    let out = out.rsplit('/').next().unwrap_or(out);
    let dirs: Vec<String> = dirs.iter().map(|dir| quote(dir)).collect();
    let dirs = dirs.join(" ");
    // `ls -t` puts the newest first; `find` runs it only when it found
    // something. `-mmin` exists in GNU and BSD find alike.
    format!(
        r#"#!/bin/sh
# Amiscara Agents: commits and Claude Code sessions of a day for the app (read only).
export GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat LC_ALL=C
out="$(dirname "$0")/{out}"
(
  seen='|'
  for d in {dirs}; do
    cd "$d" 2>/dev/null || continue
    common=$(git rev-parse --git-common-dir 2>/dev/null) || continue
    common=$(cd "$common" && pwd -P) || continue
    case "$seen" in *"|$common|"*) continue ;; esac
    seen="$seen$common|"
    printf '%s %s\n' '{repo}' "$d"
    git log --branches --since=@{since} --until=@{until} --format='%H%x1f%an%x1f%ct%x1f%s'
  done
  echo '{claude}'
  if cd "$HOME/.claude/projects" 2>/dev/null; then
    find . -mindepth 2 -maxdepth 2 -name '*.jsonl' -mmin -{minutes} -exec ls -t {{}} + | while IFS= read -r f; do
      printf '%s %s\n' "$(wc -c < "$f" | tr -d ' ')" ".claude/projects/${{f#./}}"
    done
  fi
) >"$out" 2>"$out.err"
mv "$out" "$out.done"
"#,
        repo = REPO_MARK,
        claude = CLAUDE_MARK,
    )
}

/// `text` in single quotes for the shell.
fn quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// Reads the script's output into commits, each hash once, and session
/// files in the script's order.
pub fn parse_script(output: &str) -> (Vec<Commit>, Vec<SessionFile>) {
    let mut commits: Vec<Commit> = Vec::new();
    let mut files = Vec::new();
    let mut repo = String::new();
    let mut in_claude = false;
    for line in output.lines() {
        if line == CLAUDE_MARK {
            in_claude = true;
        } else if in_claude {
            if let Some((size, path)) = line.split_once(' ')
                && let Ok(size) = size.parse()
                && !path.is_empty()
            {
                files.push(SessionFile {
                    path: path.to_owned(),
                    size,
                });
            }
        } else if let Some(top) = line
            .strip_prefix(REPO_MARK)
            .and_then(|rest| rest.strip_prefix(' '))
        {
            top.clone_into(&mut repo);
        } else {
            let mut fields = line.splitn(4, '\u{1f}');
            let (Some(hash), Some(author), Some(time), Some(subject)) =
                (fields.next(), fields.next(), fields.next(), fields.next())
            else {
                continue;
            };
            let Ok(time_secs) = time.parse() else {
                continue;
            };
            if commits.iter().any(|commit| commit.hash == hash) {
                continue;
            }
            commits.push(Commit {
                hash: hash.to_owned(),
                author: author.to_owned(),
                time_secs,
                subject: subject.to_owned(),
                repo: repo.clone(),
            });
        }
    }
    (commits, files)
}

/// Unix milliseconds of a Claude Code timestamp, UTC as
/// `2026-10-28T09:15:02.123Z`, with or without the fraction.
pub fn parse_utc_ms(text: &str) -> Option<u64> {
    let (date, time) = text.strip_suffix('Z')?.split_once('T')?;
    let number = |part: &str| -> Option<u64> {
        if part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        part.parse().ok()
    };
    let mut date = date.splitn(3, '-');
    let year = number(date.next()?)?;
    let month = number(date.next()?)?;
    let day = number(date.next()?)?;
    let (clock, fraction) = time.split_once('.').unwrap_or((time, ""));
    let mut clock = clock.splitn(3, ':');
    let hour = number(clock.next()?)?;
    let minute = number(clock.next()?)?;
    let second = number(clock.next()?)?;
    let millis = if fraction.is_empty() {
        0
    } else {
        let digits: String = fraction.chars().chain("00".chars()).take(3).collect();
        number(fraction)?;
        number(&digits)?
    };
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }
    let days = days_from_civil(year, month, day)?;
    Some(((days * 24 + hour) * 60 + minute) * 60_000 + second * 1000 + millis)
}

/// Days since 1970-01-01 of a date in the proleptic Gregorian calendar.
fn days_from_civil(year: u64, month: u64, day: u64) -> Option<u64> {
    let year = if month <= 2 {
        year.checked_sub(1)?
    } else {
        year
    };
    let era = year / 400;
    let year_of_era = year - era * 400;
    let month_index = (month + 9) % 12;
    let day_of_year = (153 * month_index + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    (era * 146_097 + day_of_era).checked_sub(719_468)
}

/// The prompts and finished turns of a conversation between the Unix
/// milliseconds `since` (inclusive) and `until` (exclusive), without
/// place. A turn starts with a prompt and ends before the next; it is done
/// at its last entry when that is Claude's text, not a tool call (an agent
/// waiting at an approval looks like one still working). Lines Claude Code
/// puts in as the user's are no prompts. Entries without a time count as
/// written with the one before. Entries before the first
/// prompt end a turn that began earlier.
pub fn turns(entries: &[Entry], since_ms: u64, until_ms: u64) -> Vec<DailyItem> {
    let in_day = |time: u64| since_ms <= time && time < until_ms;
    let item = |kind, time_ms, text: &str| DailyItem {
        kind,
        time_ms,
        place: String::new(),
        text: first_line(text),
        author: None,
    };
    let mut items = Vec::new();
    let mut time = None;
    // The last entry of the current turn and when it was written.
    let mut last: Option<(&Entry, Option<u64>)> = None;
    let finish = |last: Option<(&Entry, Option<u64>)>, items: &mut Vec<DailyItem>| {
        if let Some((entry, Some(at))) = last
            && entry.kind == EntryKind::Assistant
            && in_day(at)
        {
            items.push(item(DailyItemKind::Done, at, &entry.text));
        }
    };
    for entry in entries {
        if let Some(at) = entry.timestamp.as_deref().and_then(parse_utc_ms) {
            time = Some(at);
        }
        if entry.kind == EntryKind::User {
            match user_line(&entry.text) {
                UserLine::Prompt(text) => {
                    finish(last, &mut items);
                    if let Some(at) = time.filter(|at| in_day(*at)) {
                        items.push(item(DailyItemKind::Prompt, at, &text));
                    }
                }
                // Ends the turn without an answer.
                UserLine::Interrupted => {}
                // Part of the turn, like a tool result.
                UserLine::Inserted => continue,
            }
        }
        last = Some((entry, time));
    }
    finish(last, &mut items);
    items
}

enum UserLine {
    /// Typed by the user; a slash command as `/name args`.
    Prompt(String),
    Interrupted,
    /// Put in by Claude Code: task notifications, a command's output, the
    /// summary that continues a compacted conversation.
    Inserted,
}

/// What a user line of a conversation is.
fn user_line(text: &str) -> UserLine {
    let text = text.trim_start();
    if text.starts_with("[Request interrupted") {
        return UserLine::Interrupted;
    }
    if text.starts_with("This session is being continued from a previous conversation") {
        return UserLine::Inserted;
    }
    if !text.starts_with('<') {
        return UserLine::Prompt(text.to_owned());
    }
    match tag(text, "command-name") {
        Some(name) => {
            let args = tag(text, "command-args").unwrap_or_default();
            UserLine::Prompt(format!("{name} {args}").trim_end().to_owned())
        }
        None => UserLine::Inserted,
    }
}

/// The trimmed text inside `<name>…</name>`.
fn tag<'a>(text: &'a str, name: &str) -> Option<&'a str> {
    let start = text.find(&format!("<{name}>"))? + name.len() + 2;
    let end = start + text[start..].find(&format!("</{name}>"))?;
    Some(text[start..end].trim())
}

/// The first non-empty line of `text`, cut to [`TEXT_LEN`] characters.
fn first_line(text: &str) -> String {
    let line = text
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or_default();
    let mut short: String = line.chars().take(TEXT_LEN).collect();
    if short.len() < line.len() {
        short.push('…');
    }
    short
}

/// Where `path` lies: the name of the folder in `folders` (folder, name)
/// that is its longest prefix at a `/`, else the last part of `path`.
pub fn place_for(path: &str, folders: &[(String, String)]) -> String {
    folders
        .iter()
        .filter(|(folder, _)| within(path, folder))
        .max_by_key(|(folder, _)| folder.trim_end_matches('/').len())
        .map(|(_, name)| name.clone())
        .unwrap_or_else(|| last_part(path))
}

fn within(path: &str, folder: &str) -> bool {
    let folder = folder.trim_end_matches('/');
    path.strip_prefix(folder)
        .is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
}

/// The last part of a path, the path itself when it has none.
pub fn last_part(path: &str) -> String {
    path.trim_end_matches('/')
        .rsplit('/')
        .next()
        .filter(|part| !part.is_empty())
        .unwrap_or(path)
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(kind: EntryKind, text: &str, timestamp: Option<&str>) -> Entry {
        Entry {
            kind,
            text: text.to_owned(),
            timestamp: timestamp.map(str::to_owned),
        }
    }

    #[test]
    fn script_quotes_directories() {
        let script = day_script(
            ".amiscara-agents/uploads/day-1.txt",
            100,
            200,
            5,
            &["/home/a/it's".to_owned(), "/home/a/b c".to_owned()],
        );
        assert!(script.contains(r"for d in '/home/a/it'\''s' '/home/a/b c'; do"));
        assert!(script.contains(r#"out="$(dirname "$0")/day-1.txt""#));
        assert!(script.contains("--since=@100 --until=@200"));
        assert!(script.contains("-mmin -5 -exec ls -t {} +"));
        assert!(script.contains(r#"".claude/projects/${f#./}""#));
    }

    #[test]
    fn reads_commits_of_two_repos_once() {
        let output = format!(
            "{REPO_MARK} /home/a/shop\n\
             aaa\u{1f}Frank\u{1f}1000\u{1f}feat: cart #1\n\
             bbb\u{1f}Frank\u{1f}1100\u{1f}fix: tax\u{1f}rate\n\
             {REPO_MARK} /home/a/kino\n\
             ccc\u{1f}Eva\u{1f}1200\u{1f}docs: readme\n\
             aaa\u{1f}Frank\u{1f}1000\u{1f}feat: cart #1\n\
             {CLAUDE_MARK}\n\
             2048 .claude/projects/-home-a-shop/s1.jsonl\n\
             17 .claude/projects/-home-a-kino/s2.jsonl\n"
        );
        let (commits, files) = parse_script(&output);
        let got: Vec<_> = commits
            .iter()
            .map(|c| {
                (
                    c.hash.as_str(),
                    c.repo.as_str(),
                    c.time_secs,
                    c.subject.as_str(),
                )
            })
            .collect();
        assert_eq!(
            got,
            [
                ("aaa", "/home/a/shop", 1000, "feat: cart #1"),
                ("bbb", "/home/a/shop", 1100, "fix: tax\u{1f}rate"),
                ("ccc", "/home/a/kino", 1200, "docs: readme"),
            ]
        );
        assert_eq!(commits[2].author, "Eva");
        assert_eq!(
            files,
            [
                SessionFile {
                    path: ".claude/projects/-home-a-shop/s1.jsonl".into(),
                    size: 2048
                },
                SessionFile {
                    path: ".claude/projects/-home-a-kino/s2.jsonl".into(),
                    size: 17
                },
            ]
        );
    }

    #[test]
    fn parses_claude_timestamps() {
        assert_eq!(parse_utc_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            parse_utc_ms("2026-10-28T09:15:02.123Z"),
            Some(1_793_178_902_123)
        );
        assert_eq!(
            parse_utc_ms("2026-10-28T09:15:02Z"),
            Some(1_793_178_902_000)
        );
        assert_eq!(
            parse_utc_ms("2024-02-29T12:00:00.5Z"),
            Some(1_709_208_000_500)
        );
        for bad in [
            "",
            "t1",
            "2026-10-28 09:15:02Z",
            "2026-13-01T00:00:00Z",
            "2026-10-28T09:15Z",
        ] {
            assert_eq!(parse_utc_ms(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn turns_within_the_day() {
        let at = Some::<&str>;
        let entries = [
            // The end of a turn that began the day before.
            entry(
                EntryKind::Assistant,
                "Alles grün.",
                at("2026-10-28T00:00:05Z"),
            ),
            // A turn before `since`.
            entry(EntryKind::User, "Früh", at("2026-10-27T23:00:00Z")),
            entry(EntryKind::Assistant, "Ok", at("2026-10-27T23:30:00Z")),
            // Done, the answer's time taken from the tool call before it.
            entry(
                EntryKind::User,
                "Bitte testen\nmit Details",
                at("2026-10-28T08:00:00Z"),
            ),
            entry(
                EntryKind::Tool,
                "Bash: cargo test",
                at("2026-10-28T08:01:00Z"),
            ),
            entry(EntryKind::Assistant, "Tests laufen.", None),
            // Ends with a tool call: no "done".
            entry(EntryKind::User, "Weiter", at("2026-10-28T09:00:00Z")),
            entry(EntryKind::Tool, "Edit: a.rs", at("2026-10-28T09:00:30Z")),
            // Inserted by Claude Code: neither a prompt nor the turn's end.
            entry(
                EntryKind::User,
                "<task-notification>\n<task-id>x</task-id>",
                at("2026-10-28T09:01:00Z"),
            ),
            // A slash command is a prompt; an interruption ends the turn.
            entry(
                EntryKind::User,
                "<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>301</command-args>",
                at("2026-10-28T10:00:00Z"),
            ),
            entry(
                EntryKind::Assistant,
                "Schaue ich an.",
                at("2026-10-28T10:00:10Z"),
            ),
            entry(
                EntryKind::User,
                "[Request interrupted by user]",
                at("2026-10-28T10:00:20Z"),
            ),
            // At `until`: outside.
            entry(EntryKind::User, "Morgen", at("2026-10-29T00:00:00Z")),
            entry(EntryKind::Assistant, "Gut", at("2026-10-29T00:00:10Z")),
        ];
        let since = parse_utc_ms("2026-10-28T00:00:00Z").expect("since");
        let until = parse_utc_ms("2026-10-29T00:00:00Z").expect("until");
        let got: Vec<_> = turns(&entries, since, until)
            .into_iter()
            .map(|item| (item.kind, item.time_ms - since, item.text))
            .collect();
        assert_eq!(
            got,
            [
                (DailyItemKind::Done, 5_000, "Alles grün.".to_owned()),
                (
                    DailyItemKind::Prompt,
                    8 * 3_600_000,
                    "Bitte testen".to_owned()
                ),
                (
                    DailyItemKind::Done,
                    8 * 3_600_000 + 60_000,
                    "Tests laufen.".to_owned()
                ),
                (DailyItemKind::Prompt, 9 * 3_600_000, "Weiter".to_owned()),
                (
                    DailyItemKind::Prompt,
                    10 * 3_600_000,
                    "/review 301".to_owned()
                ),
            ]
        );
    }

    #[test]
    fn long_texts_are_cut() {
        let text = "x".repeat(200);
        let cut = first_line(&format!("\n  {text}\nmore"));
        assert_eq!(cut.chars().count(), TEXT_LEN + 1);
        assert!(cut.ends_with('…'));
        assert_eq!(first_line("kurz"), "kurz");
    }

    #[test]
    fn place_is_the_longest_folder() {
        let folders = [
            ("/home/a/shop".to_owned(), "Shop".to_owned()),
            ("/home/a/shop/.worktrees/x".to_owned(), "Shop x".to_owned()),
            ("/home/a/kino/".to_owned(), "Kino".to_owned()),
        ];
        assert_eq!(place_for("/home/a/shop/src", &folders), "Shop");
        assert_eq!(place_for("/home/a/shop/.worktrees/x", &folders), "Shop x");
        assert_eq!(place_for("/home/a/kino", &folders), "Kino");
        // A prefix only at a `/`.
        assert_eq!(place_for("/home/a/shopping", &folders), "shopping");
        assert_eq!(place_for("/home/a/other/", &folders), "other");
    }
}
