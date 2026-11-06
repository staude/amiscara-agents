//! Hosts from the user's `~/.ssh/config` (#340), offered when adding a host
//! on the Mac and in the desktop app.
//!
//! Only what the host editor needs: the `Host` aliases without patterns and,
//! for each, `HostName`, `User` and `Port` as `ssh` would resolve them (first
//! value wins, `Host *` applies). `Include` is followed; `Match` blocks are
//! skipped. `IdentityFile` is left out on purpose: the apps log in with
//! their own restricted key, not the user's personal one.

use std::path::{Path, PathBuf};

use serde::Serialize;

/// `Include` nesting `ssh` itself allows; also ends include loops.
const MAX_INCLUDE_DEPTH: usize = 16;

/// One `Host` entry of the SSH configuration.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SshConfigHost {
    /// The name after `Host`, e.g. `work`; also the SSH target for VS Code.
    pub alias: String,
    /// `HostName`, or the alias when none is set.
    pub host_name: String,
    pub user: Option<String>,
    pub port: Option<u16>,
    /// Set when the host needs something the apps cannot do, e.g.
    /// `ProxyJump` or `ProxyCommand`; the editor shows it disabled.
    pub unsupported: Option<String>,
}

/// The hosts of `~/.ssh/config` and its includes; empty when there is no
/// home, no file or it cannot be read.
pub fn ssh_config_hosts() -> Vec<SshConfigHost> {
    let Some(home) = std::env::home_dir() else {
        return Vec::new();
    };
    let base_dir = home.join(".ssh");
    let Ok(text) = std::fs::read_to_string(base_dir.join("config")) else {
        return Vec::new();
    };
    parse_ssh_config(
        &text,
        &base_dir,
        &|path| std::fs::read_to_string(path).ok(),
        &list_dir,
    )
}

fn list_dir(dir: &Path) -> Vec<String> {
    std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .filter(|entry| entry.file_type().is_ok_and(|kind| !kind.is_dir()))
                .filter_map(|entry| entry.file_name().into_string().ok())
                .collect()
        })
        .unwrap_or_default()
}

/// The hosts in `text`, a configuration in `base_dir` (normally `~/.ssh`;
/// its parent stands for `~`). `read` gives a file's content, `list` the
/// file names in a directory (for `Include` with `*` or `?`).
pub fn parse_ssh_config(
    text: &str,
    base_dir: &Path,
    read: &dyn Fn(&Path) -> Option<String>,
    list: &dyn Fn(&Path) -> Vec<String>,
) -> Vec<SshConfigHost> {
    let mut parser = Parser {
        base_dir,
        read,
        list,
        aliases: Vec::new(),
        options: Vec::new(),
    };
    parser.parse(text, Some(&[]), 0);
    let Parser {
        aliases, options, ..
    } = parser;
    aliases
        .into_iter()
        .map(|alias| resolve(alias, &options))
        .collect()
}

/// An option line together with the `Host` pattern lists it sits under
/// (more than one through `Include` inside a `Host` block); all must match.
struct Setting {
    conditions: Vec<Vec<String>>,
    key: String,
    value: String,
}

struct Parser<'a> {
    base_dir: &'a Path,
    read: &'a dyn Fn(&Path) -> Option<String>,
    list: &'a dyn Fn(&Path) -> Vec<String>,
    aliases: Vec<String>,
    options: Vec<Setting>,
}

