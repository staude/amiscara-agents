//! Conversation history of a Claude Code pane. herdr keeps no scrollback for
//! full-screen programs, but Claude Code writes every session as JSON lines
//! to `~/.claude/projects/<cwd>/<session id>.jsonl` on the host. This reads
//! that file, only from its end and a chunk at a time (a long session is
//! tens of megabytes), and turns it into prompts, answers and tool calls.
//!
//! Over SSH the files come via SFTP, so the host's key must run
//! `sftp-server` (the upload switch). Nothing is written.
//!
//! The search across all conversations of a host (#303) finds its hits
//! either line by line in files read here ([`hits_in_line`]) or with grep
//! on the host ([`search_script`]); both give the line's byte offset,
//! from which [`read_hit_line`] and [`read_forward`] continue.

use serde_json::{Value, json};

use herdr_proto::PaneGetResult;
use herdr_transport::{Connection, TransportError};

/// Bytes read per page from the end of a session file.
pub const CHUNK: u64 = 1 << 20;
/// Bytes from the end of a candidate file searched for its title.
const TITLE_TAIL: u64 = 256 * 1024;
/// Bytes from the end [`list_sessions`] reads first: Claude Code writes
/// its title lines again and again, so they are mostly near the end.
const TITLE_PEEK: u64 = 32 * 1024;
/// Entries one step back should bring at least, if the file has them.
pub const STEP_ENTRIES: usize = 30;
/// Most bytes one step back reads: sessions hold large request copies,
/// sometimes only a few entries per megabyte.
pub const STEP_BYTES: u64 = 8 * CHUNK;
/// Newest session files of a project compared by title.
const CANDIDATES: usize = 6;
/// Longest tool summary shown.
const TOOL_SUMMARY: usize = 160;
/// Shortest search text, in characters.
pub const MIN_QUERY: usize = 2;
/// Characters a snippet shows on each side of the match.
const SNIPPET_CONTEXT: usize = 80;
/// Bytes first read for the line of a hit; a longer line is read again
/// up to [`MAX_HIT_LINE`].
const HIT_READ: u64 = 64 * 1024;
/// Longest line of a hit; a longer one is a request copy, not text.
pub const MAX_HIT_LINE: u64 = CHUNK;
/// Matching lines grep reports per file on the host.
pub const HOST_HITS_PER_FILE: usize = 20;
/// Matching lines the host's search reports in all.
pub const HOST_MAX_LINES: usize = 300;
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
    /// The search text is too short or spans lines.
    #[error("{0}")]
    Query(String),
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

/// What follows a position of a session file, oldest entry first.
#[derive(Debug, Clone)]
pub struct After {
    pub entries: Vec<Entry>,
    /// Where the next step forward starts: after the last complete line read.
    pub end: u64,
    /// Whether the file ends there for now (a line still being written is
    /// left for later).
    pub at_end: bool,
}

/// A search text, lowercase. Matching ignores case.
#[derive(Debug, Clone)]
pub struct Query {
    lower: String,
    /// `lower` as it appears inside a JSON string, for raw lines.
    json: String,
}

impl Query {
    /// Trimmed; at least [`MIN_QUERY`] characters and on one line.
    pub fn new(text: &str) -> Result<Self, ClaudeError> {
        let text = text.trim();
        if text.contains(['\n', '\r']) {
            return Err(ClaudeError::Query(
                "the search text must be on one line".into(),
            ));
        }
        if text.chars().count() < MIN_QUERY {
            return Err(ClaudeError::Query(format!(
                "the search text needs at least {MIN_QUERY} characters"
            )));
        }
        let lower = text.to_lowercase();
        let quoted = serde_json::to_string(&lower).unwrap_or_default();
        let json = quoted
            .strip_prefix('"')
            .and_then(|rest| rest.strip_suffix('"'))
            .unwrap_or(&lower)
            .to_owned();
        Ok(Self { lower, json })
    }

