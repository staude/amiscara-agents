//! Token usage of Claude Code (#302), from the same session files as the
//! conversation ([`crate::claude`]). Every assistant line carries the usage
//! of its request (input, output, cache tokens, model); one message is
//! written on several lines with the same usage, so a record counts once
//! per `message.id` and `requestId`, also over files.
//!
//! The files are large, so [`UsageCache`] remembers how far each file was
//! read and keeps hourly sums; a later [`scan`] reads only what was
//! appended. Hours in UTC: the app groups them by its own time zone.
//! Nothing is written on the host.

use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use herdr_transport::Connection;

use crate::claude::{self, ClaudeError};

/// How long sums and counted records are kept: a 30-day history plus the
/// day it starts in.
pub const KEEP_MS: u64 = 31 * 24 * HOUR_MS;
const HOUR_MS: u64 = 3_600_000;

/// Tokens of one or more requests.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tokens {
    pub input: u64,
    pub output: u64,
    /// Written to the prompt cache for five minutes.
    pub cache_write_5m: u64,
    /// Written to the prompt cache for an hour.
    pub cache_write_1h: u64,
    pub cache_read: u64,
}

impl Tokens {
    fn add(&mut self, other: &Self) {
        self.input += other.input;
        self.output += other.output;
        self.cache_write_5m += other.cache_write_5m;
        self.cache_write_1h += other.cache_write_1h;
        self.cache_read += other.cache_read;
    }

    pub fn total(&self) -> u64 {
        self.input + self.output + self.cache_write_5m + self.cache_write_1h + self.cache_read
    }
}

/// The tokens of one model in one hour.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bucket {
    /// Start of the hour (UTC) in Unix milliseconds.
    pub hour_start_ms: u64,
    pub model: String,
    pub tokens: Tokens,
}

/// How far a session file was read.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
struct FileMark {
    /// Behind the last complete line counted.
    offset: u64,
    /// Seconds since 1970, as listed when it was read.
    modified: u64,
}

/// What was read of the session files of one project folder. Kept by the
/// app between runs as JSON (`serde`), so a restart reads only the new
/// lines.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UsageCache {
    /// By path below the home directory.
    files: HashMap<String, FileMark>,
    /// Keys of the counted records with their hour, for dropping them
    /// together with the sums.
    seen: HashMap<String, u64>,
    /// Hour start in ms, then model.
    sums: BTreeMap<u64, BTreeMap<String, Tokens>>,
}

impl UsageCache {
    /// Counts the records among the complete lines of `data` that are not
    /// older than `cutoff_ms` and returns how many bytes that was: up to
    /// and including the last newline. A last line without one is still
    /// being written and left for later.
    pub fn ingest(&mut self, data: &[u8], cutoff_ms: u64) -> usize {
        let Some(end) = data.iter().rposition(|&b| b == b'\n') else {
            return 0;
        };
        for line in data[..end]
            .split(|&b| b == b'\n')
            .filter(|line| !line.is_empty())
        {
            // A broken line is skipped like any other that is no record.
            if let Ok(value) = serde_json::from_slice::<Value>(line) {
                self.record(&value, cutoff_ms);
            }
        }
        end + 1
    }

