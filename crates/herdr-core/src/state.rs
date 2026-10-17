use herdr_proto::{AgentStatus, Event, PaneInfo, SessionSnapshot, TabInfo, WorkspaceInfo};

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
    pub focused_pane_id: Option<String>,
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
            focused_pane_id: snapshot.focused_pane_id,
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
            | Event::LayoutUpdated {}
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
            "layouts": [],
            "agents": []
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
}
