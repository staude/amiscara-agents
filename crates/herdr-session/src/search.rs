//! Full-text search across the Claude Code conversations of a host (#303).
//! Index-free: every search scans the session files below
//! `~/.claude/projects`. A local host's files are read directly. Over SSH
//! grep runs on the host when the app may type there (a script in a
//! short-lived, unfocused tab, as for the working tree diff); otherwise
//! the newest files of the last 30 days come over SFTP, up to 300 MB.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use herdr_core::claude::{self, Query};
use herdr_core::{SessionState, actions};
use herdr_transport::{Connection, EntryKind as FileKind};
use tokio::sync::watch;

use crate::session::{Session, SessionError, TranscriptKind, UPLOAD_DIR, files_error, run_in_tab};

/// Most hits one search reports.
pub const MAX_HITS: usize = 200;
/// Bytes read per step when the app reads a session file itself.
const SCAN_CHUNK: u64 = 8 << 20;
/// Without grep on the host: only files changed in this many days ...
const RECENT_DAYS: u64 = 30;
/// ... and newest first, up to this many bytes.
const RECENT_BYTES: u64 = 300 << 20;
/// How often the host's search is asked how far it got.
const POLL: Duration = Duration::from_millis(300);
/// How long the host's search may take.
const HOST_DEADLINE: Duration = Duration::from_secs(5 * 60);
/// Most bytes read of the host's result list.
const MAX_RESULT_BYTES: u64 = 1 << 20;

/// An entry of a Claude Code conversation that contains the search text.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationHit {
    /// The session file below the host's home directory.
    pub session_path: String,
    /// Where the entry's line starts in the file; pass both to
    /// [`Session::claude_history_at`].
    pub offset: u64,
    /// The open space whose pane works in the conversation's directory or
    /// above it; `None` when no space does.
    pub workspace_id: Option<String>,
    /// The directory Claude Code ran in.
    pub cwd: Option<String>,
    /// The session's last AI title.
    pub session_title: Option<String>,
    pub kind: TranscriptKind,
    /// The text around the first match; line breaks became spaces, `…`
    /// marks a cut.
    pub snippet: String,
    /// ISO 8601, as Claude Code wrote it.
    pub timestamp: Option<String>,
}

/// How a search ended.
#[derive(Debug, Clone, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchEnd {
    pub error: Option<String>,
    pub cancelled: bool,
    /// More hits than reported: [`MAX_HITS`], or the host's result list
    /// was cut.
    pub truncated: bool,
    /// Older or more conversations than the search read were left out
    /// (no grep on the host).
    pub older_skipped: bool,
}

/// Receives what a search finds, on a runtime thread.
pub trait SearchSink: Send + Sync + 'static {
    /// `done` of `total` steps; their unit depends on the route.
    fn on_progress(&self, done: u64, total: u64);
    /// Hits found since the last call.
    fn on_hits(&self, hits: Vec<ConversationHit>);
    /// Always the last call, once; after a cancel the only one.
    fn on_finished(&self, end: SearchEnd);
}

/// How a search reads the session files.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    /// All files, read by the app: a local host.
    ReadAll,
    /// grep in a tab on the host.
    Host,
    /// The newest files of the last 30 days, up to 300 MB, read by the app.
    ReadRecent,
}

/// Handle for [`Session::search_conversations`]; dropping it cancels.
pub struct ConversationSearch {
    stop: watch::Sender<bool>,
}

impl ConversationSearch {
    /// Ends the search once a request in flight has finished; the sink
    /// then only gets `on_finished` with `cancelled`.
    pub fn cancel(&self) {
        self.stop.send_replace(true);
    }
}

impl Drop for ConversationSearch {
    fn drop(&mut self) {
        self.stop.send_replace(true);
    }
}

impl Session {
    /// Searches all Claude Code conversations of the host for `query`
    /// (trimmed, at least two characters, one line), ignoring case.
    /// `allow_command` lets the search run grep on the host in a
    /// short-lived tab, over SSH the fast way; without it, or without an
    /// open space, only the newest conversations are read. Needs file
    /// access like uploads. Fails right away for a bad `query` or without
    /// a connection; everything else reaches `sink`.
    pub fn search_conversations(
        &self,
        query: &str,
        allow_command: bool,
        sink: impl SearchSink,
    ) -> Result<ConversationSearch, SessionError> {
        let conn = self.connection()?;
        let has_space = self
            .snapshot()
            .is_some_and(|state| !state.workspaces.is_empty());
        let route = if conn.is_local() {
            Route::ReadAll
        } else if allow_command && has_space {
            Route::Host
        } else {
            Route::ReadRecent
        };
        self.search_conversations_via(query, route, sink)
    }

