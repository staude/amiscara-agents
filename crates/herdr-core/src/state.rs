use std::collections::BTreeMap;

use herdr_proto::{
    AgentStatus, Event, PaneInfo, SessionSnapshot, TabInfo, TabLayout, WorkspaceInfo,
};

/// Everything the client knows about one server.
#[derive(Debug, Clone, PartialEq)]
pub struct SessionState {
    pub version: String,
    pub protocol: u32,
    /// Ordered by workspace number.
    pub workspaces: Vec<WorkspaceInfo>,
    /// Ordered by workspace, then tab number.
    pub tabs: Vec<TabInfo>,
    pub panes: Vec<PaneInfo>,
    /// Pane arrangement per tab, for showing split tabs side by side.
    pub layouts: Vec<TabLayout>,
    pub focused_pane_id: Option<String>,
    /// Git branch per workspace id, from `worktree.list`; not part of the
    /// snapshot, so the sync driver fills and carries it.
    pub branches: BTreeMap<String, String>,
    /// Custom agent names (`agent.rename`) by pane id. herdr sends them only
    /// with the snapshot, so the sync driver takes a fresh one after a rename.
    pub agent_names: BTreeMap<String, String>,
}

/// What [`SessionState::apply`] did with an event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Applied {
    Updated,
    Unchanged,
    /// The event changes structure (create, close, move, layout) or refers to
    /// something unknown. herdr delivers each event type from its own loop,
    /// so order across types is not guaranteed; a fresh snapshot is the
    /// reliable answer.
    NeedsSnapshot,
}

/// A page the host's browser stand-in (`scripts/host/amiscara-open`) wants
/// opened, from a pane's `open_id` and `open_url_0`, `open_url_1`, ...
/// tokens (herdr cuts every value to 80 characters).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenRequest {
    pub pane_id: String,
    /// Distinguishes requests of one pane; dismissing names it.
    pub open_id: String,
    pub url: String,
}

/// Token names of an [`OpenRequest`].
pub const OPEN_ID_TOKEN: &str = "open_id";
pub const OPEN_URL_TOKEN_PREFIX: &str = "open_url_";
/// How many URL pieces the stand-in writes at most (15 × 80 characters).
pub const OPEN_URL_PARTS: usize = 15;

/// One agent on the board.
#[derive(Debug, Clone, Copy)]
pub struct BoardEntry<'a> {
    pub pane: &'a PaneInfo,
    pub workspace: Option<&'a WorkspaceInfo>,
    pub tab: Option<&'a TabInfo>,
}

impl SessionState {
    pub fn from_snapshot(snapshot: SessionSnapshot) -> Self {
        let mut state = Self {
            version: snapshot.version,
            protocol: snapshot.protocol,
            workspaces: snapshot.workspaces,
            tabs: snapshot.tabs,
            panes: snapshot.panes,
            layouts: snapshot.layouts,
            focused_pane_id: snapshot.focused_pane_id,
            branches: BTreeMap::new(),
            agent_names: snapshot
                .agents
                .into_iter()
                .filter_map(|agent| Some((agent.pane_id, agent.name?)))
                .collect(),
        };
        state.workspaces.sort_by_key(|ws| ws.number);
        let order = state.workspace_order();
        state
            .tabs
            .sort_by_key(|tab| (order(&tab.workspace_id), tab.number));
        state
    }

    pub fn workspace(&self, workspace_id: &str) -> Option<&WorkspaceInfo> {
        self.workspaces
            .iter()
            .find(|ws| ws.workspace_id == workspace_id)
    }

    pub fn tab(&self, tab_id: &str) -> Option<&TabInfo> {
        self.tabs.iter().find(|tab| tab.tab_id == tab_id)
    }

    pub fn pane(&self, pane_id: &str) -> Option<&PaneInfo> {
        self.panes.iter().find(|pane| pane.pane_id == pane_id)
    }

    pub fn layout(&self, tab_id: &str) -> Option<&TabLayout> {
        self.layouts.iter().find(|layout| layout.tab_id == tab_id)
    }