    /// The text to look for in raw JSON lines, as grep's fixed pattern.
    pub fn json(&self) -> &str {
        &self.json
    }

    /// Whether the raw `line` may hold a hit: cheaper than parsing it.
    fn may_match(&self, line: &[u8]) -> bool {
        let needle = self.json.as_bytes();
        if needle.is_ascii() {
            line.windows(needle.len())
                .any(|window| window.eq_ignore_ascii_case(needle))
        } else {
            String::from_utf8_lossy(line)
                .to_lowercase()
                .contains(&self.json)
        }
    }
}

/// An entry of a session file that contains the search text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hit {
    /// The session file below the home directory.
    pub path: String,
    /// Where the entry's line starts in the file.
    pub offset: u64,
    pub kind: EntryKind,
    /// The text around the first match, see [`snippet`].
    pub snippet: String,
    /// ISO 8601 as written by Claude Code.
    pub timestamp: Option<String>,
    /// The working directory Claude Code ran in.
    pub cwd: Option<String>,
}

/// The entries of the session line `line`, which starts at byte `offset`
/// of `path`, whose text contains `query`.
pub fn hits_in_line(path: &str, line: &[u8], offset: u64, query: &Query) -> Vec<Hit> {
    if !query.may_match(line) {
        return Vec::new();
    }
    let Ok(value) = serde_json::from_slice::<Value>(line) else {
        return Vec::new();
    };
    let cwd = value["cwd"].as_str().map(str::to_owned);
    entries_of(&value)
        .into_iter()
        .filter_map(|entry| {
            Some(Hit {
                snippet: snippet(&entry.text, &query.lower)?,
                path: path.to_owned(),
                offset,
                kind: entry.kind,
                timestamp: entry.timestamp,
                cwd: cwd.clone(),
            })
        })
        .collect()
}

/// Up to [`SNIPPET_CONTEXT`] characters on each side of the first match of
/// the lowercase `needle` in `text`, ignoring case; line breaks and other
/// runs of white space become one space, `…` marks where it was cut.
/// `None` without a match.
pub fn snippet(text: &str, needle: &str) -> Option<String> {
    let chars: Vec<char> = text.chars().collect();
    // Lowercase can change a character's length: remember which
    // character each byte of the lowercase text comes from.
    let mut lower = String::with_capacity(text.len());
    let mut owner = Vec::with_capacity(text.len());
    for (index, ch) in chars.iter().enumerate() {
        for low in ch.to_lowercase() {
            lower.push(low);
            owner.extend(std::iter::repeat_n(index, low.len_utf8()));
        }
    }
    let at = lower.find(needle)?;
    let first = owner[at];
    let last = owner[at + needle.len().max(1) - 1];
    let from = first.saturating_sub(SNIPPET_CONTEXT);
    let to = (last + 1 + SNIPPET_CONTEXT).min(chars.len());
    let mut middle = String::new();
    let mut in_space = false;
    for &ch in &chars[from..to] {
        if ch.is_whitespace() {
            if !in_space {
                middle.push(' ');
            }
            in_space = true;
        } else {
            middle.push(ch);
            in_space = false;
        }
    }
    let mut out = String::new();
    if from > 0 {
        out.push('…');
    }
    out.push_str(middle.trim());
    if to < chars.len() {
        out.push('…');
    }
    Some(out)
}

