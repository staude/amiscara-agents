package net.staude.amiscara.agents.model

import kotlinx.serialization.Serializable
import net.staude.amiscara.agents.core.BoardItem
import net.staude.amiscara.agents.core.SessionUpdate
import net.staude.amiscara.agents.core.WorkspaceItem

// The sidebar's order, like `HostSidebar.swift` and `spaces.ts`: spaces in
// the core's order (worktrees after their repository, name groups
// together), agents most urgent first.

/** What the right side (or the next screen) shows: a space, maybe a pane. */
@Serializable
data class SpaceSelection(val hostId: String, val workspaceId: String, val paneId: String? = null)

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

/** Drag key of a whole name group; a space's is its workspace ID. */
const val GROUP_KEY_PREFIX = "group/"

/** Where a dragged row may go, as in `spaces.ts`. */
private sealed interface Level {
    data object Top : Level
    data class Group(val name: String) : Level
    data class Worktrees(val of: String) : Level
}

/** The rows that move with `key`, from `start` to before `end`. */
private class Segment(val level: Level, val start: Int, val end: Int)

/** A group with all its entries, a space with its nested worktrees. */
private fun segment(key: String, entries: List<SpaceEntry>): Segment? {
    val index = entries.indexOfFirst { it.workspace.workspaceId == key }
    if (index >= 0) {
        val entry = entries[index]
        if (entry.nested) {
            val head = (index - 1 downTo 0).firstOrNull { !entries[it].nested } ?: return null
            return Segment(Level.Worktrees(entries[head].workspace.workspaceId), index, index + 1)
        }
        var end = index + 1
        while (end < entries.size && entries[end].nested) end++
        val group = entry.workspace.group
        return Segment(if (group != null) Level.Group(group) else Level.Top, index, end)
    }
    if (!key.startsWith(GROUP_KEY_PREFIX)) return null
    val name = key.removePrefix(GROUP_KEY_PREFIX)
    val start = entries.indexOfFirst { it.workspace.group == name }
    if (start < 0) return null
    var end = start
    while (end < entries.size && entries[end].workspace.group == name) end++
    return Segment(Level.Top, start, end)
}

/**
 * The manual order after dropping `dragged` on `target` (#245): behind it
 * when it came from above, otherwise in front of it. `null` when both are
 * on different levels or the same row.
 */
fun moveSpace(entries: List<SpaceEntry>, dragged: String, target: String): List<String>? {
    if (dragged == target) return null
    val from = segment(dragged, entries) ?: return null
    val to = segment(target, entries) ?: return null
    if (from.level != to.level) return null
    val ids = entries.map { it.workspace.workspaceId }.toMutableList()
    val moving = ids.subList(from.start, from.end).toList()
    ids.subList(from.start, from.end).clear()
    val at = if (from.start < to.start) to.end - moving.size else to.start
    ids.addAll(at, moving)
    return ids
}

/** "reviewer · claude" or "claude". */
val BoardItem.title: String get() = name?.let { "$it · $agent" } ?: agent

/** "Space · Tab" when the space has several tabs, else the space. */
fun BoardItem.place(update: SessionUpdate): String {
    val tabs = update.workspaces.firstOrNull { it.workspaceId == workspaceId }?.tabs?.size ?: 0
    return if (tabs > 1) "$workspaceName · $tabLabel" else workspaceName
}
