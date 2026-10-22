package net.staude.amiscara.agents.model

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import net.staude.amiscara.agents.core.HostSession
import net.staude.amiscara.agents.core.PaneContent
import net.staude.amiscara.agents.core.PaneFollow
import net.staude.amiscara.agents.core.PaneObserver
import net.staude.amiscara.agents.core.maxHistoryLines

/**
 * The live screen of one pane, optionally with scrollback above it; like
 * `PaneModel.swift` and `pane.svelte.ts`. Only a live pane (the selected
 * one) loads history. Call [stop] when the pane leaves the screen.
 */
class PaneModel(session: HostSession, val paneId: String, live: Boolean) {
    data class State(
        val content: PaneContent? = null,
        val error: String? = null,
        /** History rows asked for; 0 shows only the visible screen. */
        val historyLines: Int = 0,
        /** Rows of the last screen-only read, to tell whether history added any. */
        val screenRows: Int = 0,
    ) {
        val isLoadingHistory: Boolean get() = historyLines > (content?.historyLines?.toInt() ?: 0)

        val canLoadMoreHistory: Boolean
            get() {
                val c = content ?: return false
                if (isLoadingHistory) return false
                return c.historyLines == 0u || (c.truncated && c.historyLines < maxHistory)
            }

        /** History read, but nothing above the screen: full-screen programs. */
        val hasNoHistory: Boolean
            get() {
                val c = content ?: return false
                if (isLoadingHistory || c.historyLines == 0u || c.truncated) return false
                return screenRows > 0 && c.lines.size <= screenRows
            }
    }

    private val state = MutableStateFlow(State())
    val flow: StateFlow<State> = state.asStateFlow()

    private var live = live
    private var unwrap = false
    private val follow: PaneFollow = session.followPanePaced(paneId, live, object : PaneObserver {
        override fun onContent(content: PaneContent) {
            state.value = state.value.let {
                it.copy(
                    content = content,
                    error = null,
                    screenRows = if (content.historyLines == 0u) content.lines.size else it.screenRows,
                )
            }
        }

        override fun onError(message: String) {
            // A closed pane leaves with the next session update; one herdr
            // restored without a terminal stays and is never readable.
            val text = if ("pane_not_found" in message) "Pane nicht lesbar." else message
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
        state.value = state.value.copy(historyLines = 0)
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
    }

    private companion object {
        val maxHistory = maxHistoryLines()
        val HISTORY_STEPS = listOf(200, 500, maxHistory.toInt())
    }
}