/// A POSIX `sh` script that searches all session files below
/// `~/.claude/projects` with grep for the fixed pattern in the file
/// `pattern` (see [`Query::json`]), ignoring case, in the lines of
/// prompts and answers. The other arguments name files next to the
/// script: `total` gets the number of files, `progress` one byte per file
/// searched, `out` one `path:offset` line per matching line (at most
/// [`HOST_HITS_PER_FILE`] per file plus one, so a cut shows), and at the end
/// `<out>.done` the first [`HOST_MAX_LINES`] of them plus one, so a cut
/// shows. Read only.
pub fn search_script(pattern: &str, out: &str, progress: &str, total: &str) -> String {
    let name = |path: &str| path.rsplit('/').next().unwrap_or(path).to_owned();
    format!(
        r#"#!/bin/sh
# Amiscara Agents: searches the Claude Code conversations for the app (read only).
d=$(cd "$(dirname "$0")" && pwd) || exit 1
out="$d/{out}"
# grep prints the offset of the line with -b, ugrep that of the match.
G=/usr/bin/grep
[ -x "$G" ] || G=grep
cd "$HOME" || exit 1
# Newest first, so the limits keep recent conversations: the last 30 days
# before the rest, each sorted by ls (a long list in batches of its own).
# Subagents are not the conversation.
p=.claude/projects
{{
  find "$p" -name '*.jsonl' -type f ! -path '*/subagents/*' -mtime -30 -exec ls -t {{}} +
  find "$p" -name '*.jsonl' -type f ! -path '*/subagents/*' ! -mtime -30 -exec ls -t {{}} +
}} >"$out.list" 2>/dev/null
wc -l <"$out.list" | tr -d ' ' >"$d/{total}"
# Lowercase ASCII text to check after grep; empty (no check) otherwise,
# awk would not lowercase other letters.
P=$(export LC_ALL=C; t=$(cat "$d/{pattern}"); case "$t" in (*[!\ -~]*) ;; (*) printf '%s' "$t" ;; esac)
export P
# Only prompts and answers: attachments, request copies, tool results and
# subagents mention a word as often and would fill the limits. Of a line
# only the texts the app shows count (a typed prompt, text blocks, the
# fields of a tool call it names): sed drops every other field (ids, model,
# directory, branch, thinking and its signature, file contents) and all
# names.
while IFS= read -r f; do
  "$G" -a -b -i -F -f "$d/{pattern}" -- "$f" 2>/dev/null |
    "$G" -a -F -e '"type":"user"' -e '"type":"assistant"' |
    "$G" -a -v -F -e '"type":"tool_result"' -e '"isSidechain":true' -e '"isMeta":true' |
    LC_ALL=C sed -E \
      -e 's/"role":"user","content":"/"@content":"/g' \
      -e 's/"(text|description|command|file_path|path|pattern|url|query|prompt)":"/"@\1":"/g' \
      -e 's/"[A-Za-z0-9_]+":("([^"\\]|\\.)*"|-?[0-9][-+.eE0-9]*|true|false|null)//g' \
      -e 's/"@?[A-Za-z0-9_]+"://g' |
    LC_ALL=C awk '{{ i = index($0, ":"); if (ENVIRON["P"] == "" || index(tolower(substr($0, i + 1)), ENVIRON["P"])) print substr($0, 1, i - 1) }}' |
    head -n {per_file} |
    while IFS= read -r o; do printf '%s:%s\n' "$f" "$o"; done
  printf . >>"$d/{progress}"
done <"$out.list" >"$out"
head -n {lines} "$out" >"$out.head"
mv "$out.head" "$out.done"
"#,
        out = name(out),
        total = name(total),
        progress = name(progress),
        pattern = name(pattern),
        per_file = HOST_HITS_PER_FILE + 1,
        lines = HOST_MAX_LINES + 1,
    )
}

/// The `path:offset` lines of [`search_script`]'s output.
pub fn parse_search_output(output: &str) -> Vec<(String, u64)> {
    output
        .lines()
        .filter_map(|line| {
            let (path, offset) = line.rsplit_once(':')?;
            Some((path.to_owned(), offset.trim().parse().ok()?))
        })
        .collect()
}