    fn record(&mut self, line: &Value, cutoff_ms: u64) {
        if line["type"].as_str() != Some("assistant") {
            return;
        }
        let message = &line["message"];
        let usage = &message["usage"];
        let Some(model) = message["model"].as_str() else {
            return;
        };
        // Claude Code's own notices (API errors and the like) cost nothing.
        if !usage.is_object() || model == "<synthetic>" {
            return;
        }
        let Some(hour) = line["timestamp"].as_str().and_then(hour_start_ms) else {
            return;
        };
        if hour < cutoff_ms {
            return;
        }
        let key = match (message["id"].as_str(), line["requestId"].as_str()) {
            (None, None) => match line["uuid"].as_str() {
                Some(uuid) => uuid.to_owned(),
                None => return,
            },
            (id, request) => format!("{}:{}", id.unwrap_or(""), request.unwrap_or("")),
        };
        if self.seen.insert(key, hour).is_some() {
            return;
        }
        let count = |value: &Value| value.as_u64().unwrap_or(0);
        // Older versions only give the sum, which was the five-minute cache.
        let split = &usage["cache_creation"];
        let (cache_write_5m, cache_write_1h) = if split.is_object() {
            (
                count(&split["ephemeral_5m_input_tokens"]),
                count(&split["ephemeral_1h_input_tokens"]),
            )
        } else {
            (count(&usage["cache_creation_input_tokens"]), 0)
        };
        let tokens = Tokens {
            input: count(&usage["input_tokens"]),
            output: count(&usage["output_tokens"]),
            cache_write_5m,
            cache_write_1h,
            cache_read: count(&usage["cache_read_input_tokens"]),
        };
        self.sums
            .entry(hour)
            .or_default()
            .entry(model.to_owned())
            .or_default()
            .add(&tokens);
    }

    /// Drops sums, records and files older than `cutoff_ms`.
    pub fn prune(&mut self, cutoff_ms: u64) {
        self.sums = self.sums.split_off(&cutoff_ms);
        self.seen.retain(|_, hour| *hour >= cutoff_ms);
        self.files
            .retain(|_, mark| mark.modified.saturating_mul(1000) >= cutoff_ms);
    }

    /// The sums of the hours that end after `since_ms`, oldest first.
    pub fn buckets_since(&self, since_ms: u64) -> Vec<Bucket> {
        self.sums
            .range(since_ms.saturating_sub(HOUR_MS - 1)..)
            .flat_map(|(hour, models)| {
                models.iter().map(|(model, tokens)| Bucket {
                    hour_start_ms: *hour,
                    model: model.clone(),
                    tokens: *tokens,
                })
            })
            .collect()
    }
}

/// Reads what is new in the session files of `cwd` into `cache`: the
/// sessions in Claude Code's project folder and their subagents, each file
/// only when it changed since `since_secs` (seconds since 1970) and only
/// from where the last scan stopped. A missing folder adds nothing.
/// `now_ms` drops what is older than [`KEEP_MS`]. A transport error ends
/// the scan; what was read until then stays counted.
pub async fn scan(
    conn: &Connection,
    cwd: &str,
    cache: &mut UsageCache,
    since_secs: u64,
    now_ms: u64,
) -> Result<(), ClaudeError> {
    let cutoff = now_ms.saturating_sub(KEEP_MS);
    cache.prune(cutoff);
    let dir = claude::project_dir(cwd);
    // 0 means unknown: such a file is read.
    let changed = |modified: u64| modified == 0 || modified >= since_secs;
    let mut files = Vec::new();
    for session in conn.list_files_if_present(&dir).await? {
        let Some(id) = session.name.strip_suffix(".jsonl") else {
            continue;
        };
        if !changed(session.modified) {
            continue;
        }
        let subagents = format!("{dir}/{id}/subagents");
        for file in conn.list_files_if_present(&subagents).await? {
            if file.name.ends_with(".jsonl") && changed(file.modified) {
                files.push((format!("{subagents}/{}", file.name), file));
            }
        }
        files.push((format!("{dir}/{}", session.name), session));
    }
    for (path, file) in files {
        read_new(conn, cache, &path, file.size, file.modified, cutoff).await?;
    }
    Ok(())
}

