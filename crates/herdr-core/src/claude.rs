//! Conversation history of a Claude Code pane. herdr keeps no scrollback for
//! full-screen programs, but Claude Code writes every session as JSON lines
//! to `~/.claude/projects/<cwd>/<session id>.jsonl` on the host. This reads
//! that file, only from its end and a chunk at a time (a long session is
//! tens of megabytes), and turns it into prompts, answers and tool calls.
//!
//! Over SSH the files come via SFTP, so the host's key must run
//! `sftp-server` (the upload switch). Nothing is written.

use serde_json::{Value, json};

use herdr_proto::PaneGetResult;
use herdr_transport::{Connection, TransportError};

/// Bytes read per page from the end of a session file.
pub const CHUNK: u64 = 1 << 20;
/// Bytes from the end of a candidate file searched for its title.
const TITLE_TAIL: u64 = 256 * 1024;
/// Entries one step back should bring at least, if the file has them.
pub const STEP_ENTRIES: usize = 30;
/// Most bytes one step back reads: sessions hold large request copies,
/// sometimes only a few entries per megabyte.
pub const STEP_BYTES: u64 = 8 * CHUNK;
/// Newest session files of a project compared by title.
const CANDIDATES: usize = 6;
/// Longest tool summary shown.
const TOOL_SUMMARY: usize = 160;
/// Newest sessions [`list_sessions`] returns (#304): each costs two reads.
pub const LIST_LIMIT: usize = 30;
/// Bytes from the start of a session searched for its first prompt.
const HEAD_BYTES: u64 = 64 * 1024;
/// Longest first prompt used as a title.
const PROMPT_TITLE: usize = 120;