impl Parser<'_> {
    /// `outer`: the conditions of the including block, `None` inside a
    /// `Match` block (its options never apply here).
    fn parse(&mut self, text: &str, outer: Option<&[Vec<String>]>, depth: usize) {
        let mut current: Option<Vec<Vec<String>>> = outer.map(<[_]>::to_vec);
        for line in text.lines() {
            let Some((key, args)) = split_line(line) else {
                continue;
            };
            match key.as_str() {
                "host" => {
                    for pattern in &args {
                        if !pattern.contains(['*', '?', '!']) && !self.aliases.contains(pattern) {
                            self.aliases.push(pattern.clone());
                        }
                    }
                    current = outer.map(|outer| {
                        let mut conditions = outer.to_vec();
                        conditions.push(args);
                        conditions
                    });
                }
                "match" => current = None,
                "include" => {
                    if depth + 1 >= MAX_INCLUDE_DEPTH {
                        continue;
                    }
                    for pattern in &args {
                        for path in self.include_paths(pattern) {
                            if let Some(text) = (self.read)(&path) {
                                self.parse(&text, current.as_deref(), depth + 1);
                            }
                        }
                    }
                }
                _ => {
                    if let (Some(conditions), Some(value)) = (&current, args.into_iter().next()) {
                        self.options.push(Setting {
                            conditions: conditions.clone(),
                            key,
                            value,
                        });
                    }
                }
            }
        }
    }

    /// The files an `Include` argument names, sorted when it has a pattern.
    fn include_paths(&self, pattern: &str) -> Vec<PathBuf> {
        let path = if let Some(rest) = pattern.strip_prefix("~/") {
            self.base_dir.parent().unwrap_or(self.base_dir).join(rest)
        } else {
            self.base_dir.join(pattern)
        };
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            return Vec::new();
        };
        if !name.contains(['*', '?']) {
            return vec![path];
        }
        let Some(dir) = path.parent() else {
            return Vec::new();
        };
        let mut names: Vec<String> = (self.list)(dir)
            .into_iter()
            .filter(|candidate| !candidate.starts_with('.') || name.starts_with('.'))
            .filter(|candidate| wildcard_match(name, candidate))
            .collect();
        names.sort();
        names.into_iter().map(|name| dir.join(name)).collect()
    }
}

/// Values for one alias: the first of each key among the blocks that apply.
fn resolve(alias: String, options: &[Setting]) -> SshConfigHost {
    let first = |key: &str| {
        options
            .iter()
            .find(|option| {
                option.key == key
                    && option
                        .conditions
                        .iter()
                        .all(|patterns| host_matches(patterns, &alias))
            })
            .map(|option| option.value.as_str())
    };
    let host_name = first("hostname")
        .map(|name| expand_tokens(name, &alias))
        .unwrap_or_else(|| alias.clone());
    let user = first("user").map(str::to_owned);
    let port = first("port")
        .and_then(|port| port.parse::<u16>().ok())
        .filter(|port| *port != 0);
    // Like ssh, whichever of ProxyJump and ProxyCommand comes first, also
    // as `none`, decides; the other is ignored then.
    let unsupported = options
        .iter()
        .find(|option| {
            matches!(option.key.as_str(), "proxyjump" | "proxycommand")
                && option
                    .conditions
                    .iter()
                    .all(|patterns| host_matches(patterns, &alias))
        })
        .filter(|option| !option.value.eq_ignore_ascii_case("none"))
        .map(|option| {
            if option.key == "proxyjump" {
                "ProxyJump".to_owned()
            } else {
                "ProxyCommand".to_owned()
            }
        });
    SshConfigHost {
        alias,
        host_name,
        user,
        port,
        unsupported,
    }
}

/// `%h` stands for the alias and `%%` for `%` in `HostName`.
fn expand_tokens(value: &str, alias: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(ch) = chars.next() {
        if ch != '%' {
            out.push(ch);
            continue;
        }
        match chars.next() {
            Some('h') => out.push_str(alias),
            Some('%') => out.push('%'),
            Some(other) => {
                out.push('%');
                out.push(other);
            }
            None => out.push('%'),
        }
    }
    out
}

/// A `Host` line's patterns against a name: no negated pattern may match,
/// and at least one plain pattern must.
fn host_matches(patterns: &[String], name: &str) -> bool {
    let mut matched = false;
    for pattern in patterns {
        if let Some(negated) = pattern.strip_prefix('!') {
            if wildcard_match(negated, name) {
                return false;
            }
        } else if wildcard_match(pattern, name) {
            matched = true;
        }
    }
    matched
}

