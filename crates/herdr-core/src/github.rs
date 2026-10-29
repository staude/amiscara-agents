//! Plans waiting for approval on GitHub (#296): which GitHub repository a
//! space's Git repository pushes to, read from its `.git/config`, and the
//! part of an enon-tools plan comment the apps show for the approval. The
//! apps fetch issues and comments from GitHub themselves.

/// A GitHub repository of the spaces on a host, with the spaces that show
/// it (its checkout and linked worktrees).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitHubRepo {
    /// `owner/name`.
    pub repo: String,
    pub workspace_ids: Vec<String>,
}

/// The heading an enon-tools plan comment starts with.
const PLAN_HEADING: &str = "## Implementierungsplan";
/// The section of a plan written for the person who approves it.
const OVERVIEW_HEADING: &str = "### Überblick für die Freigabe";

/// `owner/name` of the `[remote "origin"]` of a Git `config` file, when it
/// points to github.com: `git@github.com:o/r.git`,
/// `ssh://git@github.com/o/r.git` or `https://github.com/o/r`, with or
/// without `.git` and a trailing `/`. `None` for other hosts or no origin.
pub fn origin_repo(config: &str) -> Option<String> {
    let mut in_origin = false;
    for line in config.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_origin = is_origin_section(line);
            continue;
        }
        if !in_origin {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if key.trim().eq_ignore_ascii_case("url") {
            return github_path(value.trim().trim_matches('"'));
        }
    }
    None
}

/// `[remote "origin"]`, spaces inside the brackets allowed.
fn is_origin_section(line: &str) -> bool {
    let Some(inner) = line
        .strip_prefix('[')
        .and_then(|rest| rest.split_once(']'))
        .map(|(inner, _)| inner.trim())
    else {
        return false;
    };
    let Some((section, name)) = inner.split_once(char::is_whitespace) else {
        return false;
    };
    section.eq_ignore_ascii_case("remote") && name.trim() == "\"origin\""
}

/// `owner/name` of a remote URL on github.com.
fn github_path(url: &str) -> Option<String> {
    let path = if let Some((_, rest)) = url.split_once("://") {
        // `ssh://git@github.com:22/o/r`, `https://user@github.com/o/r`
        let (authority, path) = rest.split_once('/')?;
        let host = authority.rsplit('@').next()?;
        let host = host.split(':').next()?;
        if !host.eq_ignore_ascii_case("github.com") {
            return None;
        }
        path
    } else {
        // scp form `git@github.com:o/r`
        let (authority, path) = url.split_once(':')?;
        let host = authority.rsplit('@').next()?;
        if !host.eq_ignore_ascii_case("github.com") {
            return None;
        }
        path
    };
    let path = path.trim_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    let (owner, name) = path.split_once('/')?;
    let valid = |part: &str| {
        !part.is_empty()
            && part
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
    };
    (valid(owner) && valid(name)).then(|| format!("{owner}/{name}"))
}

/// The overview for the approval from an enon-tools plan comment: the text
/// below `### Überblick für die Freigabe` up to the agent's steps in
/// `<details>` or the end, open questions included. `None` when the
/// comment is no plan or has no such section.
pub fn plan_overview(body: &str) -> Option<String> {
    let mut lines = body.lines();
    lines.by_ref().find(|line| line.trim() == PLAN_HEADING)?;
    lines
        .by_ref()
        .find(|line| line.trim() == OVERVIEW_HEADING)?;
    let overview: Vec<&str> = lines
        .take_while(|line| !line.trim_start().starts_with("<details"))
        .collect();
    let text = overview.join("\n").trim().to_owned();
    (!text.is_empty()).then_some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(url: &str) -> String {
        format!(
            "[core]\n\trepositoryformatversion = 0\n[remote \"upstream\"]\n\turl = git@github.com:other/fork.git\n[remote \"origin\"]\n\turl = {url}\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n[branch \"main\"]\n\tremote = origin\n"
        )
    }

    #[test]
    fn reads_github_origins() {
        for url in [
            "git@github.com:staude/amiscara-agents.git",
            "git@github.com:staude/amiscara-agents",
            "ssh://git@github.com/staude/amiscara-agents.git",
            "ssh://git@github.com:22/staude/amiscara-agents",
            "https://github.com/staude/amiscara-agents",
            "https://github.com/staude/amiscara-agents.git",
            "https://github.com/staude/amiscara-agents/",
            "https://token@github.com/staude/amiscara-agents.git/",
        ] {
            assert_eq!(
                origin_repo(&config(url)).as_deref(),
                Some("staude/amiscara-agents"),
                "{url}"
            );
        }
    }

    #[test]
    fn ignores_other_hosts_and_remotes() {
        assert_eq!(origin_repo(&config("git@gitlab.com:o/r.git")), None);
        assert_eq!(origin_repo(&config("https://example.com/o/r")), None);
        assert_eq!(origin_repo(&config("/Users/me/repos/r.git")), None);
        assert_eq!(origin_repo(&config("https://github.com/o")), None);
        assert_eq!(origin_repo(&config("https://github.com/o/r/tree/x")), None);
        assert_eq!(
            origin_repo("[remote \"upstream\"]\n\turl = git@github.com:o/r.git\n"),
            None
        );
        assert_eq!(origin_repo(""), None);
    }

    #[test]
    fn reads_quoted_urls_and_spaced_sections() {
        assert_eq!(
            origin_repo("[ remote  \"origin\" ]\nURL=\"https://github.com/o/r.git\"\n").as_deref(),
            Some("o/r")
        );
    }

    const PLAN: &str = "## Implementierungsplan\n\n### Überblick für die Freigabe\n\nWer unterwegs ist, soll freigeben.\n\n**Entscheidungen**\n\n1. Token je Host.\n\n### Offene Fragen\n\n1. Welche Farbe?\n\n<details>\n<summary>Umsetzungsschritte</summary>\n\n### Schritte\n\n1. Code.\n\n</details>\n\nBranch erstellt: `feature/1-x`\n";

    #[test]
    fn takes_the_overview_up_to_the_details() {
        assert_eq!(
            plan_overview(PLAN).as_deref(),
            Some(
                "Wer unterwegs ist, soll freigeben.\n\n**Entscheidungen**\n\n1. Token je Host.\n\n### Offene Fragen\n\n1. Welche Farbe?"
            )
        );
    }

    #[test]
    fn takes_the_overview_to_the_end_without_details() {
        assert_eq!(
            plan_overview("## Implementierungsplan\n### Überblick für die Freigabe\r\nKurz.\r\n")
                .as_deref(),
            Some("Kurz.")
        );
    }

    #[test]
    fn needs_a_plan_and_an_overview() {
        assert_eq!(
            plan_overview("### Überblick für die Freigabe\n\nKein Plan."),
            None
        );
        assert_eq!(
            plan_overview("## Implementierungsplan\n\n### Schritte\n\n1. Code."),
            None
        );
        assert_eq!(
            plan_overview("## Implementierungsplan\n### Überblick für die Freigabe\n\n<details>"),
            None
        );
        assert_eq!(plan_overview("Plan freigegeben: https://example.com"), None);
    }
}