#[derive(Debug, thiserror::Error)]
pub enum ClaudeError {
    #[error(transparent)]
    Transport(#[from] TransportError),
    #[error("no Claude Code session found in {0}")]
    NoSession(String),
    #[error("herdr does not know the pane's directory")]
    NoDirectory,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryKind {
    /// A prompt typed by the user.
    User,
    /// Text Claude wrote.
    Assistant,
    /// A tool call, as `Name: what`.
    Tool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub kind: EntryKind,
    pub text: String,
    /// ISO 8601 as written by Claude Code.
    pub timestamp: Option<String>,
}

/// The session file that belongs to a pane.
#[derive(Debug, Clone)]
pub struct Session {
    /// Below the home directory.
    pub path: String,
    pub size: u64,
}

/// A session of a folder, from [`list_sessions`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionSummary {
    /// What `claude --resume` takes: the file name without `.jsonl`.
    pub id: String,
    pub title: String,
    /// Seconds since 1970, 0 if unknown.
    pub modified: u64,
    /// Bytes of the session file.
    pub size: u64,
}

/// One page of a session, oldest entry first.
#[derive(Debug, Clone)]
pub struct Page {
    pub entries: Vec<Entry>,
    /// Pass as `end` for the page before this one; 0 at the file's start.
    pub start: u64,
}

/// Claude Code's folder name for a working directory: every character that
/// is not an ASCII letter or digit becomes `-`.
pub fn project_dir(cwd: &str) -> String {
    let name: String = cwd
        .chars()
        .map(|ch| if ch.is_ascii_alphanumeric() { ch } else { '-' })
        .collect();
    format!(".claude/projects/{name}")
}

/// Finds the session file of the Claude Code pane `pane_id`: in the
/// project folder of its directory, the newest file whose last AI title is
/// the pane's terminal title (Claude Code shows it there), else the newest.
pub async fn find_session(conn: &Connection, pane_id: &str) -> Result<Session, ClaudeError> {
    let result = conn
        .request("pane.get", json!({ "pane_id": pane_id }))
        .await?;
    let pane = serde_json::from_value::<PaneGetResult>(result)
        .map_err(|err| TransportError::Files(err.to_string()))?
        .pane;
    let cwd = pane.cwd.ok_or(ClaudeError::NoDirectory)?;
    let dir = project_dir(&cwd);
    let mut files: Vec<_> = conn
        .list_files(&dir)
        .await?
        .into_iter()
        .filter(|file| file.name.ends_with(".jsonl"))
        .collect();
    files.sort_by_key(|file| std::cmp::Reverse(file.modified));
    files.truncate(CANDIDATES);
    let newest = files
        .first()
        .ok_or_else(|| ClaudeError::NoSession(dir.clone()))?;
    let path = |name: &str| format!("{dir}/{name}");
    let wanted = pane.terminal_title_stripped.as_deref().map(plain_title);
    if let Some(wanted) = wanted.filter(|title| !title.is_empty()) {
        for file in &files {
            let tail = conn
                .read_file_range(
                    &path(&file.name),
                    file.size.saturating_sub(TITLE_TAIL),
                    TITLE_TAIL,
                )
                .await?;
            if last_title(&tail, "ai-title", "aiTitle")
                .is_some_and(|title| plain_title(&title) == wanted)
            {
                return Ok(Session {
                    path: path(&file.name),
                    size: file.size,
                });
            }
        }
    }
    Ok(Session {
        path: path(&newest.name),
        size: newest.size,
    })
}

/// The Claude Code sessions of the working directory `cwd`, newest first
/// and at most [`LIST_LIMIT`]. A folder Claude Code never ran in has none.
/// Reads the end of each file and, if no title is there, its start.
pub async fn list_sessions(
    conn: &Connection,
    cwd: &str,
) -> Result<Vec<SessionSummary>, ClaudeError> {
    let dir = project_dir(cwd);
    let mut files: Vec<_> = conn
        .list_files_if_present(&dir)
        .await?
        .into_iter()
        .filter(|file| file.name.ends_with(".jsonl"))
        .collect();
    files.sort_by_key(|file| std::cmp::Reverse(file.modified));
    files.truncate(LIST_LIMIT);
    let mut sessions = Vec::with_capacity(files.len());
    for file in files {
        let path = format!("{dir}/{}", file.name);
        let tail = conn
            .read_file_range(&path, file.size.saturating_sub(TITLE_TAIL), TITLE_TAIL)
            .await?;
        let title = match tail_title(&tail) {
            Some(title) => Some(title),
            None => first_prompt(&conn.read_file_range(&path, 0, HEAD_BYTES).await?),
        };
        let id = file.name.trim_end_matches(".jsonl").to_owned();
        let title = title
            .map(|title| plain_title(&title))
            .filter(|title| !title.is_empty())
            .unwrap_or_else(|| id.chars().take(8).collect());
        sessions.push(SessionSummary {
            id,
            title,
            modified: file.modified,
            size: file.size,
        });
    }
    Ok(sessions)
}

/// The page that ends at byte `end` of `session` (its size for the newest).
pub async fn read_page(
    conn: &Connection,
    session: &Session,
    end: u64,
) -> Result<Page, ClaudeError> {
    let start = end.saturating_sub(CHUNK);
    let data = conn
        .read_file_range(&session.path, start, end - start)
        .await?;
    Ok(parse_page(&data, start))
}

/// Pages back from `end` until at least [`STEP_ENTRIES`] entries or
/// [`STEP_BYTES`] are read, or the file's start is reached.
pub async fn read_back(
    conn: &Connection,
    session: &Session,
    end: u64,
) -> Result<Page, ClaudeError> {
    let mut entries = Vec::new();
    let mut start = end;
    while start > 0 && entries.len() < STEP_ENTRIES && end - start < STEP_BYTES {
        let page = read_page(conn, session, start).await?;
        entries.splice(0..0, page.entries);
        start = page.start;
    }
    Ok(Page { entries, start })
}

/// Entries of the complete lines in `data`, which starts at byte `start`
/// of the file. Unless `start` is 0, the first line may be cut off: it is
/// left to the page before, which then ends where that line starts.
pub fn parse_page(data: &[u8], start: u64) -> Page {
    let (skip, page_start) = if start == 0 {
        (0, 0)
    } else {
        match data.iter().position(|&b| b == b'\n') {
            Some(at) if at + 1 < data.len() => (at + 1, start + at as u64 + 1),
            // All of it is one line longer than a chunk (a request copy):
            // nothing to show, continue before it, so paging always moves
            // back. Such a line is lost.
            _ => {
                return Page {
                    entries: Vec::new(),
                    start,
                };
            }
        }
    };
    let mut entries = Vec::new();
    // A last line without newline is still being written.
    for line in data[skip..]
        .split(|&b| b == b'\n')
        .filter(|line| !line.is_empty())
    {
        if let Ok(value) = serde_json::from_slice::<Value>(line) {
            entries.extend(entries_of(&value));
        }
    }
    Page {
        entries,
        start: page_start,
    }
}

fn entries_of(line: &Value) -> Vec<Entry> {
    // Subagents and meta lines (commands, reminders) are not the conversation.
    if line["isSidechain"].as_bool() == Some(true) || line["isMeta"].as_bool() == Some(true) {
        return Vec::new();
    }
    let timestamp = line["timestamp"].as_str().map(str::to_owned);
    let entry = |kind, text: String| Entry {
        kind,
        text,
        timestamp: timestamp.clone(),
    };
    let content = &line["message"]["content"];
    match line["type"].as_str() {
        Some("user") => {
            let text = match content {
                Value::String(text) => text.clone(),
                // Tool results come back as user lines without text blocks.
                Value::Array(blocks) => texts(blocks).join("\n"),
                _ => String::new(),
            };
            let text = text.trim();
            if text.is_empty() {
                Vec::new()
            } else {
                vec![entry(EntryKind::User, text.to_owned())]
            }
        }
        Some("assistant") => content
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|block| match block["type"].as_str() {
                Some("text") => block["text"]
                    .as_str()
                    .map(str::trim)
                    .filter(|text| !text.is_empty())
                    .map(|text| entry(EntryKind::Assistant, text.to_owned())),
                Some("tool_use") => Some(entry(EntryKind::Tool, tool_summary(block))),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}

fn texts(blocks: &[Value]) -> Vec<String> {
    blocks
        .iter()
        .filter(|block| block["type"].as_str() == Some("text"))
        .filter_map(|block| block["text"].as_str().map(str::to_owned))
        .collect()
}

/// `Bash: cargo test`, `Edit: src/lib.rs` and the like.
fn tool_summary(block: &Value) -> String {
    let name = block["name"].as_str().unwrap_or("Tool");
    let input = &block["input"];
    let what = [
        "description",
        "command",
        "file_path",
        "path",
        "pattern",
        "url",
        "query",
        "prompt",
    ]
    .iter()
    .find_map(|key| input[*key].as_str())
    .unwrap_or_default();
    let what = what.lines().next().unwrap_or_default().trim();
    if what.is_empty() {
        return name.to_owned();
    }
    let mut short: String = what.chars().take(TOOL_SUMMARY).collect();
    if short.len() < what.len() {
        short.push('…');
    }
    format!("{name}: {short}")
}

/// The `key` of the last line of type `kind` among the complete lines of
/// `data`, e.g. `aiTitle` of `ai-title`.
fn last_title(data: &[u8], kind: &str, key: &str) -> Option<String> {
    let kind = kind.as_bytes();
    data.split(|&b| b == b'\n')
        .rev()
        .filter(|line| line.windows(kind.len()).any(|w| w == kind))
        .find_map(|line| {
            let value: Value = serde_json::from_slice(line).ok()?;
            value[key].as_str().map(str::to_owned)
        })
}

/// The title at the end of a session: a name given with `/rename` wins
/// over the one Claude Code chose.
fn tail_title(data: &[u8]) -> Option<String> {
    last_title(data, "custom-title", "customTitle")
        .or_else(|| last_title(data, "ai-title", "aiTitle"))
}

/// The first prompt among the complete lines of `data`, the start of a
/// session: its first line that is no tag (pasted text, commands), at most
/// [`PROMPT_TITLE`] characters.
fn first_prompt(data: &[u8]) -> Option<String> {
    data.split(|&b| b == b'\n').find_map(|line| {
        let value: Value = serde_json::from_slice(line).ok()?;
        let entry = entries_of(&value)
            .into_iter()
            .find(|entry| entry.kind == EntryKind::User)?;
        let line = entry
            .text
            .lines()
            .map(str::trim)
            .find(|line| !line.is_empty() && !line.starts_with('<'))?
            .to_owned();
        let mut short: String = line.chars().take(PROMPT_TITLE).collect();
        if short.len() < line.len() {
            short.push('…');
        }
        Some(short)
    })
}

/// A title without the status mark Claude Code puts in front (`◑ `, `✳ `).
fn plain_title(title: &str) -> String {
    title
        .trim_start_matches(|ch: char| !ch.is_alphanumeric() && !ch.is_ascii_punctuation())
        .trim()
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(values: &[Value]) -> Vec<u8> {
        values
            .iter()
            .flat_map(|v| format!("{v}\n").into_bytes())
            .collect()
    }

    #[test]
    fn project_dir_like_claude_code() {
        assert_eq!(
            project_dir("/Users/me/dev/shop/.claude/worktrees/x_y"),
            ".claude/projects/-Users-me-dev-shop--claude-worktrees-x-y"
        );
    }

    #[test]
    fn prompts_answers_and_tools() {
        let data = lines(&[
            json!({"type": "user", "timestamp": "t1", "message": {"content": "Bitte testen"}}),
            json!({"type": "assistant", "message": {"content": [
                {"type": "thinking", "thinking": "hm"},
                {"type": "text", "text": "Mache ich."},
                {"type": "tool_use", "name": "Bash", "input": {"command": "cargo test\n--quiet"}},
            ]}}),
            json!({"type": "user", "message": {"content": [{"type": "tool_result", "content": "ok"}]}}),
            json!({"type": "user", "isMeta": true, "message": {"content": "<command>"}}),
            json!({"type": "assistant", "isSidechain": true, "message": {"content": [{"type": "text", "text": "sub"}]}}),
            json!({"type": "attachment", "attachment": {}}),
        ]);
        let page = parse_page(&data, 0);
        assert_eq!(page.start, 0);
        let got: Vec<_> = page
            .entries
            .iter()
            .map(|e| (e.kind, e.text.as_str()))
            .collect();
        assert_eq!(
            got,
            [
                (EntryKind::User, "Bitte testen"),
                (EntryKind::Assistant, "Mache ich."),
                (EntryKind::Tool, "Bash: cargo test"),
            ]
        );
        assert_eq!(page.entries[0].timestamp.as_deref(), Some("t1"));
    }

    #[test]
    fn a_cut_first_line_goes_to_the_page_before() {
        let data = lines(&[
            json!({"type": "user", "message": {"content": "erste"}}),
            json!({"type": "user", "message": {"content": "zweite"}}),
        ]);
        // The page starts five bytes into the first line.
        let page = parse_page(&data[5..], 100);
        let first_len = data.iter().position(|&b| b == b'\n').expect("newline") as u64 + 1;
        assert_eq!(page.start, 100 + first_len - 5);
        assert_eq!(page.entries.len(), 1);
        assert_eq!(page.entries[0].text, "zweite");
        // Inside one long line, or only its end: nothing, and the next page
        // ends before it.
        for data in [&b"abcdef"[..], b"abcdef\n"] {
            let page = parse_page(data, 100);
            assert!(page.entries.is_empty());
            assert_eq!(page.start, 100);
        }
    }

    #[test]
    fn unfinished_last_line_is_skipped() {
        let mut data = lines(&[json!({"type": "user", "message": {"content": "fertig"}})]);
        data.extend_from_slice(br#"{"type": "user", "message": {"content": "halb"#);
        let page = parse_page(&data, 0);
        assert_eq!(page.entries.len(), 1);
    }

    #[test]
    fn title_without_status_mark() {
        let data = lines(&[
            json!({"type": "ai-title", "aiTitle": "Alt"}),
            json!({"type": "ai-title", "aiTitle": "Offene Geräte-Schritte aus #84"}),
            json!({"type": "user", "message": {"content": "x"}}),
        ]);
        assert_eq!(
            last_title(&data, "ai-title", "aiTitle").as_deref(),
            Some("Offene Geräte-Schritte aus #84")
        );
        assert_eq!(
            plain_title("◑ Offene Geräte-Schritte aus #84"),
            "Offene Geräte-Schritte aus #84"
        );
        assert_eq!(plain_title("✳ Claude Code"), "Claude Code");
    }

    #[test]
    fn rename_wins_over_ai_title() {
        let data = lines(&[
            json!({"type": "custom-title", "customTitle": "Umbenannt"}),
            json!({"type": "ai-title", "aiTitle": "Von Claude"}),
        ]);
        assert_eq!(tail_title(&data).as_deref(), Some("Umbenannt"));
        let data = lines(&[json!({"type": "ai-title", "aiTitle": "Von Claude"})]);
        assert_eq!(tail_title(&data).as_deref(), Some("Von Claude"));
        assert_eq!(tail_title(b"{\"type\": \"user\"}\n"), None);
    }

    #[test]
    fn first_prompt_skips_meta_sidechain_and_tags() {
        let data = lines(&[
            json!({"type": "attachment", "attachment": {}}),
            json!({"type": "user", "isMeta": true, "message": {"content": "meta"}}),
            json!({"type": "user", "isSidechain": true, "message": {"content": "sub"}}),
            json!({"type": "user", "message": {"content": "<command-name>/x</command-name>"}}),
            json!({"type": "user", "message": {"content": [
                {"type": "text", "text": "\n<pasted_content id=\"1\">\n  Erste Zeile  \nzweite"},
            ]}}),
        ]);
        assert_eq!(first_prompt(&data).as_deref(), Some("Erste Zeile"));
        assert_eq!(first_prompt(&lines(&[json!({"type": "ai-title"})])), None);
    }

    #[test]
    fn first_prompt_is_cut() {
        let long = "ä".repeat(PROMPT_TITLE + 5);
        let data = lines(&[json!({"type": "user", "message": {"content": long}})]);
        let title = first_prompt(&data).expect("title");
        assert_eq!(title.chars().count(), PROMPT_TITLE + 1);
        assert!(title.ends_with('…'));
        let exact = "a".repeat(PROMPT_TITLE);
        let data = lines(&[json!({"type": "user", "message": {"content": exact.clone()}})]);
        assert_eq!(first_prompt(&data), Some(exact));
    }
}