/// The line of `path` that starts at byte `offset`, without its line
/// break. `None` when it is longer than [`MAX_HIT_LINE`].
pub async fn read_hit_line(
    conn: &Connection,
    path: &str,
    offset: u64,
) -> Result<Option<Vec<u8>>, ClaudeError> {
    let mut len = HIT_READ;
    loop {
        let mut data = conn.read_file_range(path, offset, len).await?;
        if let Some(end) = data.iter().position(|&b| b == b'\n') {
            data.truncate(end);
            return Ok(Some(data));
        }
        if (data.len() as u64) < len {
            // The file's last line.
            return Ok(Some(data));
        }
        if len >= MAX_HIT_LINE {
            return Ok(None);
        }
        len = MAX_HIT_LINE;
    }
}

/// The entries after byte `from` of the session file `path`, which starts
/// a line: whole lines until at least [`STEP_ENTRIES`] entries or
/// [`STEP_BYTES`] are read, or the file ends.
pub async fn read_forward(conn: &Connection, path: &str, from: u64) -> Result<After, ClaudeError> {
    forward_with(|at| conn.read_file_range(path, at, CHUNK), from).await
}

/// [`read_forward`] with `read` giving up to [`CHUNK`] bytes from a
/// position.
async fn forward_with<F, Fut>(mut read: F, from: u64) -> Result<After, ClaudeError>
where
    F: FnMut(u64) -> Fut,
    Fut: std::future::Future<Output = Result<Vec<u8>, TransportError>>,
{
    let mut entries = Vec::new();
    let mut end = from;
    let mut at_end = false;
    // Inside a line longer than a chunk, which is skipped.
    let mut in_long_line = false;
    while !at_end && entries.len() < STEP_ENTRIES && end - from < STEP_BYTES {
        let data = read(end).await?;
        let full = data.len() as u64 == CHUNK;
        // A short read reaches the file's end; a line without its line
        // break there is still being written and left for later.
        at_end = !full;
        let mut skip = 0;
        if in_long_line {
            match data.iter().position(|&b| b == b'\n') {
                Some(at) => {
                    skip = at + 1;
                    in_long_line = false;
                }
                None => {
                    end += data.len() as u64;
                    continue;
                }
            }
        }
        match data[skip..].iter().rposition(|&b| b == b'\n') {
            Some(last) => {
                entries.extend(parse_page(&data[skip..=skip + last], 0).entries);
                end += (skip + last) as u64 + 1;
            }
            // A line starts after the skipped one: read again from there.
            None if skip > 0 => end += skip as u64,
            // One line longer than a chunk (a request copy): skipped.
            None if full => {
                end += CHUNK;
                in_long_line = true;
            }
            None => {}
        }
    }
    Ok(After {
        entries,
        end,
        at_end,
    })
}

/// The title of the session file `path` of `size` bytes, see [`tail_title`].
/// `None` for an unknown size of 0.
pub async fn session_title(conn: &Connection, path: &str, size: u64) -> Option<String> {
    if size == 0 {
        return None;
    }
    let tail = conn
        .read_file_range(path, size.saturating_sub(TITLE_TAIL), TITLE_TAIL)
        .await
        .ok()?;
    tail_title(&tail)
}

