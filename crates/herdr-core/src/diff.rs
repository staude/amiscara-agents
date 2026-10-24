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
    pub additions: u32,
    pub deletions: u32,
    pub hunks: Vec<DiffHunk>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffFileStatus {
    Modified,
    Added,
    Deleted,
    Renamed,
    /// Not tracked by Git yet.
    Untracked,
    /// Binary content; no hunks.
    Binary,
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
    format!(
        r#"#!/bin/sh
# Amiscara Agents: the diff of this directory for the app (read only).
export GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat LC_ALL=C
out="$(dirname "$0")/{out}"
{{
  if git rev-parse --verify -q HEAD >/dev/null; then
    git -c core.quotepath=off diff --no-color --no-ext-diff --no-textconv HEAD --
  else
    git -c core.quotepath=off diff --no-color --no-ext-diff --no-textconv --cached --
  fi
  echo '{mark}'
  git -c core.quotepath=off ls-files --others --exclude-standard | head -n {max} | while IFS= read -r f; do
    size=$(wc -c < "$f" 2>/dev/null || echo 0)
    if [ "$size" -le {bytes} ]; then
      git -c core.quotepath=off diff --no-color --no-ext-diff --no-index -- /dev/null "$f"
    else
      printf 'diff --git a/%s b/%s\nnew file mode 100644\nBinary files /dev/null and b/%s differ\n' "$f" "$f" "$f"
    fi
  done
}} >"$out" 2>"$out.err"
mv "$out" "$out.done"
"#,
        mark = UNTRACKED_MARK,
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
            file.old_path = Some(from.to_owned());
        } else if let Some(to) = line.strip_prefix("rename to ") {
            file.path = to.to_owned();
        } else if line.starts_with("Binary files ") || line == "GIT binary patch" {
            file.status = DiffFileStatus::Binary;
        }
    }
    files
}

/// `a/x b/y` from a `diff --git` line. Paths with spaces are ambiguous
/// there; when both halves are equal (no rename) the split is exact.
fn split_git_paths(rest: &str) -> (String, String) {
    let rest = rest.trim();
    // Equal halves: "a/<p> b/<p>".
    if let Some(stripped) = rest.strip_prefix("a/") {
        let len = stripped.len();
        if len > 3 && (len - 3) % 2 == 0 {
            let half = (len - 3) / 2;
            let (left, right) = stripped.split_at(half);
            if let Some(right) = right.strip_prefix(" b/")
                && left == right
            {
                return (left.to_owned(), right.to_owned());
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

        assert_eq!(files[3].status, DiffFileStatus::Binary);
        assert!(files[3].hunks.is_empty());

        let notes = &files[4];
        assert_eq!(notes.status, DiffFileStatus::Untracked);
        assert_eq!(notes.path, "notes with space.md");
        assert_eq!(notes.old_path, None);
        assert_eq!(notes.additions, 2);
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
        assert!(script.contains("GIT_OPTIONAL_LOCKS=0"));
        assert!(script.contains("mv \"$out\" \"$out.done\""));
        assert!(script.contains(UNTRACKED_MARK));
    }
}
