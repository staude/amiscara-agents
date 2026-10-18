//! Sidebar order of spaces, with groups taken from their names.
//!
//! herdr has no level above spaces; only linked worktrees are shown under
//! their repository. The app adds one by convention: a space named
//! `Privat/Dorfkino` belongs to the group `Privat` and is shown as
//! `Dorfkino`. The name lives on the server, so every device sees the same
//! groups, and herdr's own sidebar simply shows the full name.

use herdr_proto::WorkspaceInfo;

/// A space label split into group and short name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpaceName<'a> {
    /// The part before the first `/`, trimmed; `None` without a usable one.
    pub group: Option<&'a str>,
    /// What the app shows for the space: the trimmed rest after the first
    /// `/`, or the whole label when the name forms no group.
    pub name: &'a str,
}

impl<'a> SpaceName<'a> {
    /// Splits at the first `/` only, so `Privat/Kino/Plakate` is the space
    /// `Kino/Plakate` in `Privat`. Both sides must be non-empty after
    /// trimming: `/Kino` or `Privat/` stay ungrouped under their full label
    /// rather than becoming a group without a name or a nameless row.
    pub fn parse(label: &'a str) -> Self {
        if let Some((group, name)) = label.split_once('/') {
            let (group, name) = (group.trim(), name.trim());
            if !group.is_empty() && !name.is_empty() {
                return Self {
                    group: Some(group),
                    name,
                };
            }
        }
        Self {
            group: None,
            name: label,
        }
    }
}

/// One space in sidebar order.
#[derive(Debug, Clone, PartialEq)]
pub struct Placed<'a> {
    pub workspace: &'a WorkspaceInfo,
    /// A linked worktree shown under its repository's space.
    pub nested: bool,
    /// The group the space sits in. A nested worktree inherits its
    /// repository's group; its own label (often a branch like `feature/x`)
    /// never makes one.
    pub group: Option<&'a str>,
}

impl Placed<'_> {
    /// Short name of the space, as the sidebar row shows it (before any
    /// branch a nested worktree is named after).
    pub fn name(&self) -> &str {
        if is_linked(self.workspace) {
            &self.workspace.label
        } else {
            SpaceName::parse(&self.workspace.label).name
        }
    }
}

fn is_linked(workspace: &WorkspaceInfo) -> bool {
    workspace
        .worktree
        .as_ref()
        .is_some_and(|wt| wt.is_linked_worktree)
}

fn repo_key(workspace: &WorkspaceInfo) -> Option<&str> {
    workspace
        .worktree
        .as_ref()
        .map(|wt| wt.repo_key.as_str())
        .filter(|key| !key.is_empty())
}

