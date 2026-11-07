//! Git status of the worktree spaces on a host (#343): ahead/behind against
//! the upstream and the number of uncommitted changes. herdr reports only
//! the branch, so like [`crate::diff`] the session runs a small script (see
//! [`status_script`]) in a short-lived tab or, where herdr-core answers,
//! without one (#359) and reads its output through SFTP; one run covers
//! every worktree of the host.

/// Starts the lines of one directory: the mark, a space, its path.
pub const DIR_MARK: &str = "#amiscara-dir";
/// Ends the lines of a directory Git could read: the mark, a space, the
/// number of changed and untracked files.
pub const CHANGES_MARK: &str = "#amiscara-changes";

/// The status of one checkout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitStatus {
    pub path: String,
    /// The branch tracks an upstream branch; without one `ahead` and
    /// `behind` are 0.
    pub has_upstream: bool,
    /// Commits on the branch that are not on its upstream.
    pub ahead: u32,
    /// Commits on the upstream that are not on the branch.
    pub behind: u32,
    /// Changed, staged and untracked files (ignored ones not).
    pub changes: u32,
}

/// The status of the checkout a space shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpaceGitStatus {
    pub workspace_id: String,
    pub has_upstream: bool,
    pub ahead: u32,
    pub behind: u32,
    pub changes: u32,
}

impl SpaceGitStatus {
    pub fn new(workspace_id: impl Into<String>, status: &GitStatus) -> Self {
        Self {
            workspace_id: workspace_id.into(),
            has_upstream: status.has_upstream,
            ahead: status.ahead,
            behind: status.behind,
            changes: status.changes,
        }
    }
}

/// A POSIX shell script that writes the status of every directory in
/// `dirs` (absolute paths) to the file `out` next to the script and renames
/// it to `out` + `.done` when complete, errors to `out` + `.err`, like
/// [`crate::diff::diff_script`]. Read only: `GIT_OPTIONAL_LOCKS=0` keeps
/// Git from refreshing the index. A directory Git cannot read (gone, no
/// repository) gets only its [`DIR_MARK`] line.
pub fn status_script(out: &str, dirs: &[String]) -> String {
    let out = out.rsplit('/').next().unwrap_or(out);
    let dirs = if dirs.is_empty() {
        // `for d in ; do` is a syntax error.
        "''".to_owned()
    } else {
        dirs.iter()
            .map(|dir| crate::daily::quote(dir))
            .collect::<Vec<_>>()
            .join(" ")
    };
    format!(
        r#"#!/bin/sh
# Amiscara Agents: the Git status of the worktrees for the app (read only).
export GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat LC_ALL=C
out="$(dirname "$0")/{out}"
(
  for d in {dirs}; do
    [ -n "$d" ] || continue
    printf '%s %s\n' '{dir}' "$d"
    # Runs on its own in a terminal's folder (#359): no fsmonitor hook
    # from the repository's config.
    s=$(git -c core.fsmonitor=false -C "$d" status --porcelain=v2 --branch --untracked-files=normal 2>/dev/null) || continue
    printf '%s\n' "$s" | awk '
      /^# branch\.upstream / || /^# branch\.ab / {{ print; next }}
      /^#/ || NF == 0 {{ next }}
      {{ n++ }}
      END {{ print "{changes} " n + 0 }}'
  done
) >"$out" 2>"$out.err"
mv "$out" "$out.done"
"#,
        dir = DIR_MARK,
        changes = CHANGES_MARK,
    )
}