    pub fn pane_ids(&self) -> Vec<String> {
        self.panes.iter().map(|pane| pane.pane_id.clone()).collect()
    }

    /// Agent panes, most urgent first: blocked, working, done, idle, unknown,
    /// then in workspace and tab order.
    pub fn board(&self) -> Vec<BoardEntry<'_>> {
        let mut entries: Vec<BoardEntry<'_>> = self
            .panes
            .iter()
            .filter(|pane| pane.agent.is_some())
            .map(|pane| BoardEntry {
                pane,
                workspace: self.workspace(&pane.workspace_id),
                tab: self.tab(&pane.tab_id),
            })
            .collect();
        entries.sort_by(|a, b| {
            let key = |e: &BoardEntry<'_>| {
                (
                    urgency(e.pane.agent_status),
                    e.workspace.map_or(u32::MAX, |ws| ws.number),
                    e.tab.map_or(u32::MAX, |tab| tab.number),
                )
            };
            key(a)
                .cmp(&key(b))
                .then_with(|| a.pane.pane_id.cmp(&b.pane.pane_id))
        });
        entries
    }

    /// Agent panes that now need the user and did not before: newly
    /// `blocked` (waiting for an answer) or newly `done` (finished, unseen).
    /// Panes that were already in that state stay quiet, so repeated
    /// snapshots or reconnects do not notify twice.
    pub fn attention_since(&self, before: &SessionState) -> Vec<String> {
        self.panes
            .iter()
            .filter(|pane| pane.agent.is_some())
            .filter(|pane| matches!(pane.agent_status, AgentStatus::Blocked | AgentStatus::Done))
            .filter(|pane| {
                before
                    .pane(&pane.pane_id)
                    .is_none_or(|old| old.agent_status != pane.agent_status)
            })
            .map(|pane| pane.pane_id.clone())
            .collect()
    }

    /// Pages the panes ask to open right now, in pane order. A request
    /// stays until the stand-in's time to live runs out or a client
    /// dismisses it, so every client shows the same ones. Only `http` and
    /// `https` URLs of printable ASCII count; the URL ends at the first
    /// missing piece.
    pub fn open_requests(&self) -> Vec<OpenRequest> {
        self.panes
            .iter()
            .filter_map(|pane| {
                let open_id = pane.tokens.get(OPEN_ID_TOKEN).filter(|id| !id.is_empty())?;
                let url: String = (0..OPEN_URL_PARTS)
                    .map_while(|i| pane.tokens.get(&format!("{OPEN_URL_TOKEN_PREFIX}{i}")))
                    .map(String::as_str)
                    .collect();
                let scheme = url.split_once("://")?.0.to_ascii_lowercase();
                (matches!(scheme.as_str(), "http" | "https")
                    && url.len() > scheme.len() + 3
                    && url.bytes().all(|byte| (b'!'..=b'~').contains(&byte)))
                .then(|| OpenRequest {
                    pane_id: pane.pane_id.clone(),
                    open_id: open_id.clone(),
                    url,
                })
            })
            .collect()
    }

    pub fn apply(&mut self, event: &Event) -> Applied {
        match event {
            Event::WorkspaceUpdated { workspace }
            | Event::WorkspaceMetadataUpdated { workspace } => {
                match self
                    .workspaces
                    .iter_mut()
                    .find(|ws| ws.workspace_id == workspace.workspace_id)
                {
                    // A new number means a new position; let the snapshot sort it.
                    Some(ws) if ws.number != workspace.number => Applied::NeedsSnapshot,
                    Some(ws) => replace(ws, workspace.clone()),
                    None => Applied::NeedsSnapshot,
                }
            }
            Event::WorkspaceRenamed {
                workspace_id,
                label,
            } => match self
                .workspaces
                .iter_mut()
                .find(|ws| &ws.workspace_id == workspace_id)
            {
                Some(ws) => replace(&mut ws.label, label.clone()),
                None => Applied::NeedsSnapshot,
            },
            Event::WorkspaceFocused { workspace_id } => {
                if self.workspace(workspace_id).is_none() {
                    return Applied::NeedsSnapshot;
                }
                let mut applied = Applied::Unchanged;
                for ws in &mut self.workspaces {
                    applied =
                        applied.or(replace(&mut ws.focused, &ws.workspace_id == workspace_id));
                }
                applied
            }
            Event::TabRenamed { tab_id, label, .. } => {
                match self.tabs.iter_mut().find(|tab| &tab.tab_id == tab_id) {
                    Some(tab) => replace(&mut tab.label, label.clone()),
                    None => Applied::NeedsSnapshot,
                }
            }
            Event::TabFocused {
                workspace_id,
                tab_id,
            } => {
                if self.tab(tab_id).is_none() {
                    return Applied::NeedsSnapshot;
                }
                let mut applied = Applied::Unchanged;
                for tab in self
                    .tabs
                    .iter_mut()
                    .filter(|tab| &tab.workspace_id == workspace_id)
                {
                    applied = applied.or(replace(&mut tab.focused, &tab.tab_id == tab_id));
                }
                if let Some(ws) = self
                    .workspaces
                    .iter_mut()
                    .find(|ws| &ws.workspace_id == workspace_id)
                {
                    applied = applied.or(replace(&mut ws.active_tab_id, tab_id.clone()));
                }
                applied
            }
            Event::PaneUpdated { pane } => match self.pane_mut(&pane.pane_id) {
                Some(existing)
                    if existing.tab_id == pane.tab_id
                        && existing.workspace_id == pane.workspace_id =>
                {
                    replace(existing, pane.clone())
                }
                _ => Applied::NeedsSnapshot,
            },
            Event::PaneFocused { pane_id, .. } => {
                if self.pane(pane_id).is_none() {
                    return Applied::NeedsSnapshot;
                }
                let mut applied = replace(&mut self.focused_pane_id, Some(pane_id.clone()));
                for pane in &mut self.panes {
                    applied = applied.or(replace(&mut pane.focused, &pane.pane_id == pane_id));
                }
                applied
            }
            Event::PaneAgentStatusChanged {
                pane_id,
                agent_status,
                agent,
                display_agent,
                title,
            } => {
                let Some(pane) = self.pane_mut(pane_id) else {
                    return Applied::NeedsSnapshot;
                };
                let mut applied = replace(&mut pane.agent_status, *agent_status);
                if agent.is_some() {
                    applied = applied.or(replace(&mut pane.agent, agent.clone()));
                }
                if display_agent.is_some() {
                    applied = applied.or(replace(&mut pane.display_agent, display_agent.clone()));
                }
                if title.is_some() {
                    applied = applied.or(replace(&mut pane.title, title.clone()));
                }
                applied
            }
            Event::PaneAgentDetected { pane_id, agent } => match self.pane_mut(pane_id) {
                Some(pane) => replace(&mut pane.agent, agent.clone()),
                None => Applied::NeedsSnapshot,
            },
            Event::PaneOutputChanged { pane_id, revision } => match self.pane_mut(pane_id) {
                Some(pane) if *revision > pane.revision => {
                    pane.revision = *revision;
                    Applied::Updated
                }
                Some(_) => Applied::Unchanged,
                None => Applied::NeedsSnapshot,
            },
            // A resize, ratio change or zoom keeps the same panes and can be
            // applied directly. A layout with other panes comes together with
            // create, close or move events, which take a snapshot anyway.
            Event::LayoutUpdated {
                layout: Some(layout),
            } => {
                let mut known: Vec<&str> = self
                    .panes
                    .iter()
                    .filter(|pane| pane.tab_id == layout.tab_id)
                    .map(|pane| pane.pane_id.as_str())
                    .collect();
                let mut laid_out: Vec<&str> = layout
                    .panes
                    .iter()
                    .map(|pane| pane.pane_id.as_str())
                    .collect();
                known.sort_unstable();
                laid_out.sort_unstable();
                if known != laid_out {
                    return Applied::NeedsSnapshot;
                }
                match self
                    .layouts
                    .iter_mut()
                    .find(|existing| existing.tab_id == layout.tab_id)
                {
                    Some(existing) => replace(existing, layout.clone()),
                    None => Applied::NeedsSnapshot,
                }
            }
            Event::WorkspaceCreated { .. }
            | Event::WorkspaceClosed { .. }
            | Event::WorkspaceMoved { .. }
            | Event::WorkspaceReordered {}
            | Event::WorktreeCreated {}
            | Event::WorktreeOpened {}
            | Event::WorktreeRemoved {}
            | Event::TabCreated { .. }
            | Event::TabClosed { .. }
            | Event::TabMoved { .. }
            | Event::PaneCreated { .. }
            | Event::PaneClosed { .. }
            | Event::PaneMoved { .. }
            | Event::PaneExited { .. }
            | Event::LayoutUpdated { layout: None }
            | Event::Unknown => Applied::NeedsSnapshot,
        }
    }

    fn pane_mut(&mut self, pane_id: &str) -> Option<&mut PaneInfo> {
        self.panes.iter_mut().find(|pane| pane.pane_id == pane_id)
    }

    fn workspace_order(&self) -> impl Fn(&str) -> u32 + use<> {
        let numbers: Vec<(String, u32)> = self
            .workspaces
            .iter()
            .map(|ws| (ws.workspace_id.clone(), ws.number))
            .collect();
        move |id| {
            numbers
                .iter()
                .find(|(ws, _)| ws == id)
                .map_or(u32::MAX, |(_, number)| *number)
        }
    }
}

