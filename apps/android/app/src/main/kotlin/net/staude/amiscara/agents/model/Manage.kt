package net.staude.amiscara.agents.model

import net.staude.amiscara.agents.core.AgentState
import net.staude.amiscara.agents.core.WorkspaceItem

// Creating, renaming and closing in herdr; the rules of `manage.svelte.ts`.

/**
 * The space a new worktree starts from: herdr wants the repository's main
 * checkout, so a linked worktree hands over to its repository's space.
 * `null` outside Git.
 */
fun repositoryOf(workspace: WorkspaceItem, all: List<WorkspaceItem>): WorkspaceItem? =
    if (workspace.worktreeName == null) {
        workspace.takeIf { it.branch != null || it.repoKey != null }
    } else {
        all.firstOrNull { it.repoKey == workspace.repoKey && it.worktreeName == null }
    }

/** The linked worktree spaces a repository's space closes with it. */
fun linkedWorktrees(workspace: WorkspaceItem, all: List<WorkspaceItem>): List<WorkspaceItem> =
    if (workspace.worktreeName == null && workspace.repoKey != null) {
        all.filter { it.repoKey == workspace.repoKey && it.worktreeName != null }
    } else {
        emptyList()
    }

/** The most urgent state among spaces about to close, for the warning. */
fun closingState(spaces: List<WorkspaceItem>): AgentState {
    val states = spaces.map { it.agentState }
    return when {
        AgentState.BLOCKED in states -> AgentState.BLOCKED
        AgentState.WORKING in states -> AgentState.WORKING
        else -> states.firstOrNull() ?: AgentState.UNKNOWN
    }
}

/** herdr's refusals of an agent name, in German. */
fun renameMessage(text: String): String = when {
    "invalid_agent_name" in text -> "Nur Kleinbuchstaben, Ziffern, - und _ sind erlaubt, am Anfang ein Buchstabe."
    "agent_name_taken" in text -> "Diesen Namen trägt schon ein anderer Agent."
    else -> text
}
