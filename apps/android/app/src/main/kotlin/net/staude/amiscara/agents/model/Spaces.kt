package net.staude.amiscara.agents.model

import net.staude.amiscara.agents.core.BoardItem
import net.staude.amiscara.agents.core.SessionUpdate
import net.staude.amiscara.agents.core.WorkspaceItem

// The sidebar's order, like `HostSidebar.swift` and `spaces.ts`: spaces in
// the core's order (worktrees after their repository, name groups
// together), agents most urgent first.

data class SpaceEntry(val workspace: WorkspaceItem, val nested: Boolean)

sealed interface SpaceBlock {
    data class Space(val entry: SpaceEntry) : SpaceBlock
    data class Group(val name: String, val entries: List<SpaceEntry>) : SpaceBlock
}

fun arrange(update: SessionUpdate): List<SpaceEntry> {
    val byId = update.workspaces.associateBy { it.workspaceId }
    return update.spaceOrder.mapNotNull { slot -> byId[slot.workspaceId]?.let { SpaceEntry(it, slot.nested) } }
}

/** The core keeps a group's spaces adjacent; a group ends at another one. */
fun blocks(entries: List<SpaceEntry>): List<SpaceBlock> {
    val out = mutableListOf<SpaceBlock>()
    for (entry in entries) {
        val group = entry.workspace.group
        val last = out.lastOrNull()
        when {
            group == null -> out += SpaceBlock.Space(entry)
            last is SpaceBlock.Group && last.name == group -> out[out.lastIndex] = last.copy(entries = last.entries + entry)
            else -> out += SpaceBlock.Group(group, listOf(entry))
        }
    }
    return out
}

/** "reviewer · claude" or "claude". */
val BoardItem.title: String get() = name?.let { "$it · $agent" } ?: agent

/** "Space · Tab" when the space has several tabs, else the space. */
fun BoardItem.place(update: SessionUpdate): String {
    val tabs = update.workspaces.firstOrNull { it.workspaceId == workspaceId }?.tabs?.size ?: 0
    return if (tabs > 1) "$workspaceName · $tabLabel" else workspaceName
}