/// `*` for any run of characters, `?` for one.
fn wildcard_match(pattern: &str, text: &str) -> bool {
    let pattern: Vec<char> = pattern.chars().collect();
    let text: Vec<char> = text.chars().collect();
    let (mut p, mut t) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while t < text.len() {
        if p < pattern.len() && (pattern[p] == '?' || pattern[p] == text[t]) {
            p += 1;
            t += 1;
        } else if p < pattern.len() && pattern[p] == '*' {
            star = Some((p, t));
            p += 1;
        } else if let Some((star_p, star_t)) = star {
            p = star_p + 1;
            t = star_t + 1;
            star = Some((star_p, star_t + 1));
        } else {
            return false;
        }
    }
    pattern[p..].iter().all(|ch| *ch == '*')
}

/// Keyword (lowercase) and arguments of a line; `None` for blank lines and
/// comments. Accepts `key value` and `key=value`, double quotes, and `#`
/// starting a comment at the beginning of an argument.
fn split_line(line: &str) -> Option<(String, Vec<String>)> {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    let end = line
        .find(|ch: char| ch.is_whitespace() || ch == '=')
        .unwrap_or(line.len());
    let key = line[..end].to_ascii_lowercase();
    let mut rest = line[end..].trim_start();
    if let Some(after) = rest.strip_prefix('=') {
        rest = after.trim_start();
    }
    let mut args = Vec::new();
    let mut chars = rest.chars().peekable();
    loop {
        while chars.next_if(|ch| ch.is_whitespace()).is_some() {}
        match chars.peek() {
            None | Some('#') => break,
            Some('"') => {
                chars.next();
                let arg: String = chars.by_ref().take_while(|ch| *ch != '"').collect();
                args.push(arg);
            }
            Some(_) => {
                let mut arg = String::new();
                while let Some(ch) = chars.next_if(|ch| !ch.is_whitespace()) {
                    arg.push(ch);
                }
                args.push(arg);
            }
        }
    }
    Some((key, args))
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;

    fn parse(main: &str, files: &[(&str, &str)]) -> Vec<SshConfigHost> {
        let files: HashMap<PathBuf, String> = files
            .iter()
            .map(|(path, text)| (PathBuf::from(path), (*text).to_owned()))
            .collect();
        let read = |path: &Path| files.get(path).cloned();
        let list = |dir: &Path| {
            files
                .keys()
                .filter(|path| path.parent() == Some(dir))
                .filter_map(|path| path.file_name()?.to_str().map(str::to_owned))
                .collect()
        };
        parse_ssh_config(main, Path::new("/home/frank/.ssh"), &read, &list)
    }

    fn host(alias: &str, host_name: &str, user: Option<&str>, port: Option<u16>) -> SshConfigHost {
        SshConfigHost {
            alias: alias.to_owned(),
            host_name: host_name.to_owned(),
            user: user.map(str::to_owned),
            port,
            unsupported: None,
        }
    }

    #[test]
    fn ssh_config_lists_hosts_without_wildcards() {
        let hosts = parse(
            "Host work build\n  HostName work.staude.internal\nHost *.example ?x !no\n  User x\nHost work\n  Port 2222\n",
            &[],
        );
        let aliases: Vec<_> = hosts.iter().map(|host| host.alias.as_str()).collect();
        assert_eq!(aliases, ["work", "build"]);
    }

    #[test]
    fn ssh_config_host_star_applies_and_first_value_wins() {
        let hosts = parse(
            "Host work\n  HostName work.staude.internal\n  User frank\nHost work\n  User other\n  Port 2222\nHost *\n  User fallback\n  Port 22\nHost spare\n",
            &[],
        );
        assert_eq!(
            hosts,
            [
                host("work", "work.staude.internal", Some("frank"), Some(2222)),
                host("spare", "spare", Some("fallback"), Some(22)),
            ]
        );
    }

    #[test]
    fn ssh_config_negated_pattern_excludes() {
        let hosts = parse("Host a b\nHost * !b\n  User u\n", &[]);
        assert_eq!(hosts[0].user.as_deref(), Some("u"));
        assert_eq!(hosts[1].user, None);
    }

    #[test]
    fn ssh_config_hostname_token_and_invalid_port() {
        let hosts = parse(
            "Host work\n  HostName %h.staude.internal\n  Port nope\n",
            &[],
        );
        assert_eq!(hosts, [host("work", "work.staude.internal", None, None)]);
    }

    #[test]
    fn ssh_config_key_equals_value_quotes_and_comments() {
        let hosts = parse(
            "# comment\nHost=\"work\"\n  hostname=\"work.example\"\n  USER = frank # me\n  Port=22\n",
            &[],
        );
        assert_eq!(
            hosts,
            [host("work", "work.example", Some("frank"), Some(22))]
        );
    }

    #[test]
    fn ssh_config_include_with_glob_and_relative_path() {
        let hosts = parse(
            "Include config.d/*.conf ~/other/extra\nHost main\n",
            &[
                ("/home/frank/.ssh/config.d/b.conf", "Host b\n  User bee\n"),
                ("/home/frank/.ssh/config.d/a.conf", "Host a\n"),
                ("/home/frank/.ssh/config.d/skip.txt", "Host skip\n"),
                ("/home/frank/other/extra", "Host extra\n  Port 2200\n"),
            ],
        );
        let aliases: Vec<_> = hosts.iter().map(|host| host.alias.as_str()).collect();
        assert_eq!(aliases, ["a", "b", "extra", "main"]);
        assert_eq!(hosts[1].user.as_deref(), Some("bee"));
        assert_eq!(hosts[2].port, Some(2200));
    }

    #[test]
    fn ssh_config_include_inside_host_block_stays_conditional() {
        let hosts = parse(
            "Host work\n  Include extra\nHost other\n",
            &[("/home/frank/.ssh/extra", "User frank\n")],
        );
        assert_eq!(hosts[0].user.as_deref(), Some("frank"));
        assert_eq!(hosts[1].user, None);
    }

    #[test]
    fn ssh_config_include_loop_ends() {
        let hosts = parse(
            "Include loop\n",
            &[("/home/frank/.ssh/loop", "Host looped\nInclude loop\n")],
        );
        assert_eq!(hosts, [host("looped", "looped", None, None)]);
    }

    #[test]
    fn ssh_config_skips_match_blocks() {
        let hosts = parse(
            "Match host work\n  User matched\nHost work\n  HostName w\n",
            &[],
        );
        assert_eq!(hosts, [host("work", "w", None, None)]);
    }

    #[test]
    fn ssh_config_marks_proxy_jump_and_command() {
        let hosts = parse(
            "Host jump\n  ProxyJump bastion\nHost cmd\n  ProxyCommand ssh -W %h:%p bastion\nHost none\n  ProxyJump none\n",
            &[],
        );
        assert_eq!(hosts[0].unsupported.as_deref(), Some("ProxyJump"));
        assert_eq!(hosts[1].unsupported.as_deref(), Some("ProxyCommand"));
        assert_eq!(hosts[2].unsupported, None);
    }

    #[test]
    fn ssh_config_first_proxy_option_decides() {
        let hosts = parse(
            "Host direct\n  ProxyCommand none\nHost cmd\n  ProxyJump none\nHost *\n  ProxyJump bastion\n  ProxyCommand nc %h %p\n",
            &[],
        );
        assert_eq!(hosts[0].unsupported, None);
        assert_eq!(hosts[1].unsupported, None);
    }

    #[test]
    fn ssh_config_ignores_identity_file() {
        let hosts = parse("Host work\n  IdentityFile ~/.ssh/id_ed25519\n", &[]);
        assert_eq!(hosts, [host("work", "work", None, None)]);
    }
}
