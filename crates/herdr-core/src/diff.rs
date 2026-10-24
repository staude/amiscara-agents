//! What an agent changed in its working directory (#228): the output of
//! `git diff` against `HEAD`, plus untracked files, read into files and
//! hunks. herdr has no method for it and the device keys reach no shell, so
//! the session runs a small script in a short-lived tab (see
//! [`diff_script`]) and reads its output through SFTP.

/// One file of a diff.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffFile {
    /// The path after the change (before it for a deleted file).
    pub path: String,
    /// The path before a rename.
    pub old_path: Option<String>,
    pub status: DiffFileStatus,
    /// Binary content; no hunks.
    pub binary: bool,
    /// An untracked file too big to show; no hunks.
    pub too_large: bool,
    pub additions: u32,
    pub deletions: u32,
    pub hunks: Vec<DiffHunk>,
}

/// A working tree diff; `truncated` when it was cut off at the size the
/// apps read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkingTreeDiff {
    pub files: Vec<DiffFile>,
    pub truncated: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffFileStatus {
    Modified,
    Added,
    Deleted,
    Renamed,
    /// Not tracked by Git yet.
    Untracked,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffHunk {
    /// The `@@ -a,b +c,d @@ context` line.
    pub header: String,
    pub lines: Vec<DiffLine>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffLine {
    pub kind: DiffLineKind,
    /// The line without its `+`, `-` or ` ` prefix.
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffLineKind {
    Context,
    Added,
    Removed,
    /// `\ No newline at end of file`.
    Note,
}

/// Marks the start of the untracked files' diffs in the script's output.
pub const UNTRACKED_MARK: &str = "#amiscara-untracked";
/// An untracked file over the size limit: the mark, a space, its path.
pub const TOO_LARGE_MARK: &str = "#amiscara-too-large";

/// Untracked files the script includes at most, and their size limit.
pub const MAX_UNTRACKED: usize = 50;
pub const MAX_UNTRACKED_BYTES: u64 = 200_000;

/// A POSIX shell script that writes the diff of the current directory to
/// the file `out` next to the script and renames it to `out` + `.done`
/// when complete, errors to `out` + `.err`. Next to the script rather than
/// below `$HOME`: the app's home can differ from the shell's (the iOS
/// simulator on a local socket). Read only: `GIT_OPTIONAL_LOCKS=0`
/// keeps Git from refreshing the index, nothing else is written but those
/// files.
pub fn diff_script(out: &str) -> String {
    let out = out.rsplit('/').next().unwrap_or(out);
    // Fixed prefixes: `diff.mnemonicPrefix` or `diff.noprefix` in the
    // user's config would change them. From the repository's top, so
    // tracked and untracked paths are relative to the same place. A
    // subshell, so `exit` outside a repository still leaves `.done`.
    format!(
        r#"#!/bin/sh
# Amiscara Agents: the diff of this directory for the app (read only).
export GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat LC_ALL=C
out="$(dirname "$0")/{out}"
(
  top=$(git rev-parse --show-toplevel) && cd "$top" || exit 1
  set -- -c core.quotepath=off diff --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/
  if git rev-parse --verify -q HEAD >/dev/null; then
    git "$@" HEAD --
  else
    git "$@" --cached --
  fi
  echo '{mark}'
  git ls-files -z --others --exclude-standard | tr '\000' '\n' | head -n {max} | while IFS= read -r f; do
    size=$(wc -c < "$f" 2>/dev/null || echo 0)
    if [ "$size" -le {bytes} ]; then
      git "$@" --no-index -- /dev/null "$f"
    else
      printf '%s %s\n' '{large}' "$f"
    fi
  done
) >"$out" 2>"$out.err"
mv "$out" "$out.done"
"#,
        mark = UNTRACKED_MARK,
        large = TOO_LARGE_MARK,
        max = MAX_UNTRACKED,
        bytes = MAX_UNTRACKED_BYTES,
    )
}

/// Reads the script's output into files. Files after [`UNTRACKED_MARK`]
/// count as untracked.
pub fn parse(output: &str) -> Vec<DiffFile> {
    let mut files: Vec<DiffFile> = Vec::new();
    let mut untracked = false;
    let mut in_hunk = false;
    for line in output.lines() {
        if line == UNTRACKED_MARK {
            untracked = true;
            in_hunk = false;
            continue;
        }
        if let Some(path) = line
            .strip_prefix(TOO_LARGE_MARK)
            .and_then(|rest| rest.strip_prefix(' '))
        {
            files.push(DiffFile {
                path: path.to_owned(),
                old_path: None,
                status: DiffFileStatus::Untracked,
                binary: false,
                too_large: true,
                additions: 0,
                deletions: 0,
                hunks: Vec::new(),
            });
            in_hunk = false;
            continue;
        }
        if let Some(rest) = line.strip_prefix("diff --git ") {
            let (old, new) = split_git_paths(rest);
            files.push(DiffFile {
                path: new.clone(),
                old_path: (old != new).then_some(old),
                status: if untracked {
                    DiffFileStatus::Untracked
                } else {
                    DiffFileStatus::Modified
                },
                binary: false,
                too_large: false,
                additions: 0,
                deletions: 0,
                hunks: Vec::new(),
            });
            in_hunk = false;
            continue;
        }
        let Some(file) = files.last_mut() else {
            continue;
        };
        if line.starts_with("@@") {
            file.hunks.push(DiffHunk {
                header: line.to_owned(),
                lines: Vec::new(),
            });
            in_hunk = true;
            continue;
        }
        if in_hunk {
            let Some(hunk) = file.hunks.last_mut() else {
                continue;
            };
            let (kind, text) = match line.chars().next() {
                Some('+') => (DiffLineKind::Added, &line[1..]),
                Some('-') => (DiffLineKind::Removed, &line[1..]),
                Some(' ') => (DiffLineKind::Context, &line[1..]),
                Some('\\') => (DiffLineKind::Note, line),
                // An empty context line some tools write without its space.
                None => (DiffLineKind::Context, ""),
                _ => {
                    in_hunk = false;
                    continue;
                }
            };
            match kind {
                DiffLineKind::Added => file.additions += 1,
                DiffLineKind::Removed => file.deletions += 1,
                _ => {}
            }
            hunk.lines.push(DiffLine {
                kind,
                text: text.to_owned(),
            });
            continue;
        }
        // Header lines between `diff --git` and the first hunk.
        if line.starts_with("new file mode") && file.status != DiffFileStatus::Untracked {
            file.status = DiffFileStatus::Added;
        } else if line.starts_with("deleted file mode") {
            file.status = DiffFileStatus::Deleted;
        } else if let Some(from) = line.strip_prefix("rename from ") {
            file.status = DiffFileStatus::Renamed;
            file.old_path = Some(unquote(from));
        } else if let Some(to) = line.strip_prefix("rename to ") {
            file.path = unquote(to);
        } else if line.starts_with("Binary files ") || line == "GIT binary patch" {
            file.binary = true;
        }
    }
    files
}

/// `a/x b/y` from a `diff --git` line. Paths with spaces are ambiguous
/// there; when both halves are equal (no rename) the split is exact.
/// Paths Git quotes (with `"`, `\` or control characters) come as C
/// strings: `"a/q\"uote" "b/q\"uote"`.
fn split_git_paths(rest: &str) -> (String, String) {
    let rest = rest.trim();
    if rest.starts_with('"') || rest.ends_with('"') {
        let (old, rest) = take_path(rest);
        let (new, _) = take_path(rest.trim_start());
        return (strip_side(&old, "a/"), strip_side(&new, "b/"));
    }
    // Equal halves: "a/<p> b/<p>".
    if let Some(stripped) = rest.strip_prefix("a/") {
        let len = stripped.len();
        if len > 3 && (len - 3) % 2 == 0 {
            let half = (len - 3) / 2;
            if stripped.is_char_boundary(half) {
                let (left, right) = stripped.split_at(half);
                if let Some(right) = right.strip_prefix(" b/")
                    && left == right
                {
                    return (left.to_owned(), right.to_owned());
                }
            }
        }
    }
    match rest.rsplit_once(" b/") {
        Some((old, new)) => (
            old.strip_prefix("a/").unwrap_or(old).to_owned(),
            new.to_owned(),
        ),
        None => (rest.to_owned(), rest.to_owned()),
    }
}

fn strip_side(path: &str, side: &str) -> String {
    path.strip_prefix(side).unwrap_or(path).to_owned()
}

/// One path from the start of `text`, quoted or up to the next space;
/// returns it and the rest.
fn take_path(text: &str) -> (String, &str) {
    if let Some(quoted) = text.strip_prefix('"') {
        let mut escaped = false;
        for (index, ch) in quoted.char_indices() {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                return (unquote(&text[..index + 2]), &quoted[index + 1..]);
            }
        }
        return (unquote(text), "");
    }
    match text.split_once(' ') {
        Some((path, rest)) => (path.to_owned(), rest),
        None => (text.to_owned(), ""),
    }
}

/// Undoes Git's C quoting of a path (`"a\tb\303\244"`); plain paths stay.
fn unquote(path: &str) -> String {
    let Some(inner) = path.strip_prefix('"').and_then(|p| p.strip_suffix('"')) else {
        return path.to_owned();
    };
    let mut bytes = Vec::with_capacity(inner.len());
    let mut chars = inner.bytes().peekable();
    while let Some(byte) = chars.next() {
        if byte != b'\\' {
            bytes.push(byte);
            continue;
        }
        match chars.next() {
            Some(b'n') => bytes.push(b'\n'),
            Some(b't') => bytes.push(b'\t'),
            Some(b'r') => bytes.push(b'\r'),
            Some(b'a') => bytes.push(0x07),
            Some(b'b') => bytes.push(0x08),
            Some(b'f') => bytes.push(0x0c),
            Some(b'v') => bytes.push(0x0b),
            Some(digit @ b'0'..=b'7') => {
                let mut value = u32::from(digit - b'0');
                for _ in 0..2 {
                    match chars.peek() {
                        Some(next @ b'0'..=b'7') => {
                            value = value * 8 + u32::from(next - b'0');
                            chars.next();
                        }
                        _ => break,
                    }
                }
                bytes.push(value as u8);
            }
            Some(other) => bytes.push(other),
            None => {}
        }
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "\
diff --git a/src/main.rs b/src/main.rs
index 1111111..2222222 100644
--- a/src/main.rs
+++ b/src/main.rs
@@ -1,3 +1,4 @@ fn main() {
 fn main() {
-    println!(\"hi\");
+    println!(\"hello\");
+    println!(\"world\");
 }
diff --git a/old name.txt b/new name.txt
similarity index 90%
rename from old name.txt
rename to new name.txt
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
index 3333333..0000000
--- a/gone.txt
+++ /dev/null
@@ -1 +0,0 @@
-bye
\\ No newline at end of file
diff --git a/logo.png b/logo.png
index 4444444..5555555 100644
Binary files a/logo.png and b/logo.png differ
#amiscara-untracked
diff --git a/notes with space.md b/notes with space.md
new file mode 100644
index 0000000..6666666
--- /dev/null
+++ b/notes with space.md
@@ -0,0 +1,2 @@
+# Notes
+
";

    #[test]
    fn reads_files_and_hunks() {
        let files = parse(SAMPLE);
        assert_eq!(files.len(), 5);

        let main = &files[0];
        assert_eq!(main.path, "src/main.rs");
        assert_eq!(main.status, DiffFileStatus::Modified);
        assert_eq!((main.additions, main.deletions), (2, 1));
        assert_eq!(main.hunks.len(), 1);
        assert_eq!(main.hunks[0].header, "@@ -1,3 +1,4 @@ fn main() {");
        assert_eq!(main.hunks[0].lines.len(), 5);
        assert_eq!(main.hunks[0].lines[1].kind, DiffLineKind::Removed);
        assert_eq!(main.hunks[0].lines[1].text, "    println!(\"hi\");");

        let renamed = &files[1];
        assert_eq!(renamed.status, DiffFileStatus::Renamed);
        assert_eq!(renamed.path, "new name.txt");
        assert_eq!(renamed.old_path.as_deref(), Some("old name.txt"));

        let gone = &files[2];
        assert_eq!(gone.status, DiffFileStatus::Deleted);
        assert_eq!(gone.deletions, 1);
        assert_eq!(gone.hunks[0].lines[1].kind, DiffLineKind::Note);

        assert!(files[3].binary);
        assert_eq!(files[3].status, DiffFileStatus::Modified);
        assert!(files[3].hunks.is_empty());

        let notes = &files[4];
        assert_eq!(notes.status, DiffFileStatus::Untracked);
        assert_eq!(notes.path, "notes with space.md");
        assert_eq!(notes.old_path, None);
        assert_eq!(notes.additions, 2);
    }

    #[test]
    fn quoted_paths_and_large_files() {
        let output = format!(
            "diff --git \"a/q\\\"uote.txt\" \"b/q\\\"uote.txt\"\nindex 1..2 100644\n@@ -1 +1 @@\n-a\n+b\n\
             diff --git a/\"tab\\there\" b/\"tab\\there\"\n\
             {UNTRACKED_MARK}\n{TOO_LARGE_MARK} big file.bin\n"
        );
        let files = parse(&output);
        assert_eq!(files[0].path, "q\"uote.txt");
        assert_eq!(files[0].old_path, None);
        assert_eq!((files[0].additions, files[0].deletions), (1, 1));
        assert_eq!(files[2].path, "big file.bin");
        assert!(files[2].too_large);
        assert_eq!(files[2].status, DiffFileStatus::Untracked);
        assert_eq!(unquote("\"\\303\\244\\tx\""), "ä\tx");
    }

    #[test]
    fn empty_output_is_no_change() {
        assert!(parse("").is_empty());
        assert!(parse(&format!("{UNTRACKED_MARK}\n")).is_empty());
    }

    #[test]
    fn script_writes_below_home_and_marks_completion() {
        let script = diff_script(".amiscara-agents/uploads/diff-1.txt");
        assert!(script.contains("out=\"$(dirname \"$0\")/diff-1.txt\""));
        assert!(script.contains("--src-prefix=a/ --dst-prefix=b/"));
        assert!(script.contains("--show-toplevel"));
        assert!(script.contains("GIT_OPTIONAL_LOCKS=0"));
        assert!(script.contains("mv \"$out\" \"$out.done\""));
        assert!(script.contains(UNTRACKED_MARK));
    }
}
