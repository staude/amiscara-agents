package net.staude.amiscara.agents.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.PaneContent
import net.staude.amiscara.agents.core.ScrollStep
import net.staude.amiscara.agents.model.PaneModel
import net.staude.amiscara.agents.model.TerminalPrefs

/** One search hit: line index and character range in that line. */
data class SearchHit(val line: Int, val range: IntRange)

/** All hits of `query` in the content, ignoring case. */
fun searchHits(content: PaneContent?, query: String): List<SearchHit> {
    if (content == null || query.isBlank()) return emptyList()
    val hits = mutableListOf<SearchHit>()
    content.lines.forEachIndexed { index, line ->
        val text = line.spans.joinToString("") { it.text }
        var from = text.indexOf(query, ignoreCase = true)
        while (from >= 0) {
            hits += SearchHit(index, from until from + query.length)
            from = text.indexOf(query, from + query.length, ignoreCase = true)
        }
    }
    return hits
}

/**
 * The screen of a pane, with scrollback once loaded, like
 * `TerminalScreenView.swift`: lines keep the pane's width and scroll both
 * ways, pinch changes the font size, the view stays at the bottom while
 * the user has not scrolled up. `interactive` false draws a pane beside
 * the selected one without history and gestures. With [fullscreen] the
 * history row of a full-screen agent fetches its transcript or pages
 * through its view (#187).
 */
@Composable
fun TerminalView(
    state: PaneModel.State,
    theme: TerminalTheme,
    fontSize: Float,
    modifier: Modifier = Modifier,
    interactive: Boolean = true,
    /** Long lines wrap at the view width instead of scrolling sideways (#191). */
    wrap: Boolean = false,
    onFontSize: (Float) -> Unit = {},
    onLoadMore: () -> Unit = {},
    onHideHistory: () -> Unit = {},
    fullscreen: FullscreenActions? = null,
    hits: List<SearchHit> = emptyList(),
    currentHit: Int = -1,
) {
    val content = state.content
    val lines = content?.lines.orEmpty()
    val textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = fontSize.sp, lineHeight = (fontSize * 1.2f).sp)
    val measurer = rememberTextMeasurer()
    val cellWidth = remember(fontSize) { measurer.measure("M", textStyle).size.width }
    val columns = remember(content) { lines.maxOfOrNull { line -> line.spans.sumOf { it.width.toInt() } } ?: 0 }
    val highlight = Color(0x80FFD60A)
    val current = Color(0xFFFF9F0A)
    val annotated = remember(content, theme, hits, currentHit) {
        val marks = hits.withIndex().groupBy(
            { it.value.line },
            { it.value.range to if (it.index == currentHit) current else highlight },
        )
        lines.mapIndexed { index, line -> theme.line(line, marks[index].orEmpty()) }
    }

    val list = rememberLazyListState()
    var stickToBottom by remember { mutableStateOf(true) }
    // History rows are put on top: an item's key is its distance from the
    // bottom, so the visible lines keep their place when history arrives.
    LaunchedEffect(list.isScrollInProgress) {
        if (!list.isScrollInProgress) stickToBottom = !list.canScrollForward
    }
    LaunchedEffect(content) {
        if (stickToBottom && lines.isNotEmpty()) list.scrollToItem(lines.size)
    }
    LaunchedEffect(currentHit, hits) {
        hits.getOrNull(currentHit)?.let {
            stickToBottom = false
            list.scrollToItem(it.line + 1)
        }
    }

    val size by rememberUpdatedState(fontSize)
    var pinch by remember { mutableFloatStateOf(1f) }
    val zoom = rememberTransformableState { factor, _, _ ->
        pinch *= factor
        val next = (size * pinch).coerceIn(TerminalPrefs.FONT_RANGE)
        if (kotlin.math.abs(next - size) >= 1f) {
            onFontSize(kotlin.math.round(next))
            pinch = 1f
        }
    }

    BoxWithConstraints(
        modifier
            .background(theme.background.color)
            .then(if (interactive) Modifier.transformable(zoom, canPan = { false }) else Modifier),
    ) {
        val density = LocalDensity.current
        val contentWidth = with(density) { (columns * cellWidth).toDp() + 16.dp }
        val width = if (contentWidth > maxWidth) contentWidth else maxWidth
        if (content == null) {
            Text(
                state.error ?: stringResource(R.string.loading),
                color = theme.foreground.color,
                modifier = Modifier.align(Alignment.Center).padding(16.dp),
            )
            return@BoxWithConstraints
        }
        val scroll = if (wrap) Modifier else Modifier.horizontalScroll(rememberScrollState())
        Box(Modifier.fillMaxSize().then(scroll)) {
            SelectionContainer {
                LazyColumn(
                    state = list,
                    modifier = (if (wrap) Modifier.fillMaxWidth() else Modifier.width(width)).fillMaxHeight().padding(horizontal = 8.dp),
                ) {
                    item(key = "history") {
                        if (interactive) HistoryRow(state, theme, onLoadMore, onHideHistory, fullscreen)
                    }
                    itemsIndexed(annotated, key = { index, _ -> lines.size - index }) { index, line ->
                        // A frame would break apart when wrapped: clip it instead.
                        val soft = wrap && !isRule(lines[index].spans.joinToString("") { it.text })
                        Text(
                            line,
                            style = textStyle,
                            color = theme.foreground.color,
                            softWrap = soft,
                            maxLines = if (soft) Int.MAX_VALUE else 1,
                            overflow = TextOverflow.Clip,
                        )
                    }
                }
            }
        }
    }
}

