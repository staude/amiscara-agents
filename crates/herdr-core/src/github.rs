//! The GitHub repository of a space (#309): read from the `origin` remote in
//! the Git configuration of its repository, so the apps can show the pull
//! request of the space's branch. Other remotes and hosts are ignored.

/// A repository on github.com.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitHubRepo {
    pub owner: String,
    pub name: String,
}

/// The GitHub repository of the `origin` remote in the Git configuration
/// `config` (the text of `.git/config`). `None` without an `origin`, or
/// when it does not point to github.com.
pub fn origin_repository(config: &str) -> Option<GitHubRepo> {
    let mut in_origin = false;
    let mut url = None;
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
            // The first `url` wins, as for `git remote get-url`.
            url.get_or_insert_with(|| config_value(value));
        }
    }
    parse_url(&url?)
}

/// `[remote "origin"]`; the section name ignores case, the remote's not.
fn is_origin_section(line: &str) -> bool {
    let Some(inner) = line
        .strip_prefix('[')
        .and_then(|rest| rest.split(']').next())
    else {
        return false;
    };
    let Some((section, sub)) = inner.split_once(char::is_whitespace) else {
        return false;
    };
    section.eq_ignore_ascii_case("remote") && sub.trim() == "\"origin\""
}

/// A value without comment and surrounding quotes.
fn config_value(value: &str) -> String {
    let value = value.trim();
    if let Some(quoted) = value.strip_prefix('"') {
        return quoted.split('"').next().unwrap_or_default().to_owned();
    }
    value
        .split([';', '#'])
        .next()
        .unwrap_or_default()
        .trim()
        .to_owned()
}

/// `git@github.com:o/r`, `ssh://git@github.com[:port]/o/r` or
/// `https://[user@]github.com/o/r`, each with or without `.git`.
fn parse_url(url: &str) -> Option<GitHubRepo> {
    let path = if let Some(rest) = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("ssh://"))
    {
        let (authority, path) = rest.split_once('/')?;
        let host = authority.rsplit('@').next()?;
        let host = host.split(':').next()?;
        if !host.eq_ignore_ascii_case("github.com") {
            return None;
        }
        path
    } else if url.contains("://") {
        return None;
    } else {
        // scp-like: [user@]host:path
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
    if owner.is_empty() || name.is_empty() || name.contains('/') {
        return None;
    }
    Some(GitHubRepo {
        owner: owner.to_owned(),
        name: name.to_owned(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo(owner: &str, name: &str) -> Option<GitHubRepo> {
        Some(GitHubRepo {
            owner: owner.into(),
            name: name.into(),
        })
    }

    fn config(url: &str) -> String {
        format!(
            "[core]\n\trepositoryformatversion = 0\n[remote \"origin\"]\n\turl = {url}\n\
             \tfetch = +refs/heads/*:refs/remotes/origin/*\n[branch \"main\"]\n\tremote = origin\n"
        )
    }

    #[test]
    fn scp_form() {
        let expected = repo("staude", "amiscara-agents");
        assert_eq!(
            origin_repository(&config("git@github.com:staude/amiscara-agents.git")),
            expected
        );
        assert_eq!(
            origin_repository(&config("git@github.com:staude/amiscara-agents")),
            expected
        );
    }

    #[test]
    fn ssh_form() {
        let expected = repo("staude", "amiscara-agents");
        assert_eq!(
            origin_repository(&config("ssh://git@github.com/staude/amiscara-agents.git")),
            expected
        );
        assert_eq!(
            origin_repository(&config("ssh://git@github.com:22/staude/amiscara-agents")),
            expected
        );
    }

    #[test]
    fn https_form() {
        let expected = repo("Immoticket24", "enon-ai-tooling");
        assert_eq!(
            origin_repository(&config(
                "https://github.com/Immoticket24/enon-ai-tooling.git"
            )),
            expected
        );
        assert_eq!(
            origin_repository(&config(
                "https://frank@github.com/Immoticket24/enon-ai-tooling"
            )),
            expected
        );
        assert_eq!(
            origin_repository(&config(
                "\"https://GitHub.com/Immoticket24/enon-ai-tooling/\""
            )),
            expected
        );
    }

    #[test]
    fn other_hosts() {
        assert_eq!(
            origin_repository(&config("git@gitlab.com:staude/amiscara-agents.git")),
            None
        );
        assert_eq!(
            origin_repository(&config("https://github.example.com/staude/x.git")),
            None
        );
        assert_eq!(origin_repository(&config("/srv/git/project.git")), None);
        assert_eq!(
            origin_repository(&config("file:///srv/github.com/a/b.git")),
            None
        );
    }

    #[test]
    fn origin_only() {
        let text = "[remote \"upstream\"]\n\turl = git@github.com:ogulcancelik/herdr.git\n\
                    [remote \"origin\"]\n\turl = git@github.com:staude/herdr.git # fork\n";
        assert_eq!(origin_repository(text), repo("staude", "herdr"));
    }

    #[test]
    fn no_origin() {
        let text = "[remote \"upstream\"]\n\turl = git@github.com:ogulcancelik/herdr.git\n";
        assert_eq!(origin_repository(text), None);
        assert_eq!(origin_repository("[core]\n\tbare = false\n"), None);
    }
}