    /// [`Session::search_conversations`] on a given route, for tests.
    #[doc(hidden)]
    pub fn search_conversations_via(
        &self,
        query: &str,
        route: Route,
        sink: impl SearchSink,
    ) -> Result<ConversationSearch, SessionError> {
        let query = Query::new(query)?;
        let conn = self.connection()?;
        let state = self.snapshot();
        let spaces = state.as_deref().map(pane_directories).unwrap_or_default();
        let first_space = state
            .as_deref()
            .and_then(|state| state.workspaces.first())
            .map(|space| space.workspace_id.clone());
        let (stop_tx, stop) = watch::channel(false);
        self.runtime.spawn(async move {
            let sink = Guarded {
                sink,
                stop: stop.clone(),
            };
            let mut search = Search {
                conn,
                query,
                spaces,
                home: String::new(),
                stop,
                sink: &sink,
                found: 0,
                titles: HashMap::new(),
                end: SearchEnd::default(),
            };
            let result = search.run(route, first_space).await;
            let mut end = search.end;
            end.cancelled = *search.stop.borrow();
            if !end.cancelled {
                end.error = result.err().map(|err| err.to_string());
            }
            sink.sink.on_finished(end);
        });
        Ok(ConversationSearch { stop: stop_tx })
    }

    fn snapshot(&self) -> Option<Arc<SessionState>> {
        let state = self.state.lock().ok()?;
        state.as_ref()?.borrow().session.clone()
    }
}

/// Passes progress and hits on only until the search is cancelled.
struct Guarded<S> {
    sink: S,
    stop: watch::Receiver<bool>,
}

impl<S: SearchSink> Guarded<S> {
    fn progress(&self, done: u64, total: u64) {
        if !*self.stop.borrow() {
            self.sink.on_progress(done, total);
        }
    }

    fn hits(&self, hits: Vec<ConversationHit>) {
        if !hits.is_empty() && !*self.stop.borrow() {
            self.sink.on_hits(hits);
        }
    }
}

/// The space and directory of every pane: its foreground process's
/// directory, else the pane's.
fn pane_directories(state: &SessionState) -> Vec<(String, String)> {
    state
        .panes
        .iter()
        .filter_map(|pane| {
            let cwd = pane.foreground_cwd.clone().or_else(|| pane.cwd.clone())?;
            Some((pane.workspace_id.clone(), cwd))
        })
        .collect()
}

/// The space for a conversation in `cwd`: that of a pane in the same
/// directory, else of the pane in the deepest directory above it. The home
/// directory does not count as above, it would take every conversation.
fn space_of(spaces: &[(String, String)], cwd: &str, home: &str) -> Option<String> {
    let trim = |dir: &str| dir.trim_end_matches('/').to_owned();
    let cwd = trim(cwd);
    let home = trim(home);
    if let Some((space, _)) = spaces.iter().find(|(_, dir)| trim(dir) == cwd) {
        return Some(space.clone());
    }
    spaces
        .iter()
        .map(|(space, dir)| (space, trim(dir)))
        .filter(|(_, dir)| *dir != home && !dir.is_empty())
        .filter(|(_, dir)| cwd.starts_with(&format!("{dir}/")))
        .max_by_key(|(_, dir)| dir.len())
        .map(|(space, _)| space.clone())
}

fn transcript_kind(kind: claude::EntryKind) -> TranscriptKind {
    match kind {
        claude::EntryKind::User => TranscriptKind::User,
        claude::EntryKind::Assistant => TranscriptKind::Assistant,
        claude::EntryKind::Tool => TranscriptKind::Tool,
    }
}

/// Keeps of `files` (newest first) those changed in the last
/// [`RECENT_DAYS`] before `now`, up to [`RECENT_BYTES`] in all; whether
/// any were left out.
fn keep_recent(files: &mut Vec<SessionFile>, now: u64) -> bool {
    let cutoff = now.saturating_sub(RECENT_DAYS * 24 * 60 * 60);
    let all = files.len();
    let mut budget = RECENT_BYTES;
    files.retain(|file| {
        let keep = file.modified >= cutoff && file.size <= budget;
        if keep {
            budget -= file.size;
        }
        keep
    });
    files.len() < all
}