/// herdr's order (by number, each linked worktree right after the first
/// space of its repository), then grouped: all spaces of a group follow
/// the group's first space, so groups keep herdr's order among each other
/// and ungrouped spaces stay where they were. Entries of one group are
/// always adjacent.
pub fn arrange(workspaces: &[WorkspaceInfo]) -> Vec<Placed<'_>> {
    let mut sorted: Vec<&WorkspaceInfo> = workspaces.iter().collect();
    sorted.sort_by_key(|ws| ws.number);

    // A unit is a space with the worktrees nested under it; it moves as one.
    let mut placed = vec![false; sorted.len()];
    let mut units: Vec<(Option<&str>, Vec<Placed<'_>>)> = Vec::new();
    for (index, &workspace) in sorted.iter().enumerate() {
        if is_linked(workspace) {
            continue;
        }
        let group = SpaceName::parse(&workspace.label).group;
        let mut members = vec![Placed {
            workspace,
            nested: false,
            group,
        }];
        placed[index] = true;
        if let Some(repo) = repo_key(workspace) {
            for (other, &worktree) in sorted.iter().enumerate() {
                if !placed[other] && is_linked(worktree) && repo_key(worktree) == Some(repo) {
                    members.push(Placed {
                        workspace: worktree,
                        nested: true,
                        group,
                    });
                    placed[other] = true;
                }
            }
        }
        units.push((group, members));
    }
    // Worktrees whose main checkout has no space of their own.
    for (index, &workspace) in sorted.iter().enumerate() {
        if !placed[index] {
            units.push((
                None,
                vec![Placed {
                    workspace,
                    nested: false,
                    group: None,
                }],
            ));
        }
    }

    let mut result = Vec::with_capacity(sorted.len());
    let mut taken = vec![false; units.len()];
    for first in 0..units.len() {
        if taken[first] {
            continue;
        }
        let group = units[first].0;
        for unit in first..units.len() {
            if !taken[unit] && (unit == first || (group.is_some() && units[unit].0 == group)) {
                taken[unit] = true;
                result.extend(units[unit].1.iter().cloned());
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_splits_at_the_first_slash() {
        let cases = [
            ("Dorfkino", None, "Dorfkino"),
            ("Privat/Dorfkino", Some("Privat"), "Dorfkino"),
            ("Privat / Dorfkino", Some("Privat"), "Dorfkino"),
            ("  Privat/  Bürgertreff ", Some("Privat"), "Bürgertreff"),
            ("Privat/Kino/Plakate", Some("Privat"), "Kino/Plakate"),
            ("a//b", Some("a"), "/b"),
            // No usable group: the label stays as it is.
            ("/Dorfkino", None, "/Dorfkino"),
            (" / Dorfkino", None, " / Dorfkino"),
            ("Privat/", None, "Privat/"),
            ("Privat / ", None, "Privat / "),
            ("/", None, "/"),
            ("", None, ""),
        ];
        for (label, group, name) in cases {
            assert_eq!(
                SpaceName::parse(label),
                SpaceName { group, name },
                "label {label:?}"
            );
        }
    }

    fn space(id: &str, number: u32, label: &str) -> WorkspaceInfo {
        workspace(json!({"workspace_id": id, "number": number, "label": label}))
    }

    fn repo(id: &str, number: u32, label: &str, key: &str) -> WorkspaceInfo {
        workspace(json!({"workspace_id": id, "number": number, "label": label,
            "worktree": {"repo_key": key, "repo_name": "r", "checkout_path": "/r"}}))
    }

    fn worktree(id: &str, number: u32, label: &str, key: &str) -> WorkspaceInfo {
        workspace(json!({"workspace_id": id, "number": number, "label": label,
            "worktree": {"repo_key": key, "repo_name": "r", "checkout_path": "/wt",
                         "is_linked_worktree": true}}))
    }

    fn workspace(value: serde_json::Value) -> WorkspaceInfo {
        match serde_json::from_value(value) {
            Ok(ws) => ws,
            Err(err) => panic!("fixture: {err}"),
        }
    }

    /// `id`, `nested`, `group` per entry.
    fn layout(workspaces: &[WorkspaceInfo]) -> Vec<(&str, bool, Option<&str>)> {
        arrange(workspaces)
            .into_iter()
            .map(|p| (p.workspace.workspace_id.as_str(), p.nested, p.group))
            .collect()
    }

    #[test]
    fn without_groups_order_is_herdrs() {
        let spaces = [
            space("w3", 3, "c"),
            repo("w1", 1, "core", "k"),
            worktree("w4", 4, "docs", "k"),
            space("w2", 2, "b"),
        ];
        assert_eq!(
            layout(&spaces),
            [
                ("w1", false, None),
                ("w4", true, None),
                ("w2", false, None),
                ("w3", false, None)
            ]
        );
    }

    #[test]
    fn groups_follow_their_first_space() {
        let spaces = [
            space("w1", 1, "Arbeit/energieausweis"),
            space("w2", 2, "notes"),
            space("w3", 3, "Privat/Bürgertreff"),
            space("w4", 4, "Arbeit / torromail"),
            space("w5", 5, "Privat/Dorfkino"),
            space("w6", 6, "scratch"),
        ];
        assert_eq!(
            layout(&spaces),
            [
                ("w1", false, Some("Arbeit")),
                ("w4", false, Some("Arbeit")),
                ("w2", false, None),
                ("w3", false, Some("Privat")),
                ("w5", false, Some("Privat")),
                ("w6", false, None)
            ]
        );
    }

    #[test]
    fn worktrees_stay_under_their_repository_and_never_group() {
        let spaces = [
            repo("w1", 1, "Privat/Dorfkino", "kino"),
            space("w2", 2, "notes"),
            space("w3", 3, "Privat/Bürgertreff"),
            // Branch-like labels must not start a group "feature".
            worktree("w4", 4, "feature/x", "kino"),
            worktree("w5", 5, "feature/y", "other"),
            repo("w6", 6, "plain", "plain"),
            worktree("w7", 7, "feature/z", "plain"),
        ];
        let arranged = arrange(&spaces);
        assert_eq!(
            layout(&spaces),
            [
                ("w1", false, Some("Privat")),
                ("w4", true, Some("Privat")),
                ("w3", false, Some("Privat")),
                ("w2", false, None),
                ("w6", false, None),
                ("w7", true, None),
                // Its repository has no space: last, ungrouped.
                ("w5", false, None)
            ]
        );
        let names: Vec<&str> = arranged.iter().map(Placed::name).collect();
        assert_eq!(
            names,
            [
                "Dorfkino",
                "feature/x",
                "Bürgertreff",
                "notes",
                "plain",
                "feature/z",
                "feature/y"
            ]
        );
    }

    #[test]
    fn slashes_without_a_group_stay_in_place() {
        let spaces = [
            space("w1", 1, "/lead"),
            space("w2", 2, "a/b"),
            space("w3", 3, "trail/"),
            space("w4", 4, "a/c/d"),
        ];
        assert_eq!(
            layout(&spaces),
            [
                ("w1", false, None),
                ("w2", false, Some("a")),
                ("w4", false, Some("a")),
                ("w3", false, None)
            ]
        );
    }
}
