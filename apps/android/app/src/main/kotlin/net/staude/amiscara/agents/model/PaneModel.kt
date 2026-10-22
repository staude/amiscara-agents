package net.staude.amiscara.agents.model

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import net.staude.amiscara.agents.core.FfiException
import net.staude.amiscara.agents.core.HostSession
import net.staude.amiscara.agents.core.PaneContent
import net.staude.amiscara.agents.core.PaneFollow
import net.staude.amiscara.agents.core.PaneObserver
import net.staude.amiscara.agents.core.ScrollStep
import net.staude.amiscara.agents.core.maxHistoryLines
import net.staude.amiscara.agents.R

/**
 * The live screen of one pane, optionally with scrollback above it; like
 * `PaneModel.swift` and `pane.svelte.ts`. Only a live pane (the selected
 * one) loads history. Call [stop] when the pane leaves the screen.
 */
class PaneModel(private val session: HostSession, val paneId: String, live: Boolean) {
    data class State(
        /** The followed screen, with scrollback when asked for. */
        val followed: PaneContent? = null,
        val error: String? = null,
        /** History rows asked for; 0 shows only the visible screen. */
        val historyLines: Int = 0,
        /** Rows of the last screen-only read, to tell whether history added any. */
        val screenRows: Int = 0,
        /**
         * The transcript of a full-screen agent such as Claude Code, which
         * herdr keeps no scrollback for (#187): read once on request and
         * shown instead of the live screen until [hideHistory]. Plain text.
         */
        val agentHistory: PaneContent? = null,
        val loadingAgentHistory: Boolean = false,
        /** Why the last step through a full-screen agent failed. */
        val agentError: String? = null,
    ) {
        /** What the pane view shows: the agent's transcript, else the live screen. */
        val content: PaneContent? get() = agentHistory ?: followed

        val isLoadingHistory: Boolean get() = historyLines > (followed?.historyLines?.toInt() ?: 0)

        val canLoadMoreHistory: Boolean
            get() {
                val c = followed ?: return false
                if (agentHistory != null) return false
                if (isLoadingHistory) return false
                return c.historyLines == 0u || (c.truncated && c.historyLines < maxHistory)
            }

        /** History read, but nothing above the screen: full-screen programs. */
        val hasNoHistory: Boolean
            get() {
                val c = followed ?: return false
                if (agentHistory != null || isLoadingHistory || c.historyLines == 0u || c.truncated) return false
                return screenRows > 0 && c.lines.size <= screenRows
            }
    }

    private val state = MutableStateFlow(State())
    val flow: StateFlow<State> = state.asStateFlow()

    private var live = live
    private var unwrap = false
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    /** The app scrolled the agent's own view up, also on the host; undone in [stop]. */
    @Volatile private var agentScrolled = false
    private val follow: PaneFollow = session.followPanePaced(paneId, live, object : PaneObserver {
        override fun onContent(content: PaneContent) {
            state.value = state.value.let {
                it.copy(
                    followed = content,
                    error = null,
                    screenRows = if (content.historyLines == 0u) content.lines.size else it.screenRows,
                )
            }
        }

        override fun onError(message: String) {
            // A closed pane leaves with the next session update; one herdr
            // restored without a terminal stays and is never readable.
            val text = if ("pane_not_found" in message) Texts.get(R.string.error_pane_unreadable) else message
            state.value = state.value.copy(error = text)
        }
    })

    fun loadMoreHistory() {
        val current = state.value
        if (!live || !current.canLoadMoreHistory) return
        val next = HISTORY_STEPS.firstOrNull { it > current.historyLines } ?: maxHistory.toInt()
        state.value = current.copy(historyLines = next)
        follow.setHistoryLines(next.toUInt())
    }

    fun hideHistory() {
        state.value = state.value.copy(historyLines = 0, agentHistory = null, agentError = null)
        follow.setHistoryLines(0u)
    }

    /**
     * Joins the rows the terminal wrapped at the pane width, for a view that
     * wraps lines at its own width (#191). Drops loaded history, whose row
     * count would no longer match the screen's.
     */
    fun setUnwrap(value: Boolean) {
        if (value == unwrap) return
        unwrap = value
        if (state.value.historyLines > 0) hideHistory()
        follow.setUnwrap(value)
    }

    /**
     * Reads the transcript of the full-screen agent in the pane. herdr
     * scrolls the agent on the host through it and back down, which takes
     * a moment and works only while the agent is idle.
     */
    fun loadAgentHistory() {
        if (state.value.loadingAgentHistory) return
        state.value = state.value.copy(loadingAgentHistory = true, agentError = null)
        scope.launch {
            state.value = try {
                state.value.copy(agentHistory = session.agentHistory(paneId), loadingAgentHistory = false)
            } catch (e: FfiException) {
                state.value.copy(agentError = inputErrorMessage(e), loadingAgentHistory = false)
            }
        }
    }

    /** Scrolls the full-screen agent's own view; the live screen follows. */
    fun scrollAgent(step: ScrollStep) {
        agentScrolled = step != ScrollStep.BOTTOM
        state.value = state.value.copy(agentError = null)
        scope.launch {
            try {
                session.scrollAgent(paneId, step)
            } catch (e: FfiException) {
                state.value = state.value.copy(agentError = inputErrorMessage(e))
            }
        }
    }

    /** The fast pace for the selected pane, the slow one beside it. */
    fun setLive(value: Boolean) {
        if (value == live) return
        live = value
        follow.setLive(value)
        if (!value && state.value.historyLines > 0) hideHistory()
    }

    fun stop() {
        follow.stop()
        follow.close()
        if (agentScrolled) {
            scope.launch { runCatching { session.scrollAgent(paneId, ScrollStep.BOTTOM) } }
                .invokeOnCompletion { scope.cancel() }
        } else {
            scope.cancel()
        }
    }

    private companion object {
        val maxHistory = maxHistoryLines()
        val HISTORY_STEPS = listOf(200, 500, maxHistory.toInt())
    }
}