/** The steps through a full-screen agent; both move its view on the host too. */
class FullscreenActions(val loadHistory: () -> Unit, val scroll: (ScrollStep) -> Unit)

@Composable
private fun HistoryRow(
    state: PaneModel.State,
    theme: TerminalTheme,
    onLoadMore: () -> Unit,
    onHide: () -> Unit,
    fullscreen: FullscreenActions?,
) {
    val color = theme.foreground.color.copy(alpha = 0.7f)
    val loaded = state.content?.historyLines?.toInt() ?: 0
    val truncated = state.content?.truncated == true
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            when {
                state.isLoadingHistory || state.loadingAgentHistory -> {
                    CircularProgressIndicator(Modifier.padding(8.dp).width(16.dp), strokeWidth = 2.dp, color = color)
                    Text(
                        stringResource(if (state.loadingAgentHistory) R.string.history_agent_loading else R.string.history_loading),
                        color = color,
                    )
                }
                state.agentHistory != null && fullscreen != null -> {
                    Text(stringResource(R.string.history_agent), color = color, modifier = Modifier.padding(8.dp))
                    TextButton(onClick = fullscreen.loadHistory) { Text(stringResource(R.string.history_agent_reload), color = color) }
                }
                state.canLoadMoreHistory -> TextButton(onClick = onLoadMore) { Text(stringResource(R.string.history_more), color = color) }
                state.hasNoHistory && fullscreen != null -> {
                    TextButton(onClick = fullscreen.loadHistory) { Text(stringResource(R.string.history_agent_load), color = color) }
                    IconButton(onClick = { fullscreen.scroll(ScrollStep.PAGE_UP) }) {
                        Icon(Icons.Default.KeyboardArrowUp, contentDescription = stringResource(R.string.scroll_page_up), tint = color)
                    }
                    IconButton(onClick = { fullscreen.scroll(ScrollStep.PAGE_DOWN) }) {
                        Icon(Icons.Default.KeyboardArrowDown, contentDescription = stringResource(R.string.scroll_page_down), tint = color)
                    }
                    TextButton(onClick = { fullscreen.scroll(ScrollStep.BOTTOM) }) { Text(stringResource(R.string.scroll_bottom), color = color) }
                }
                state.hasNoHistory -> Text(stringResource(R.string.history_none), color = color, modifier = Modifier.padding(8.dp))
                loaded > 0 && truncated ->
                    Text(pluralStringResource(R.plurals.history_limit, loaded, loaded), color = color, modifier = Modifier.padding(8.dp))
                loaded > 0 -> Text(stringResource(R.string.history_start), color = color, modifier = Modifier.padding(8.dp))
            }
            if (loaded > 0 && !state.isLoadingHistory && !state.loadingAgentHistory) {
                TextButton(onClick = onHide) { Text(stringResource(R.string.history_hide), color = color) }
            }
        }
        state.agentError?.let { Text(it, color = color, modifier = Modifier.padding(8.dp)) }
    }
}

/**
 * A row drawn only with box-drawing and block characters, such as a frame
 * or a rule of a full-screen program: wrapping would break it apart, so a
 * wrapping view clips it instead (#191).
 */
internal fun isRule(text: String): Boolean =
    text.any { it in '\u2500'..'\u259F' } && text.all { it.isWhitespace() || it in '\u2500'..'\u259F' }
