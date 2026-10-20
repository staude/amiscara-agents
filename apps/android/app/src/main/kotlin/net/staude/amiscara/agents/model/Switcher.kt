package net.staude.amiscara.agents.model

import net.staude.amiscara.agents.core.AgentState
import net.staude.amiscara.agents.core.SessionUpdate

/** One hit of the quick switcher: a space or an agent on some host. */
data class SwitcherEntry(
    val selection: SpaceSelection,
    val isAgent: Boolean,
    val title: String,
    val subtitle: String?,
    val hostName: String,
    val state: AgentState?,
    /** Texts a query is matched against, most important first. */
    val fields: List<String>,
)

/** Spaces in sidebar order, then agents, per host; like `switcher.ts`. */
fun switcherEntries(hosts: List<HostConfig>, updates: Map<String, SessionUpdate>): List<SwitcherEntry> = hosts.flatMap { host ->
    val update = updates[host.id] ?: return@flatMap emptyList()
    val spaces = arrange(update).map { (ws, nested) ->
        SwitcherEntry(
            selection = SpaceSelection(host.id, ws.workspaceId, null),
            isAgent = false,
            title = if (nested) ws.branch ?: ws.worktreeName ?: ws.label else ws.name,
            subtitle = (if (nested) ws.label else listOfNotNull(ws.group, ws.branch).joinToString(" · ")).ifEmpty { null },
            hostName = host.name,
            state = ws.agentState.takeIf { it != AgentState.UNKNOWN },
            fields = listOfNotNull(ws.name, ws.label, ws.branch, ws.worktreeName),
        )
    }
    val agents = update.board.map { agent ->
        val space = agent.workspaceGroup?.let { "${agent.workspaceName} ($it)" } ?: agent.workspaceName
        val tabs = update.workspaces.firstOrNull { it.workspaceId == agent.workspaceId }?.tabs?.size ?: 0
        val place = if (tabs > 1) "$space · ${agent.tabLabel}" else space
        SwitcherEntry(
            selection = SpaceSelection(host.id, agent.workspaceId, agent.paneId),
            isAgent = true,
            title = agent.name ?: agent.agent,
            subtitle = if (agent.title.isNotEmpty()) "$place · ${agent.title}" else place,
            hostName = host.name,
            state = agent.agentState,
            fields = listOf(agent.name ?: agent.agent, agent.agent, agent.workspaceLabel, agent.title, agent.tabLabel),
        )
    }
    spaces + agents
}

/**
 * Every word must appear in a field, as a substring or as letters in order
 * ("hrc" finds "herdr-remote-core"). Word starts rank above substrings,
 * substrings above scattered letters, the first field above the others.
 */
fun filterSwitcher(all: List<SwitcherEntry>, query: String): List<SwitcherEntry> {
    val words = query.lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
    if (words.isEmpty()) return all
    return all.withIndex()
        .mapNotNull { (index, entry) -> score(entry.fields, words)?.let { Triple(entry, index, it) } }
        .sortedWith(compareByDescending<Triple<SwitcherEntry, Int, Int>> { it.third }.thenBy { it.second })
        .map { it.first }
}

private fun score(fields: List<String>, words: List<String>): Int? {
    val lower = fields.map { it.lowercase() }
    var total = 0
    for (word in words) {
        var best: Int? = null
        lower.forEachIndexed { position, field ->
            val bonus = if (position == 0) 1 else 0
            val at = field.indexOf(word)
            val points = when {
                at >= 0 -> (if (at == 0 || !field[at - 1].isLetterOrDigit()) 6 else 4) + bonus
                subsequence(word, field) -> 1
                else -> null
            }
            if (points != null && points > (best ?: 0)) best = points
        }
        total += best ?: return null
    }
    return total
}

private fun subsequence(word: String, text: String): Boolean {
    var i = 0
    for (ch in text) {
        if (i < word.length && ch == word[i]) i++
        if (i == word.length) return true
    }
    return i == word.length
}