impl Applied {
    /// Combines two outcomes; the stronger one wins.
    pub fn or(self, other: Applied) -> Applied {
        match (self, other) {
            (Applied::NeedsSnapshot, _) | (_, Applied::NeedsSnapshot) => Applied::NeedsSnapshot,
            (Applied::Updated, _) | (_, Applied::Updated) => Applied::Updated,
            _ => Applied::Unchanged,
        }
    }
}

fn replace<T: PartialEq>(slot: &mut T, value: T) -> Applied {
    if *slot == value {
        Applied::Unchanged
    } else {
        *slot = value;
        Applied::Updated
    }
}

fn urgency(status: AgentStatus) -> u8 {
    match status {
        AgentStatus::Blocked => 0,
        AgentStatus::Working => 1,
        AgentStatus::Done => 2,
        AgentStatus::Idle => 3,
        AgentStatus::Unknown => 4,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn snapshot() -> SessionState {
        let value = json!({
            "version": "0.9.4",
            "protocol": 22,
            "focused_pane_id": "w1:p1",
            "workspaces": [
                {"workspace_id": "w2", "number": 2, "label": "api", "active_tab_id": "w2:t1"},
                {"workspace_id": "w1", "number": 1, "label": "web", "focused": true, "active_tab_id": "w1:t1"}
            ],
            "tabs": [
                {"tab_id": "w2:t1", "workspace_id": "w2", "number": 1, "label": "1", "focused": true},
                {"tab_id": "w1:t2", "workspace_id": "w1", "number": 2, "label": "2"},
                {"tab_id": "w1:t1", "workspace_id": "w1", "number": 1, "label": "1", "focused": true}
            ],
            "panes": [
                {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "focused": true,
                 "agent": "claude", "agent_status": "idle", "revision": 3},
                {"pane_id": "w1:p2", "workspace_id": "w1", "tab_id": "w1:t2",
                 "agent": "codex", "agent_status": "working", "revision": 1},
                {"pane_id": "w2:p1", "workspace_id": "w2", "tab_id": "w2:t1",
                 "agent": "claude", "agent_status": "done", "revision": 9},
                {"pane_id": "w2:p2", "workspace_id": "w2", "tab_id": "w2:t1",
                 "agent_status": "unknown", "revision": 2}
            ],
            "layouts": [
                {"workspace_id": "w2", "tab_id": "w2:t1", "zoomed": false,
                 "area": {"x": 0, "y": 0, "width": 120, "height": 40},
                 "focused_pane_id": "w2:p1",
                 "panes": [
                    {"pane_id": "w2:p1", "focused": true, "rect": {"x": 0, "y": 0, "width": 60, "height": 40}},
                    {"pane_id": "w2:p2", "rect": {"x": 60, "y": 0, "width": 60, "height": 40}}
                 ],
                 "splits": [{"id": "split_0_root", "direction": "right", "ratio": 0.5,
                             "rect": {"x": 0, "y": 0, "width": 120, "height": 40}}]}
            ],
            "agents": [
                {"terminal_id": "term_1", "name": "reviewer", "agent": "claude", "agent_status": "idle",
                 "workspace_id": "w1", "tab_id": "w1:t1", "pane_id": "w1:p1", "revision": 3},
                {"terminal_id": "term_2", "agent": "codex", "agent_status": "working",
                 "workspace_id": "w1", "tab_id": "w1:t2", "pane_id": "w1:p2", "revision": 1}
            ]
        });
        match serde_json::from_value(value) {
            Ok(snapshot) => SessionState::from_snapshot(snapshot),
            Err(err) => panic!("fixture: {err}"),
        }
    }

    fn event(value: serde_json::Value) -> Event {
        match herdr_proto::parse_event(value) {
            Ok(event) => event,
            Err(err) => panic!("fixture: {err}"),
        }
    }

    fn board_ids(state: &SessionState) -> Vec<&str> {
        state
            .board()
            .iter()
            .map(|e| e.pane.pane_id.as_str())
            .collect()
    }

    #[test]
    fn snapshot_is_sorted() {
        let state = snapshot();
        let ws: Vec<_> = state
            .workspaces
            .iter()
            .map(|w| w.workspace_id.as_str())
            .collect();
        assert_eq!(ws, ["w1", "w2"]);
        let tabs: Vec<_> = state.tabs.iter().map(|t| t.tab_id.as_str()).collect();
        assert_eq!(tabs, ["w1:t1", "w1:t2", "w2:t1"]);
    }

    #[test]
    fn board_puts_urgent_agents_first_and_skips_shells() {
        let mut state = snapshot();
        assert_eq!(board_ids(&state), ["w1:p2", "w2:p1", "w1:p1"]);

        let applied = state.apply(&event(json!({
            "event": "pane.agent_status_changed",
            "data": {"pane_id": "w1:p1", "workspace_id": "w1", "agent_status": "blocked"}
        })));
        assert_eq!(applied, Applied::Updated);
        assert_eq!(board_ids(&state), ["w1:p1", "w1:p2", "w2:p1"]);
    }

    #[test]
    fn repeated_status_is_unchanged() {
        let mut state = snapshot();
        let changed = event(json!({
            "event": "pane.agent_status_changed",
            "data": {"pane_id": "w1:p2", "workspace_id": "w1", "agent_status": "working"}
        }));
        assert_eq!(state.apply(&changed), Applied::Unchanged);
    }

    #[test]
    fn focus_moves_between_panes_and_tabs() {
        let mut state = snapshot();
        let applied = state.apply(&event(json!({
            "event": "pane_focused",
            "data": {"type": "pane_focused", "pane_id": "w1:p2", "workspace_id": "w1"}
        })));
        assert_eq!(applied, Applied::Updated);
        assert_eq!(state.focused_pane_id.as_deref(), Some("w1:p2"));
        assert!(state.pane("w1:p2").is_some_and(|p| p.focused));
        assert!(state.pane("w1:p1").is_some_and(|p| !p.focused));

        state.apply(&event(json!({
            "event": "tab_focused",
            "data": {"type": "tab_focused", "tab_id": "w1:t2", "workspace_id": "w1"}
        })));
        assert!(state.tab("w1:t2").is_some_and(|t| t.focused));
        assert!(state.tab("w1:t1").is_some_and(|t| !t.focused));
        assert!(
            state.tab("w2:t1").is_some_and(|t| t.focused),
            "other workspace untouched"
        );
        assert_eq!(
            state.workspace("w1").map(|w| w.active_tab_id.as_str()),
            Some("w1:t2")
        );
    }

    #[test]
    fn renames_apply_in_place() {
        let mut state = snapshot();
        state.apply(&event(json!({
            "event": "workspace_renamed",
            "data": {"type": "workspace_renamed", "workspace_id": "w2", "label": "backend"}
        })));
        state.apply(&event(json!({
            "event": "tab_renamed",
            "data": {"type": "tab_renamed", "workspace_id": "w1", "tab_id": "w1:t2", "label": "tests"}
        })));
        assert_eq!(
            state.workspace("w2").map(|w| w.label.as_str()),
            Some("backend")
        );
        assert_eq!(state.tab("w1:t2").map(|t| t.label.as_str()), Some("tests"));
    }

    #[test]
    fn agent_names_come_from_the_snapshot() {
        let state = snapshot();
        assert_eq!(
            state.agent_names.get("w1:p1").map(String::as_str),
            Some("reviewer")
        );
        assert!(!state.agent_names.contains_key("w1:p2"), "unnamed agent");
    }

    #[test]
    fn output_revision_only_moves_forward() {
        let mut state = snapshot();
        let older = event(json!({
            "event": "pane_output_changed",
            "data": {"type": "pane_output_changed", "pane_id": "w2:p1", "workspace_id": "w2", "revision": 4}
        }));
        assert_eq!(state.apply(&older), Applied::Unchanged);
        let newer = event(json!({
            "event": "pane_output_changed",
            "data": {"type": "pane_output_changed", "pane_id": "w2:p1", "workspace_id": "w2", "revision": 12}
        }));
        assert_eq!(state.apply(&newer), Applied::Updated);
        assert_eq!(state.pane("w2:p1").map(|p| p.revision), Some(12));
    }

    #[test]
    fn structural_and_unknown_events_need_a_snapshot() {
        let mut state = snapshot();
        for value in [
            json!({"event": "pane_closed", "data": {"type": "pane_closed", "pane_id": "w1:p1", "workspace_id": "w1"}}),
            json!({"event": "layout_updated", "data": {"type": "layout_updated", "layout": {}}}),
            json!({"event": "pane_sparkled", "data": {"type": "pane_sparkled"}}),
            json!({"event": "pane.agent_status_changed",
                   "data": {"pane_id": "w9:p1", "workspace_id": "w9", "agent_status": "done"}}),
        ] {
            assert_eq!(state.apply(&event(value)), Applied::NeedsSnapshot);
        }
        assert_eq!(state, snapshot(), "nothing applied");
    }

    #[test]
    fn attention_only_for_new_waits_and_finishes() {
        let before = snapshot();
        let mut after = before.clone();
        assert!(after.attention_since(&before).is_empty(), "nothing changed");

        let set = |state: &mut SessionState, pane: &str, status: &str| {
            state.apply(&event(json!({
                "event": "pane.agent_status_changed",
                "data": {"pane_id": pane, "workspace_id": "w1", "agent_status": status}
            })));
        };
        set(&mut after, "w1:p1", "blocked"); // idle -> blocked
        set(&mut after, "w1:p2", "done"); // working -> done
        assert_eq!(after.attention_since(&before), ["w1:p1", "w1:p2"]);

        // Still blocked and done in the next state: no second notice.
        let again = after.clone();
        assert!(again.attention_since(&after).is_empty());

        // w2:p1 was done before the app looked; staying done is not news.
        assert!(!after.attention_since(&before).contains(&"w2:p1".to_owned()));
    }

    #[test]
    fn shells_never_need_attention() {
        let before = snapshot();
        let mut after = before.clone();
        if let Some(shell) = after.panes.iter_mut().find(|p| p.pane_id == "w2:p2") {
            shell.agent_status = AgentStatus::Blocked;
        }
        assert!(after.attention_since(&before).is_empty());
    }

    fn layout_event(tab: &str, panes: &[(&str, u16)]) -> Event {
        let panes: Vec<_> = panes
            .iter()
            .map(|(id, width)| {
                json!({"pane_id": id, "rect": {"x": 0, "y": 0, "width": width, "height": 40}})
            })
            .collect();
        event(json!({
            "event": "layout_updated",
            "data": {"type": "layout_updated", "layout": {
                "workspace_id": "w2", "tab_id": tab, "zoomed": false,
                "area": {"x": 0, "y": 0, "width": 120, "height": 40},
                "focused_pane_id": "w2:p1", "panes": panes, "splits": []
            }}
        }))
    }

    #[test]
    fn snapshot_keeps_layouts() {
        let state = snapshot();
        let layout = state.layout("w2:t1");
        assert_eq!(layout.map(|l| l.panes.len()), Some(2));
        assert!(state.layout("w1:t1").is_none());
    }

    #[test]
    fn resize_applies_in_place() {
        let mut state = snapshot();
        let resized = layout_event("w2:t1", &[("w2:p1", 80), ("w2:p2", 40)]);
        assert_eq!(state.apply(&resized), Applied::Updated);
        assert_eq!(
            state.layout("w2:t1").map(|l| l.panes[0].rect.width),
            Some(80)
        );
        assert_eq!(state.apply(&resized), Applied::Unchanged);
    }

    #[test]
    fn layout_with_other_panes_needs_a_snapshot() {
        let mut state = snapshot();
        let split = layout_event("w2:t1", &[("w2:p1", 40), ("w2:p2", 40), ("w2:p3", 40)]);
        assert_eq!(state.apply(&split), Applied::NeedsSnapshot);
        let unknown_tab = layout_event("w2:t9", &[("w2:p1", 120)]);
        assert_eq!(state.apply(&unknown_tab), Applied::NeedsSnapshot);
        assert_eq!(state, snapshot(), "nothing applied");
    }

    #[test]
    fn pane_updated_in_another_tab_needs_a_snapshot() {
        let mut state = snapshot();
        let moved = event(json!({
            "event": "pane_updated",
            "data": {"type": "pane_updated", "pane": {
                "pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t2", "agent_status": "idle"
            }}
        }));
        assert_eq!(state.apply(&moved), Applied::NeedsSnapshot);
    }

    fn with_tokens(tokens: &[(&str, &str)]) -> SessionState {
        let mut state = snapshot();
        state.panes[1].tokens = tokens
            .iter()
            .map(|(name, value)| ((*name).to_owned(), (*value).to_owned()))
            .collect();
        state
    }

    #[test]
    fn open_requests_join_the_url_pieces() {
        let state = with_tokens(&[
            ("open_id", "1700000000-42"),
            ("open_url_0", "http://localhost:5173/"),
            ("open_url_1", "mockup?x=1"),
            ("other", "kept apart"),
        ]);
        assert_eq!(
            state.open_requests(),
            vec![OpenRequest {
                pane_id: "w1:p2".into(),
                open_id: "1700000000-42".into(),
                url: "http://localhost:5173/mockup?x=1".into(),
            }]
        );
        // Every client sees the same request until it is gone.
        assert_eq!(state.open_requests(), state.open_requests());
        assert!(snapshot().open_requests().is_empty());
    }

    #[test]
    fn open_requests_end_at_a_gap() {
        let state = with_tokens(&[
            ("open_id", "1-1"),
            ("open_url_0", "https://example.com/"),
            ("open_url_2", "ignored"),
        ]);
        assert_eq!(state.open_requests()[0].url, "https://example.com/");
    }

    #[test]
    fn open_requests_need_an_id_and_a_web_scheme() {
        for tokens in [
            &[("open_url_0", "https://example.com/")][..],
            &[("open_id", ""), ("open_url_0", "https://example.com/")],
            &[("open_id", "1-1"), ("open_url_0", "file:///etc/passwd")],
            &[("open_id", "1-1"), ("open_url_0", "javascript:alert(1)")],
            &[("open_id", "1-1"), ("open_url_0", "https://")],
            &[("open_id", "1-1"), ("open_url_0", "https://a b")],
            &[("open_id", "1-1")],
        ] {
            assert!(with_tokens(tokens).open_requests().is_empty(), "{tokens:?}");
        }
        let upper = with_tokens(&[("open_id", "1-1"), ("open_url_0", "HTTPS://example.com")]);
        assert_eq!(upper.open_requests().len(), 1);
    }
}