/// The entries of the line `line` of a session file.
pub fn entries_in_line(line: &[u8]) -> Vec<Entry> {
    serde_json::from_slice::<Value>(line)
        .map(|value| entries_of(&value))
        .unwrap_or_default()
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
/// Reads the end of each file (a little, then more) and, if no title is
/// there, its start.
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
        let mut title = None;
        for len in [TITLE_PEEK, TITLE_TAIL] {
            let tail = conn
                .read_file_range(&path, file.size.saturating_sub(len), len)
                .await?;
            title = tail_title(&tail);
            if title.is_some() || file.size <= len {
                break;
            }
        }
        if title.is_none() {
            title = first_prompt(&conn.read_file_range(&path, 0, HEAD_BYTES).await?);
        }
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

/// Whether `id` can be a Claude Code session id (a UUID): only ASCII
/// letters, digits and `-`, so it is safe as an argument of `claude`.
pub fn is_session_id(id: &str) -> bool {
    !id.is_empty() && id.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '-')
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
    fn search_text_rules() {
        assert!(matches!(Query::new(" a "), Err(ClaudeError::Query(_))));
        assert!(matches!(Query::new("ab\ncd"), Err(ClaudeError::Query(_))));
        let query = Query::new("  Sag \"Hallo\" ").expect("query");
        assert_eq!(query.lower, "sag \"hallo\"");
        assert_eq!(query.json(), r#"sag \"hallo\""#);
        assert!(Query::new("äö").is_ok());
    }

    #[test]
    fn hits_of_a_line_ignore_case() {
        let line = json!({
            "type": "assistant",
            "cwd": "/Users/me/dev/app",
            "timestamp": "t1",
            "message": {"content": [
                {"type": "text", "text": "Der SCHLÜSSEL liegt in der Keychain."},
                {"type": "tool_use", "name": "Bash", "input": {"command": "security find schlüssel"}},
                {"type": "text", "text": "Nichts davon."},
            ]},
        })
        .to_string();
        let query = Query::new("Schlüssel").expect("query");
        let hits = hits_in_line("p.jsonl", line.as_bytes(), 42, &query);
        let got: Vec<_> = hits.iter().map(|h| (h.kind, h.snippet.as_str())).collect();
        assert_eq!(
            got,
            [
                (EntryKind::Assistant, "Der SCHLÜSSEL liegt in der Keychain."),
                (EntryKind::Tool, "Bash: security find schlüssel"),
            ]
        );
        assert_eq!(hits[0].offset, 42);
        assert_eq!(hits[0].cwd.as_deref(), Some("/Users/me/dev/app"));
        assert_eq!(hits[0].timestamp.as_deref(), Some("t1"));
        // Only in the metadata, or in a quoted text: as JSON writes it.
        let app = Query::new("dev/app").expect("query");
        assert!(hits_in_line("p", line.as_bytes(), 0, &app).is_empty());
        let quoted =
            json!({"type": "user", "message": {"content": "Sag \"Hallo\" bitte"}}).to_string();
        let query = Query::new("\"hallo\"").expect("query");
        assert_eq!(hits_in_line("p", quoted.as_bytes(), 0, &query).len(), 1);
    }

    #[test]
    fn snippet_around_the_match() {
        let text = format!("{}\nKeychain\n\n{}", "a".repeat(100), "b".repeat(100));
        let got = snippet(&text, "keychain").expect("match");
        assert_eq!(
            got,
            format!("…{} Keychain {}…", "a".repeat(79), "b".repeat(78))
        );
        assert_eq!(snippet("kurz", "ur").as_deref(), Some("kurz"));
        assert_eq!(snippet("kurz", "lang"), None);
        // A character whose lowercase is longer (İ is i plus a dot).
        assert_eq!(snippet("İstanbul x", "x").as_deref(), Some("İstanbul x"));
    }

    #[test]
    fn host_output_lines() {
        let out = ".claude/projects/-a/1.jsonl:0\n.claude/projects/-a/1.jsonl:4711\nBinary file x matches\n";
        assert_eq!(
            parse_search_output(out),
            [
                (".claude/projects/-a/1.jsonl".to_owned(), 0),
                (".claude/projects/-a/1.jsonl".to_owned(), 4711),
            ]
        );
    }

    /// Runs the host's search script with `HOME` in a temporary folder.
    #[cfg(unix)]
    #[test]
    fn search_script_finds_lines_in_two_projects() {
        let home = std::env::temp_dir().join(format!("herdr-search-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        // As Claude Code writes it: `role` before `content`.
        let entry = |text: &str| {
            format!(
                "{{\"type\":\"user\",\"message\":{{\"role\":\"user\",\"content\":{}}}}}\n",
                json!(text)
            )
        };
        for (dir, lines) in [
            (
                "-Users-me-a",
                vec![
                    entry("erst"),
                    entry("die KEYCHAIN hier"),
                    format!("{}\n", json!({"type": "attachment", "content": "Keychain"})),
                    format!(
                        "{}\n",
                        json!({"type": "user", "message": {"content": [
                            {"type": "tool_result", "content": "keychain"},
                        ]}})
                    ),
                ],
            ),
            (
                "-Users-me-b",
                vec![
                    entry("keychain auch"),
                    format!(
                        "{}\n",
                        json!({"type": "assistant", "message": {"model": "keychain-1", "content": [
                            {"type": "thinking", "thinking": "die \"Keychain\"", "signature": "keychain"},
                        ]}})
                    ),
                ],
            ),
            (
                "-Users-me-c",
                vec![format!(
                    "{}\n",
                    json!({"type": "user", "cwd": "/keychain", "message": {"content": "nichts"}})
                )],
            ),
        ] {
            let dir = home.join(".claude/projects").join(dir);
            std::fs::create_dir_all(&dir).expect("dir");
            std::fs::write(dir.join("s.jsonl"), lines.concat()).expect("file");
        }
        let work = home.join("up");
        std::fs::create_dir_all(&work).expect("dir");
        let query = Query::new("Keychain").expect("query");
        std::fs::write(work.join("p.txt"), format!("{}\n", query.json())).expect("pattern");
        std::fs::write(
            work.join("s.sh"),
            search_script("up/p.txt", "up/o.txt", "up/g.txt", "up/t.txt"),
        )
        .expect("script");
        let status = std::process::Command::new("sh")
            .arg(work.join("s.sh"))
            .env("HOME", &home)
            .status()
            .expect("sh");
        assert!(status.success());
        let done = std::fs::read_to_string(work.join("o.txt.done")).expect("done");
        let mut found = parse_search_output(&done);
        found.sort();
        let first = entry("erst").len() as u64;
        assert_eq!(
            found,
            [
                (".claude/projects/-Users-me-a/s.jsonl".to_owned(), first),
                (".claude/projects/-Users-me-b/s.jsonl".to_owned(), 0),
            ]
        );
        assert_eq!(
            std::fs::read_to_string(work.join("t.txt"))
                .expect("total")
                .trim(),
            "3"
        );
        assert_eq!(
            std::fs::read(work.join("g.txt")).expect("progress").len(),
            3
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    async fn forward_in(data: &[u8], from: u64) -> After {
        forward_with(
            |at| {
                let at = (at as usize).min(data.len());
                let end = (at + CHUNK as usize).min(data.len());
                std::future::ready(Ok(data[at..end].to_vec()))
            },
            from,
        )
        .await
        .expect("read")
    }

    #[tokio::test]
    async fn forward_reads_whole_lines() {
        let text = |i: usize| json!({"type": "user", "message": {"content": format!("n{i}")}});
        let mut data = lines(&(0..40).map(text).collect::<Vec<_>>());
        let after = forward_in(&data, 0).await;
        assert_eq!(after.entries.len(), 40);
        assert!(after.at_end);
        assert_eq!(after.end, data.len() as u64);
        // An unfinished last line waits; a line longer than a chunk is
        // skipped, the lines after it are read.
        let long = json!({"type": "user", "message": {"content": "x".repeat(CHUNK as usize + 10)}});
        let mut tail = lines(&[long, text(99)]);
        let before = data.len() as u64;
        data.append(&mut tail);
        data.extend_from_slice(br#"{"type": "user""#);
        let after = forward_in(&data, before).await;
        assert_eq!(after.entries.len(), 1);
        assert_eq!(after.entries[0].text, "n99");
        assert!(after.at_end);
        assert_eq!(after.end, data.len() as u64 - 15);
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

    #[test]
    fn session_ids_are_checked() {
        assert!(is_session_id("1a809806-9573-40d1-a97b-f3362b079eb7"));
        for id in ["", "a b", "x;rm -rf ~", "$(id)", "../x", "a\nb", "ä"] {
            assert!(!is_session_id(id), "{id:?}");
        }
    }
}