/// The hits of one session file, fed in pieces: at most
/// [`claude::HOST_HITS_PER_FILE`] lines, like grep on the host; lines
/// longer than [`claude::MAX_HIT_LINE`] are skipped, the conversation
/// cannot open them.
struct LineScan<'a> {
    path: &'a str,
    hits: Vec<claude::Hit>,
    lines: usize,
    /// The file has more lines with hits than kept.
    cut: bool,
    /// Bytes of a line not yet complete, and where it starts.
    rest: Vec<u8>,
    rest_start: u64,
    /// Inside a line that is too long.
    skipping: bool,
}

impl<'a> LineScan<'a> {
    fn new(path: &'a str) -> Self {
        Self {
            path,
            hits: Vec::new(),
            lines: 0,
            cut: false,
            rest: Vec::new(),
            rest_start: 0,
            skipping: false,
        }
    }

    /// The next piece of the file, which starts at byte `pos`.
    fn feed(&mut self, pos: u64, data: &[u8], query: &Query) {
        let mut data = data;
        if self.skipping {
            match data.iter().position(|&b| b == b'\n') {
                Some(at) => {
                    data = &data[at + 1..];
                    self.rest_start = pos + at as u64 + 1;
                    self.skipping = false;
                }
                None => return,
            }
        }
        self.rest.extend_from_slice(data);
        let complete = self
            .rest
            .iter()
            .rposition(|&b| b == b'\n')
            .map_or(0, |at| at + 1);
        let mut start = self.rest_start;
        for line in self.rest[..complete].split(|&b| b == b'\n') {
            let found = if line.len() as u64 > claude::MAX_HIT_LINE {
                Vec::new()
            } else {
                claude::hits_in_line(self.path, line, start, query)
            };
            if !found.is_empty() {
                if self.lines == claude::HOST_HITS_PER_FILE {
                    self.cut = true;
                    return;
                }
                self.lines += 1;
                self.hits.extend(found);
            }
            start += line.len() as u64 + 1;
        }
        self.rest.drain(..complete);
        self.rest_start += complete as u64;
        if self.rest.len() as u64 > claude::MAX_HIT_LINE {
            self.rest.clear();
            self.skipping = true;
        }
    }
}

/// A session file to read.
struct SessionFile {
    path: String,
    size: u64,
    modified: u64,
}

struct Search<'a, S> {
    conn: Arc<Connection>,
    query: Query,
    spaces: Vec<(String, String)>,
    /// The host's home directory, absolute.
    home: String,
    stop: watch::Receiver<bool>,
    sink: &'a Guarded<S>,
    found: usize,
    /// AI title per session file, read once.
    titles: HashMap<String, Option<String>>,
    end: SearchEnd,
}