/// Counts the lines of `path` from its mark to `size`, a step at a time.
async fn read_new(
    conn: &Connection,
    cache: &mut UsageCache,
    path: &str,
    size: u64,
    modified: u64,
    cutoff_ms: u64,
) -> Result<(), ClaudeError> {
    let mut offset = cache.files.get(path).map_or(0, |mark| mark.offset);
    // Shorter than read: a new file under the old name. The keys keep
    // records seen before from counting twice.
    if size < offset {
        offset = 0;
    }
    let mut pending = Vec::new();
    let mut pos = offset;
    while pos < size {
        let data = conn
            .read_file_range(path, pos, claude::STEP_BYTES.min(size - pos))
            .await?;
        if data.is_empty() {
            break;
        }
        pos += data.len() as u64;
        pending.extend_from_slice(&data);
        let used = cache.ingest(&pending, cutoff_ms);
        pending.drain(..used);
        offset += used as u64;
        cache
            .files
            .insert(path.to_owned(), FileMark { offset, modified });
    }
    cache
        .files
        .insert(path.to_owned(), FileMark { offset, modified });
    Ok(())
}

/// Start of the hour of an ISO 8601 UTC time as Claude Code writes it
/// (`2026-10-24T20:44:04.386Z`), in Unix milliseconds.
fn hour_start_ms(timestamp: &str) -> Option<u64> {
    let bytes = timestamp.as_bytes();
    if bytes.len() < 20
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || !timestamp.ends_with('Z')
    {
        return None;
    }
    let number = |from: usize, to: usize| timestamp.get(from..to)?.parse::<u64>().ok();
    let (year, month, day, hour) = (
        number(0, 4)?,
        number(5, 7)?,
        number(8, 10)?,
        number(11, 13)?,
    );
    if year < 1970 || !(1..=12).contains(&month) || !(1..=31).contains(&day) || hour > 23 {
        return None;
    }
    // Days since 1970 of a civil date (Howard Hinnant's algorithm).
    let (y, m) = if month <= 2 {
        (year - 1, month + 9)
    } else {
        (year, month - 3)
    };
    let era = y / 400;
    let year_of_era = y - era * 400;
    let day_of_year = (153 * m + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = (era * 146_097 + day_of_era).checked_sub(719_468)?;
    Some((days * 24 + hour) * HOUR_MS)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn lines(values: &[Value]) -> Vec<u8> {
        values
            .iter()
            .flat_map(|v| format!("{v}\n").into_bytes())
            .collect()
    }

    fn assistant(id: &str, request: &str, timestamp: &str, usage: Value) -> Value {
        json!({
            "type": "assistant",
            "requestId": request,
            "timestamp": timestamp,
            "message": {"id": id, "model": "claude-opus-5-5", "usage": usage},
        })
    }

    fn usage() -> Value {
        json!({
            "input_tokens": 2,
            "output_tokens": 600,
            "cache_read_input_tokens": 28_000,
            "cache_creation_input_tokens": 31_000,
            "cache_creation": {"ephemeral_5m_input_tokens": 1_000, "ephemeral_1h_input_tokens": 30_000},
        })
    }

    #[test]
    fn hours_in_utc() {
        assert_eq!(hour_start_ms("1970-01-01T00:59:59.999Z"), Some(0));
        // 2026-10-24 is day 20_750 since 1970.
        assert_eq!(
            hour_start_ms("2026-10-24T20:44:04.386Z"),
            Some((20_750 * 24 + 20) * HOUR_MS)
        );
        assert_eq!(
            hour_start_ms("2024-03-01T00:00:00Z"),
            Some(19_783 * 24 * HOUR_MS)
        );
        assert_eq!(hour_start_ms("2026-10-24T20:44:04+02:00"), None);
        assert_eq!(hour_start_ms("gestern"), None);
    }

    #[test]
    fn a_message_on_several_lines_counts_once() {
        let mut cache = UsageCache::default();
        let line = assistant("msg_1", "req_1", "2026-10-24T20:44:04.386Z", usage());
        let data = lines(&[
            line.clone(),
            line.clone(),
            json!({"type": "user", "message": {"content": "weiter"}}),
            assistant("msg_2", "req_2", "2026-10-24T21:01:00.000Z", usage()),
        ]);
        assert_eq!(cache.ingest(&data, 0), data.len());
        // Again in another file, e.g. after a resumed session.
        cache.ingest(&lines(&[line]), 0);
        let buckets = cache.buckets_since(0);
        assert_eq!(buckets.len(), 2);
        assert_eq!(
            buckets[0].tokens,
            Tokens {
                input: 2,
                output: 600,
                cache_write_5m: 1_000,
                cache_write_1h: 30_000,
                cache_read: 28_000,
            }
        );
        assert_eq!(buckets[0].model, "claude-opus-5-5");
        assert_eq!(buckets[1].hour_start_ms - buckets[0].hour_start_ms, HOUR_MS);
    }

    #[test]
    fn unfinished_last_line_is_left_for_later() {
        let mut cache = UsageCache::default();
        let mut data = lines(&[assistant("msg_1", "req_1", "2026-10-24T20:44:04Z", usage())]);
        let complete = data.len();
        data.extend_from_slice(br#"{"type":"assistant","message":{"id":"msg_2""#);
        assert_eq!(cache.ingest(&data, 0), complete);
        assert_eq!(cache.buckets_since(0).len(), 1);
        assert_eq!(cache.ingest(br#"{"type":"assistant""#, 0), 0);
    }

    #[test]
    fn without_split_the_cache_write_is_five_minutes() {
        let mut cache = UsageCache::default();
        let data = lines(&[assistant(
            "msg_1",
            "req_1",
            "2026-10-24T20:44:04Z",
            json!({"input_tokens": 10, "output_tokens": 20, "cache_creation_input_tokens": 300}),
        )]);
        cache.ingest(&data, 0);
        let tokens = cache.buckets_since(0)[0].tokens;
        assert_eq!((tokens.cache_write_5m, tokens.cache_write_1h), (300, 0));
        assert_eq!(tokens.total(), 330);
    }

    #[test]
    fn synthetic_broken_and_old_lines_are_skipped() {
        let mut cache = UsageCache::default();
        let mut synthetic = assistant("msg_1", "req_1", "2026-10-24T20:44:04Z", usage());
        synthetic["message"]["model"] = json!("<synthetic>");
        let mut data = lines(&[
            synthetic,
            assistant("msg_2", "req_2", "2026-09-01T10:00:00Z", usage()),
            json!({"type": "assistant", "message": {"id": "msg_3", "model": "claude-opus-5-5"}}),
        ]);
        data.extend_from_slice(b"{kaputt\n");
        let cutoff = hour_start_ms("2026-10-01T00:00:00Z").expect("time");
        assert_eq!(cache.ingest(&data, cutoff), data.len());
        assert!(cache.buckets_since(0).is_empty());
    }

    #[test]
    fn prune_drops_old_hours_and_keys() {
        let mut cache = UsageCache::default();
        let data = lines(&[
            assistant("msg_1", "req_1", "2026-09-01T10:00:00Z", usage()),
            assistant("msg_2", "req_2", "2026-10-24T10:00:00Z", usage()),
        ]);
        cache.ingest(&data, 0);
        let cutoff = hour_start_ms("2026-10-01T00:00:00Z").expect("time");
        cache.prune(cutoff);
        assert_eq!(cache.buckets_since(0).len(), 1);
        assert_eq!(cache.seen.len(), 1);
        // The state survives JSON, the app's store.
        let back: UsageCache =
            serde_json::from_str(&serde_json::to_string(&cache).expect("json")).expect("parse");
        assert_eq!(back.buckets_since(0), cache.buckets_since(0));
    }

    #[test]
    fn buckets_since_includes_the_running_hour() {
        let mut cache = UsageCache::default();
        cache.ingest(
            &lines(&[assistant("msg_1", "req_1", "2026-10-24T20:44:04Z", usage())]),
            0,
        );
        let hour = hour_start_ms("2026-10-24T20:00:00Z").expect("time");
        assert_eq!(cache.buckets_since(hour + 30 * 60_000).len(), 1);
        assert!(cache.buckets_since(hour + HOUR_MS).is_empty());
    }
}
