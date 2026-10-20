package net.staude.amiscara.agents.widget

import android.content.Context
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import net.staude.amiscara.agents.core.AgentState
import net.staude.amiscara.agents.core.HostStatus
import net.staude.amiscara.agents.core.SessionUpdate
import net.staude.amiscara.agents.model.HostConfig
import net.staude.amiscara.agents.model.place

/**
 * What the widget shows, as `WidgetSnapshot` of the Apple apps: the agents
 * of all hosts, most urgent first, and when that was true. Kept in the
 * preferences, so the widget still has it after the process ended.
 */
@Serializable
data class WidgetSnapshot(val updated: Long = 0, val hosts: Int = 0, val agents: List<Agent> = emptyList()) {
    @Serializable
    data class Agent(
        val hostId: String,
        val hostName: String,
        val workspaceId: String,
        val paneId: String,
        /** "Space · Tab" as in the sidebar. */
        val place: String,
        /** The agent's custom name, else its kind (`claude`). */
        val name: String,
        val state: AgentState,
    )

    val waiting get() = agents.count { it.state == AgentState.BLOCKED }
    val working get() = agents.count { it.state == AgentState.WORKING }

    /** The same agents and hosts, whatever the time. */
    fun sameAs(other: WidgetSnapshot) = hosts == other.hosts && agents == other.agents

    companion object {
        /** From the live hosts only; `null` while none is connected. */
        fun of(hosts: List<HostConfig>, updates: Map<String, SessionUpdate>, now: Long): WidgetSnapshot? {
            val live = hosts.mapNotNull { host -> updates[host.id]?.takeIf { it.status is HostStatus.Live }?.let { host to it } }
            if (live.isEmpty() && hosts.isNotEmpty()) return null
            val agents = live.flatMap { (host, update) ->
                update.board.map { item ->
                    Agent(host.id, host.name, item.workspaceId, item.paneId, item.place(update), item.name ?: item.agent, item.agentState)
                }
            }.sortedBy { urgency(it.state) }
            return WidgetSnapshot(now, hosts.size, agents)
        }

        /** Waiting first, as on the board. */
        private fun urgency(state: AgentState) = when (state) {
            AgentState.BLOCKED -> 0
            AgentState.WORKING -> 1
            AgentState.DONE -> 2
            AgentState.IDLE -> 3
            AgentState.UNKNOWN -> 4
        }
    }
}

/** The latest [WidgetSnapshot], in memory and in the preferences. */
class WidgetData(context: Context) {
    private val prefs = context.getSharedPreferences("widget", Context.MODE_PRIVATE)
    private val state = MutableStateFlow(load())
    val snapshot: StateFlow<WidgetSnapshot> = state.asStateFlow()

    /**
     * Stores a new snapshot; true when the widget should show it: when
     * something changed, or to move its time on now and then.
     */
    fun save(value: WidgetSnapshot): Boolean {
        if (value.sameAs(state.value) && value.updated - state.value.updated < REFRESH_MS) return false
        prefs.edit { putString("snapshot", Json.encodeToString(value)) }
        state.value = value
        return true
    }

    private companion object {
        /** How old "Stand" may get while nothing changes. */
        const val REFRESH_MS = 5 * 60_000L
    }

    private fun load(): WidgetSnapshot =
        prefs.getString("snapshot", null)?.let { runCatching { Json.decodeFromString<WidgetSnapshot>(it) }.getOrNull() }
            ?: WidgetSnapshot()
}
