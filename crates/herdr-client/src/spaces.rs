//! Sidebar order of spaces, with groups taken from their names.
//!
//! herdr has no level above spaces; only linked worktrees are shown under
//! their repository. The app adds one by convention: a space named
//! `Privat/Dorfkino` belongs to the group `Privat` and is shown as
//! `Dorfkino`. The name lives on the server, so every device sees the same
//! groups, and herdr's own sidebar simply shows the full name.
//!
//! The convention is optional per host: without it, [`arrange`] keeps
//! herdr's flat order and full names, and only nests linked worktrees.

use std::cmp::Reverse;
use std::collections::HashMap;

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
    /// Name of the space as the sidebar row shows it (before any branch a
    /// nested worktree is named after): the short name inside a group,
    /// otherwise the full label.
    pub name: &'a str,
}

/// Places a space that is not a nested worktree.
fn place(workspace: &WorkspaceInfo, nested: bool, by_name: bool) -> Placed<'_> {
    let parsed = SpaceName::parse(&workspace.label);
    if by_name && !is_linked(workspace) {
        Placed {
            workspace,
            nested,
            group: parsed.group,
            name: parsed.name,
        }
    } else {
        Placed {
            workspace,
            nested,
            group: None,
            name: &workspace.label,
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

/// How [`arrange`] orders the spaces on each level of the sidebar: groups
/// and ungrouped spaces at the top, spaces inside a group, worktrees under
/// their repository. Groups stay blocks and worktrees stay under their
/// repository in every mode. herdr cannot reorder workspaces, so the order
/// is the app's, stored per host.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum SpaceSort {
    /// herdr's order, see [`arrange`].
    #[default]
    Herdr,
    /// By name, ignoring case; equal names keep herdr's order.
    NameAscending,
    NameDescending,
    /// Workspace IDs in the order the user put them. A group ranks by its
    /// first listed space; spaces not listed, such as new ones, follow at
    /// the end of their level in herdr's order.
    Manual(Vec<String>),
}

/// A space with the worktrees nested under it; it moves as one. Each entry
/// carries its position in herdr's order.
struct Unit<'a> {
    group: Option<&'a str>,
    members: Vec<(usize, Placed<'a>)>,
}

/// Sorts one level of the sidebar stably by `sort`, so ties keep herdr's
/// order; `manual` is an item's rank in a manual order.
fn sort_level<T>(
    items: &mut [T],
    sort: &SpaceSort,
    name: impl Fn(&T) -> &str,
    manual: impl Fn(&T) -> usize,
) {
    match sort {
        SpaceSort::Herdr => {}
        SpaceSort::NameAscending => items.sort_by_cached_key(|item| name(item).to_lowercase()),
        SpaceSort::NameDescending => {
            items.sort_by_cached_key(|item| Reverse(name(item).to_lowercase()));
        }
        SpaceSort::Manual(_) => items.sort_by_cached_key(manual),
    }
}

/// herdr's order (by number, each linked worktree right after the first
/// space of its repository), then grouped: all spaces of a group follow
/// the group's first space, so groups keep herdr's order among each other
/// and ungrouped spaces stay where they were. Entries of one group are
/// always adjacent. `sort` then reorders each level (see [`SpaceSort`]).
///
/// With `by_name` off no space forms a group: the order is herdr's and
/// every name is the full label, as herdr's own sidebar shows it.
pub fn arrange<'a>(
    workspaces: &'a [WorkspaceInfo],
    by_name: bool,
    sort: &SpaceSort,
) -> Vec<Placed<'a>> {
    let mut sorted: Vec<&WorkspaceInfo> = workspaces.iter().collect();
    sorted.sort_by_key(|ws| ws.number);

    let mut placed = vec![false; sorted.len()];
    let mut units: Vec<Unit<'_>> = Vec::new();
    for (index, &workspace) in sorted.iter().enumerate() {
        if is_linked(workspace) {
            continue;
        }
        let head = place(workspace, false, by_name);
        let group = head.group;
        let mut members = vec![(index, head)];
        placed[index] = true;
        if let Some(repo) = repo_key(workspace) {
            for (other, &worktree) in sorted.iter().enumerate() {
                if !placed[other] && is_linked(worktree) && repo_key(worktree) == Some(repo) {
                    members.push((
                        other,
                        Placed {
                            group,
                            ..place(worktree, true, false)
                        },
                    ));
                    placed[other] = true;
                }
            }
        }
        units.push(Unit { group, members });
    }
    // Worktrees whose main checkout has no space of their own.
    for (index, &workspace) in sorted.iter().enumerate() {
        if !placed[index] {
            units.push(Unit {
                group: None,
                members: vec![(index, place(workspace, false, false))],
            });
        }
    }

    // Blocks: a group with its units, or a single ungrouped unit.
    let mut blocks: Vec<Vec<Unit<'_>>> = Vec::new();
    let mut units: Vec<Option<Unit<'_>>> = units.into_iter().map(Some).collect();
    for first in 0..units.len() {
        let Some(head) = units[first].take() else {
            continue;
        };
        let group = head.group;
        let mut block = vec![head];
        if group.is_some() {
            for unit in units.iter_mut().skip(first + 1) {
                if unit.as_ref().is_some_and(|u| u.group == group) {
                    block.extend(unit.take());
                }
            }
        }
        blocks.push(block);
    }

    // Number the entries in herdr's order: the manual rank of unlisted
    // spaces, so a manual order without them is herdr's.
    for (position, member) in blocks
        .iter_mut()
        .flatten()
        .flat_map(|unit| unit.members.iter_mut())
        .enumerate()
    {
        member.0 = position;
    }

    // A listed space ranks by its position, the others after all listed
    // ones in herdr's order. The first of duplicate IDs counts.
    let (ranks, listed): (HashMap<&str, usize>, usize) = match sort {
        SpaceSort::Manual(order) => (
            order
                .iter()
                .enumerate()
                .rev()
                .map(|(rank, id)| (id.as_str(), rank))
                .collect(),
            order.len(),
        ),
        _ => (HashMap::new(), 0),
    };
    let rank = |(index, placed): &(usize, Placed<'_>)| {
        ranks
            .get(placed.workspace.workspace_id.as_str())
            .copied()
            .unwrap_or(listed + index)
    };
    let unit_rank = |unit: &Unit<'_>| rank(&unit.members[0]);

    for unit in blocks.iter_mut().flatten() {
        sort_level(&mut unit.members[1..], sort, |(_, p)| p.name, rank);
    }
    for block in &mut blocks {
        sort_level(block, sort, |unit| unit.members[0].1.name, unit_rank);
    }
    sort_level(
        &mut blocks,
        sort,
        |block| block[0].group.unwrap_or(block[0].members[0].1.name),
        |block| block.iter().map(unit_rank).min().unwrap_or(usize::MAX),
    );

    blocks
        .into_iter()
        .flatten()
        .flat_map(|unit| unit.members.into_iter().map(|(_, placed)| placed))
        .collect()
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
        layout_with(workspaces, true)
    }

    fn layout_with(workspaces: &[WorkspaceInfo], by_name: bool) -> Vec<(&str, bool, Option<&str>)> {
        arrange(workspaces, by_name, &SpaceSort::Herdr)
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
            space("w4", 4, "Arbeit / mailer"),
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
        let arranged = arrange(&spaces, true, &SpaceSort::Herdr);
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
        let names: Vec<&str> = arranged.iter().map(|p| p.name).collect();
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
    #[test]
    fn without_grouping_order_and_names_are_herdrs() {
        let spaces = [
            repo("w1", 1, "Privat/Dorfkino", "kino"),
            space("w2", 2, "notes"),
            space("w3", 3, "Privat/Bürgertreff"),
            worktree("w4", 4, "feature/x", "kino"),
            space("w5", 5, "Arbeit/mailer"),
            worktree("w6", 6, "feature/y", "other"),
        ];
        // Worktrees still sit under their repository; nothing else moves.
        assert_eq!(
            layout_with(&spaces, false),
            [
                ("w1", false, None),
                ("w4", true, None),
                ("w2", false, None),
                ("w3", false, None),
                ("w5", false, None),
                ("w6", false, None)
            ]
        );
        let names: Vec<&str> = arrange(&spaces, false, &SpaceSort::Herdr)
            .iter()
            .map(|p| p.name)
            .collect();
        assert_eq!(
            names,
            [
                "Privat/Dorfkino",
                "feature/x",
                "notes",
                "Privat/Bürgertreff",
                "Arbeit/mailer",
                "feature/y"
            ]
        );
    }

    #[test]
    fn grouping_gives_short_names() {
        let spaces = [space("w1", 1, "Privat / Dorfkino"), space("w2", 2, "/lead")];
        let names: Vec<&str> = arrange(&spaces, true, &SpaceSort::Herdr)
            .iter()
            .map(|p| p.name)
            .collect();
        assert_eq!(names, ["Dorfkino", "/lead"]);
    }

    fn ids(workspaces: &[WorkspaceInfo], by_name: bool, sort: &SpaceSort) -> Vec<String> {
        arrange(workspaces, by_name, sort)
            .into_iter()
            .map(|p| p.workspace.workspace_id.clone())
            .collect()
    }

    fn manual(order: &[&str]) -> SpaceSort {
        SpaceSort::Manual(order.iter().map(|id| (*id).to_owned()).collect())
    }

    /// Two groups, ungrouped spaces, a repository with worktrees inside a
    /// group and a worktree whose repository has no space.
    fn mixed() -> Vec<WorkspaceInfo> {
        vec![
            space("w1", 1, "Privat/Dorfkino"),
            space("w2", 2, "notes"),
            repo("w3", 3, "Arbeit/mailer", "mail"),
            space("w4", 4, "Privat/Bürgertreff"),
            worktree("w5", 5, "feature/zebra", "mail"),
            space("w6", 6, "Arbeit/energieausweis"),
            worktree("w7", 7, "Feature/alpha", "mail"),
            worktree("w8", 8, "Orphan", "gone"),
            space("w9", 9, "archive"),
        ]
    }

    #[test]
    fn herdr_sort_is_the_unsorted_order() {
        let spaces = mixed();
        assert_eq!(
            ids(&spaces, true, &SpaceSort::Herdr),
            ["w1", "w4", "w2", "w3", "w5", "w7", "w6", "w9", "w8"]
        );
    }

    #[test]
    fn name_ascending_sorts_every_level_and_keeps_blocks() {
        let spaces = mixed();
        let arranged = arrange(&spaces, true, &SpaceSort::NameAscending);
        assert_eq!(
            arranged
                .iter()
                .map(|p| (p.workspace.workspace_id.as_str(), p.nested, p.group))
                .collect::<Vec<_>>(),
            [
                // Groups sort by their name among the ungrouped spaces.
                ("w6", false, Some("Arbeit")),
                ("w3", false, Some("Arbeit")),
                // Worktrees by their own label, ignoring case.
                ("w7", true, Some("Arbeit")),
                ("w5", true, Some("Arbeit")),
                ("w9", false, None),
                ("w2", false, None),
                ("w8", false, None),
                ("w4", false, Some("Privat")),
                ("w1", false, Some("Privat")),
            ]
        );
    }

    #[test]
    fn name_descending_reverses_every_level() {
        let spaces = mixed();
        assert_eq!(
            ids(&spaces, true, &SpaceSort::NameDescending),
            ["w1", "w4", "w8", "w2", "w9", "w3", "w5", "w7", "w6"]
        );
    }

    #[test]
    fn equal_names_keep_herdrs_order() {
        let spaces = [
            space("w1", 1, "same"),
            space("w2", 2, "Same"),
            space("w3", 3, "a"),
        ];
        assert_eq!(
            ids(&spaces, true, &SpaceSort::NameAscending),
            ["w3", "w1", "w2"]
        );
        assert_eq!(
            ids(&spaces, true, &SpaceSort::NameDescending),
            ["w1", "w2", "w3"]
        );
    }

    #[test]
    fn without_grouping_names_are_full_labels() {
        let spaces = mixed();
        // "Arbeit/…" and "Privat/…" are plain labels and form no block.
        assert_eq!(
            ids(&spaces, false, &SpaceSort::NameAscending),
            ["w6", "w3", "w7", "w5", "w9", "w2", "w8", "w4", "w1"]
        );
        let arranged = arrange(&spaces, false, &SpaceSort::NameAscending);
        assert!(arranged.iter().all(|p| p.group.is_none()));
    }

    #[test]
    fn manual_follows_the_stored_order() {
        let spaces = mixed();
        let order = manual(&["w2", "w4", "w1", "w7", "w3", "w5", "w9", "w8", "w6"]);
        assert_eq!(
            ids(&spaces, true, &order),
            // Privat ranks by w4, Arbeit by w3; a repository stays above
            // its worktrees.
            ["w2", "w4", "w1", "w3", "w7", "w5", "w6", "w9", "w8"]
        );
    }

    #[test]
    fn manual_puts_unlisted_spaces_last_on_their_level() {
        let spaces = mixed();
        // w6 (Arbeit), w7 (worktree of w3) and w2 are not listed.
        let order = manual(&["w9", "w3", "w5", "w1", "w4", "w8"]);
        assert_eq!(
            ids(&spaces, true, &order),
            ["w9", "w3", "w5", "w7", "w6", "w1", "w4", "w8", "w2"]
        );
    }

    #[test]
    fn manual_without_order_is_herdrs() {
        let spaces = mixed();
        assert_eq!(
            ids(&spaces, true, &manual(&[])),
            ids(&spaces, true, &SpaceSort::Herdr)
        );
        // Unknown and duplicate IDs change nothing either.
        assert_eq!(
            ids(&spaces, true, &manual(&["gone", "w9", "w9"])),
            ["w9", "w1", "w4", "w2", "w3", "w5", "w7", "w6", "w8"]
        );
    }
}