/// Reads the script's output: one entry per directory Git could read, in
/// the script's order.
pub fn parse_status(output: &str) -> Vec<GitStatus> {
    let mut found = Vec::new();
    let mut current: Option<GitStatus> = None;
    for line in output.lines() {
        if let Some(path) = line
            .strip_prefix(DIR_MARK)
            .and_then(|rest| rest.strip_prefix(' '))
        {
            current = Some(GitStatus {
                path: path.to_owned(),
                has_upstream: false,
                ahead: 0,
                behind: 0,
                changes: 0,
            });
            continue;
        }
        let Some(status) = current.as_mut() else {
            continue;
        };
        if line.starts_with("# branch.upstream ") {
            status.has_upstream = true;
        } else if let Some(rest) = line.strip_prefix("# branch.ab ") {
            // `+<ahead> -<behind>`.
            for part in rest.split_whitespace() {
                if let Some(n) = part.strip_prefix('+') {
                    status.ahead = n.parse().unwrap_or(0);
                } else if let Some(n) = part.strip_prefix('-') {
                    status.behind = n.parse().unwrap_or(0);
                }
            }
        } else if let Some(n) = line
            .strip_prefix(CHANGES_MARK)
            .and_then(|rest| rest.strip_prefix(' '))
        {
            status.changes = n.trim().parse().unwrap_or(0);
            found.extend(current.take());
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_upstream_ahead_behind_and_changes() {
        let output = "#amiscara-dir /x/repo\n\
            # branch.upstream origin/main\n\
            # branch.ab +3 -2\n\
            #amiscara-changes 4\n\
            #amiscara-dir /x/repo/.worktrees/new\n\
            #amiscara-changes 0\n";
        assert_eq!(
            parse_status(output),
            vec![
                GitStatus {
                    path: "/x/repo".into(),
                    has_upstream: true,
                    ahead: 3,
                    behind: 2,
                    changes: 4,
                },
                GitStatus {
                    path: "/x/repo/.worktrees/new".into(),
                    has_upstream: false,
                    ahead: 0,
                    behind: 0,
                    changes: 0,
                },
            ]
        );
    }

    #[test]
    fn a_gone_upstream_has_no_counts() {
        let output = "#amiscara-dir /x\n# branch.upstream origin/gone\n#amiscara-changes 1\n";
        let got = parse_status(output);
        assert_eq!(got.len(), 1);
        assert!(got[0].has_upstream);
        assert_eq!((got[0].ahead, got[0].behind, got[0].changes), (0, 0, 1));
    }

    #[test]
    fn a_directory_without_repository_is_left_out() {
        let output = "#amiscara-dir /gone\n#amiscara-dir /x y\n#amiscara-changes 2\n";
        let got = parse_status(output);
        assert_eq!(got.len(), 1);
        assert_eq!((got[0].path.as_str(), got[0].changes), ("/x y", 2));
    }

    /// Runs the script against real repositories: one with an upstream,
    /// a commit ahead and an untracked file, one clean without upstream,
    /// a folder outside Git.
    #[cfg(unix)]
    #[test]
    fn script_reads_real_repositories() -> std::io::Result<()> {
        use std::process::Command;
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("amiscara-git-status-{stamp}"));
        let git = |dir: &std::path::Path, args: &[&str]| -> std::io::Result<()> {
            let ok = Command::new("git")
                .args([
                    "-c",
                    "user.name=t",
                    "-c",
                    "user.email=t@t",
                    "-c",
                    "init.defaultBranch=main",
                ])
                .args(args)
                .current_dir(dir)
                .output()?
                .status
                .success();
            if ok {
                Ok(())
            } else {
                Err(std::io::Error::other(format!("git {args:?} failed")))
            }
        };
        let origin = root.join("origin");
        let work = root.join("work tree");
        let plain = root.join("plain");
        std::fs::create_dir_all(&origin)?;
        std::fs::create_dir_all(&plain)?;
        git(&origin, &["init", "-q", "--bare"])?;
        git(&root, &["clone", "-q", "origin", "work tree"])?;
        git(&work, &["commit", "-q", "--allow-empty", "-m", "one"])?;
        git(&work, &["push", "-q", "origin", "HEAD:main"])?;
        git(&work, &["branch", "-q", "--set-upstream-to=origin/main"])?;
        git(&work, &["commit", "-q", "--allow-empty", "-m", "two"])?;
        std::fs::write(work.join("new.txt"), "x")?;
        let solo = root.join("solo");
        std::fs::create_dir_all(&solo)?;
        git(&solo, &["init", "-q"])?;
        git(&solo, &["commit", "-q", "--allow-empty", "-m", "one"])?;

        let dirs: Vec<String> = [&work, &solo, &plain, &root.join("gone")]
            .iter()
            .map(|dir| dir.to_string_lossy().into_owned())
            .collect();
        let script = root.join("status.sh");
        std::fs::write(&script, status_script("out.txt", &dirs))?;
        let ran = Command::new("sh")
            .arg(&script)
            .current_dir(&plain)
            .status()?;
        let output = std::fs::read_to_string(root.join("out.txt.done"));
        let _ = std::fs::remove_dir_all(&root);
        assert!(ran.success());
        let got = parse_status(&output?);
        assert_eq!(
            got,
            vec![
                GitStatus {
                    path: dirs[0].clone(),
                    has_upstream: true,
                    ahead: 1,
                    behind: 0,
                    changes: 1,
                },
                GitStatus {
                    path: dirs[1].clone(),
                    has_upstream: false,
                    ahead: 0,
                    behind: 0,
                    changes: 0,
                },
            ]
        );
        Ok(())
    }

    #[test]
    fn script_quotes_paths() {
        let script = status_script(
            ".amiscara-agents/uploads/git-status-1.txt",
            &["/x/it's here".into(), "/y".into()],
        );
        assert!(script.contains(r#"for d in '/x/it'\''s here' '/y'; do"#));
        assert!(script.contains(r#"out="$(dirname "$0")/git-status-1.txt""#));
        assert!(status_script("o.txt", &[]).contains("for d in ''; do"));
    }
}