impl<S: SearchSink> Search<'_, S> {
    fn stopped(&self) -> bool {
        *self.stop.borrow()
    }

    /// Whether no more hits are wanted: cancelled or enough.
    fn done(&self) -> bool {
        self.stopped() || self.found >= MAX_HITS
    }

    async fn run(&mut self, route: Route, first_space: Option<String>) -> Result<(), SessionError> {
        self.home = self.conn.list_dir("").await.map_err(files_error)?.home;
        match (route, first_space) {
            (Route::Host, Some(space)) => self.on_host(&space).await,
            (Route::ReadAll, _) => self.read_files(false).await,
            _ => self.read_files(true).await,
        }
    }

    /// Reports the hits of one session file, at most up to [`MAX_HITS`].
    async fn report(&mut self, path: &str, size: u64, hits: Vec<claude::Hit>) {
        if hits.is_empty() || self.done() {
            return;
        }
        if !self.titles.contains_key(path) {
            let title = claude::session_title(&self.conn, path, size).await;
            self.titles.insert(path.to_owned(), title);
        }
        let title = self.titles.get(path).cloned().flatten();
        let room = MAX_HITS - self.found;
        if hits.len() > room {
            self.end.truncated = true;
        }
        let hits: Vec<_> = hits
            .into_iter()
            .take(room)
            .map(|hit| ConversationHit {
                workspace_id: hit
                    .cwd
                    .as_deref()
                    .and_then(|cwd| space_of(&self.spaces, cwd, &self.home)),
                session_path: hit.path,
                offset: hit.offset,
                cwd: hit.cwd,
                session_title: title.clone(),
                kind: transcript_kind(hit.kind),
                snippet: hit.snippet,
                timestamp: hit.timestamp,
            })
            .collect();
        self.found += hits.len();
        self.sink.hits(hits);
    }

    /// The session files of all project folders, newest first.
    async fn session_files(&self) -> Result<Vec<SessionFile>, SessionError> {
        let projects = format!("{}/.claude/projects", self.home.trim_end_matches('/'));
        // No folder: Claude Code never ran here.
        let Ok(listing) = self.conn.list_dir(&projects).await else {
            return Ok(Vec::new());
        };
        let mut files = Vec::new();
        for dir in listing.entries.iter().filter(|e| e.kind == FileKind::Dir) {
            if self.stopped() {
                break;
            }
            let rel = format!(".claude/projects/{}", dir.name);
            let found = self
                .conn
                .list_files_if_present(&rel)
                .await
                .map_err(files_error)?;
            files.extend(
                found
                    .into_iter()
                    .filter(|file| file.name.ends_with(".jsonl"))
                    .map(|file| SessionFile {
                        path: format!("{rel}/{}", file.name),
                        size: file.size,
                        modified: file.modified,
                    }),
            );
        }
        files.sort_by_key(|file| std::cmp::Reverse(file.modified));
        Ok(files)
    }

    /// Reads the session files itself; `recent` keeps to the newest of
    /// the last [`RECENT_DAYS`], up to [`RECENT_BYTES`].
    async fn read_files(&mut self, recent: bool) -> Result<(), SessionError> {
        let mut files = self.session_files().await?;
        if recent {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            self.end.older_skipped = keep_recent(&mut files, now);
        }
        let total: u64 = files.iter().map(|file| file.size).sum();
        let mut done = 0;
        self.sink.progress(0, total);
        for file in files {
            if self.done() {
                // Files left unread.
                self.end.truncated |= !self.stopped();
                break;
            }
            let (hits, cut) = self.read_file(&file, done, total).await?;
            self.end.truncated |= cut;
            done += file.size;
            self.sink.progress(done, total);
            self.report(&file.path, file.size, hits).await;
        }
        Ok(())
    }

    /// The hits of one file, read in steps of [`SCAN_CHUNK`]; at most
    /// [`claude::HOST_HITS_PER_FILE`] lines, like grep on the host, and
    /// whether the file had more. Progress counts on from `done` bytes of
    /// `total`.
    async fn read_file(
        &self,
        file: &SessionFile,
        done: u64,
        total: u64,
    ) -> Result<(Vec<claude::Hit>, bool), SessionError> {
        let mut scan = LineScan::new(&file.path);
        let mut pos = 0;
        while pos < file.size && !scan.cut {
            if self.stopped() {
                break;
            }
            let data = self
                .conn
                .read_file_range(&file.path, pos, SCAN_CHUNK.min(file.size - pos))
                .await
                .map_err(files_error)?;
            if data.is_empty() {
                break;
            }
            scan.feed(pos, &data, &self.query);
            pos += data.len() as u64;
            self.sink.progress(done + pos, total);
        }
        // The rest is a line still being written.
        Ok((scan.hits, scan.cut))
    }

    /// Runs [`claude::search_script`] in a tab of `space` and reads the
    /// lines it found.
    async fn on_host(&mut self, space: &str) -> Result<(), SessionError> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        let stamp = format!("search-{}-{:09}", now.as_secs(), now.subsec_nanos());
        let name = |suffix: &str| format!("{stamp}{suffix}");
        let rel = |suffix: &str| format!("{UPLOAD_DIR}/{stamp}{suffix}");
        let (out, pattern, progress, total) = (
            rel(".txt"),
            rel(".pattern"),
            rel(".progress"),
            rel(".total"),
        );
        let temp: Vec<String> = [
            ".sh",
            ".pattern",
            ".progress",
            ".total",
            ".txt",
            ".txt.list",
            ".txt.head",
            ".txt.done",
        ]
        .iter()
        .map(|suffix| rel(suffix))
        .collect();

        let result = async {
            // The text goes in a file, never into the script or the shell.
            self.conn
                .upload(
                    UPLOAD_DIR,
                    &name(".pattern"),
                    format!("{}\n", self.query.json()).as_bytes(),
                )
                .await
                .map_err(files_error)?;
            let script = self
                .conn
                .upload(
                    UPLOAD_DIR,
                    &name(".sh"),
                    claude::search_script(&pattern, &out, &progress, &total).as_bytes(),
                )
                .await
                .map_err(files_error)?;
            // A leading space keeps it out of the shell's history where the
            // shell honours that.
            let tab = run_in_tab(
                &self.conn,
                space,
                &self.home,
                &format!(" sh '{script}'; exit"),
            )
            .await?;
            let finished = self.wait_for_host(&stamp).await;
            // The shell exits by itself; close the tab in case it stayed,
            // and to end the search when it was cancelled.
            let _ = actions::close_tab(&self.conn, &tab).await;
            if !finished? {
                return Ok(());
            }
            let data = self
                .conn
                .read_file_range(&format!("{out}.done"), 0, MAX_RESULT_BYTES)
                .await
                .map_err(files_error)?;
            let mut lines = claude::parse_search_output(&String::from_utf8_lossy(&data));
            if lines.len() > claude::HOST_MAX_LINES {
                lines.truncate(claude::HOST_MAX_LINES);
                self.end.truncated = true;
            }
            // The script reports one line more per file than it keeps.
            let mut per_file: HashMap<String, usize> = HashMap::new();
            let all = lines.len();
            lines.retain(|(path, _)| {
                let count = per_file.entry(path.clone()).or_default();
                *count += 1;
                *count <= claude::HOST_HITS_PER_FILE
            });
            self.end.truncated |= lines.len() < all;
            self.read_host_hits(lines).await
        }
        .await;
        if self.stopped() || result.is_err() {
            // The shell of a tab closed early may write a last byte of
            // progress.
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        for file in &temp {
            let _ = self.conn.remove_file(file).await;
        }
        result
    }

    /// Waits for the host's search `stamp` to leave its result in the
    /// uploads folder, reporting progress; false when cancelled first.
    async fn wait_for_host(&mut self, stamp: &str) -> Result<bool, SessionError> {
        let deadline = tokio::time::Instant::now() + HOST_DEADLINE;
        let done = format!("{stamp}.txt.done");
        let progress_name = format!("{stamp}.progress");
        let total_name = format!("{stamp}.total");
        let mut total = None;
        loop {
            if self.stopped() {
                return Ok(false);
            }
            let files = self
                .conn
                .list_files(UPLOAD_DIR)
                .await
                .map_err(files_error)?;
            if files.iter().any(|file| file.name == done) {
                return Ok(true);
            }
            if total.is_none() && files.iter().any(|f| f.name == total_name && f.size > 0) {
                let text = self
                    .conn
                    .read_file_range(&format!("{UPLOAD_DIR}/{total_name}"), 0, 64)
                    .await
                    .map_err(files_error)?;
                total = String::from_utf8_lossy(&text).trim().parse::<u64>().ok();
            }
            if let Some(total) = total {
                let searched = files
                    .iter()
                    .find(|file| file.name == progress_name)
                    .map_or(0, |file| file.size);
                self.sink.progress(searched, total);
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(SessionError::Files(
                    "the search on the host did not finish in time".into(),
                ));
            }
            tokio::select! {
                () = tokio::time::sleep(POLL) => {}
                _ = self.stop.wait_for(|stopped| *stopped) => return Ok(false),
            }
        }
    }

    /// Reads the lines the host found and reports their hits, file by file.
    async fn read_host_hits(&mut self, lines: Vec<(String, u64)>) -> Result<(), SessionError> {
        let total = lines.len() as u64;
        // File sizes per project folder, for the titles.
        let mut sizes: HashMap<String, HashMap<String, u64>> = HashMap::new();
        let mut current: Option<String> = None;
        let mut hits = Vec::new();
        for (index, (path, offset)) in lines.into_iter().enumerate() {
            if self.done() {
                // Lines left unread.
                self.end.truncated |= !self.stopped();
                break;
            }
            if current.as_deref() != Some(&path) {
                if let Some(previous) = current.take() {
                    let size = self.size_of(&mut sizes, &previous).await;
                    self.report(&previous, size, std::mem::take(&mut hits))
                        .await;
                }
                current = Some(path.clone());
            }
            if let Some(line) = claude::read_hit_line(&self.conn, &path, offset).await? {
                hits.extend(claude::hits_in_line(&path, &line, offset, &self.query));
            }
            self.sink.progress(index as u64 + 1, total);
        }
        if let Some(previous) = current {
            let size = self.size_of(&mut sizes, &previous).await;
            self.report(&previous, size, hits).await;
        }
        Ok(())
    }

    /// The size of the session file `path`, from a listing of its folder.
    async fn size_of(&self, sizes: &mut HashMap<String, HashMap<String, u64>>, path: &str) -> u64 {
        let (dir, name) = path.rsplit_once('/').unwrap_or(("", path));
        if !sizes.contains_key(dir) {
            let files = self
                .conn
                .list_files_if_present(dir)
                .await
                .unwrap_or_default()
                .into_iter()
                .map(|file| (file.name, file.size))
                .collect();
            sizes.insert(dir.to_owned(), files);
        }
        sizes
            .get(dir)
            .and_then(|files| files.get(name))
            .copied()
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::{LineScan, RECENT_BYTES, SessionFile, keep_recent, space_of};
    use herdr_core::claude::{self, Query};

    fn line(text: &str) -> Vec<u8> {
        format!(
            "{}\n",
            serde_json::json!({"type": "user", "message": {"content": text}})
        )
        .into_bytes()
    }

    /// Feeds `data` in pieces of `step` bytes.
    fn scan(data: &[u8], step: usize) -> (Vec<u64>, bool) {
        let query = Query::new("treffer").expect("query");
        let mut scan = LineScan::new("s.jsonl");
        for (index, piece) in data.chunks(step).enumerate() {
            scan.feed((index * step) as u64, piece, &query);
            if scan.cut {
                break;
            }
        }
        (scan.hits.iter().map(|hit| hit.offset).collect(), scan.cut)
    }

    #[test]
    fn scanning_in_pieces_keeps_line_offsets() {
        let mut data = line("nichts");
        let first = data.len() as u64;
        data.extend(line("ein Treffer"));
        let second = data.len() as u64;
        data.extend(line("noch ein TREFFER"));
        // A last line still being written does not count.
        data.extend_from_slice(br#"{"type":"user","message":{"content":"treffer"#);
        for step in [1, 7, 64, data.len()] {
            assert_eq!(
                scan(&data, step),
                (vec![first, second], false),
                "step {step}"
            );
        }
    }

    #[test]
    fn scanning_skips_too_long_lines() {
        let long = "x".repeat(claude::MAX_HIT_LINE as usize + 10);
        let mut data = line(&format!("treffer {long}"));
        let after = data.len() as u64;
        data.extend(line("treffer danach"));
        // Whole in one piece, and across pieces smaller than the line.
        for step in [data.len(), 300_000] {
            assert_eq!(scan(&data, step), (vec![after], false), "step {step}");
        }
    }

    #[test]
    fn scanning_stops_after_the_lines_per_file() {
        let data: Vec<u8> = (0..=claude::HOST_HITS_PER_FILE)
            .flat_map(|i| line(&format!("treffer {i}")))
            .collect();
        let (hits, cut) = scan(&data, 100);
        assert_eq!(hits.len(), claude::HOST_HITS_PER_FILE);
        assert!(cut);
    }

    #[test]
    fn recent_files_by_age_and_size() {
        let day = 24 * 60 * 60;
        let now = 100 * day;
        let file = |name: &str, size, age| SessionFile {
            path: name.to_owned(),
            size,
            modified: now - age * day,
        };
        let mut files = vec![
            file("a", RECENT_BYTES / 2, 0),
            file("b", RECENT_BYTES / 2 + 1, 1),
            file("c", 10, 2),
            file("d", 10, 31),
        ];
        assert!(keep_recent(&mut files, now));
        let kept: Vec<_> = files.iter().map(|file| file.path.as_str()).collect();
        assert_eq!(kept, ["a", "c"]);
        let mut files = vec![file("a", 10, 0)];
        assert!(!keep_recent(&mut files, now));
    }

    #[test]
    fn a_conversation_belongs_to_the_closest_space() {
        let spaces = [
            ("home".to_owned(), "/Users/me".to_owned()),
            ("shop".to_owned(), "/Users/me/dev/shop".to_owned()),
            (
                "wt".to_owned(),
                "/Users/me/dev/shop/.worktrees/x".to_owned(),
            ),
        ];
        let space = |cwd| space_of(&spaces, cwd, "/Users/me");
        assert_eq!(space("/Users/me/dev/shop").as_deref(), Some("shop"));
        assert_eq!(space("/Users/me/dev/shop/src").as_deref(), Some("shop"));
        assert_eq!(
            space("/Users/me/dev/shop/.worktrees/x/a").as_deref(),
            Some("wt")
        );
        assert_eq!(space("/Users/me").as_deref(), Some("home"));
        // Not below a space; the home directory does not count.
        assert_eq!(space("/Users/me/dev/shopping"), None);
        assert_eq!(space("/Users/me/notes"), None);
    }
}
