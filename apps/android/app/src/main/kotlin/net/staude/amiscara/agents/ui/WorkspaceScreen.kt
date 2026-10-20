package net.staude.amiscara.agents.ui

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.PrimaryScrollableTabRow
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.HostSession
import net.staude.amiscara.agents.core.HostStatus
import net.staude.amiscara.agents.core.PaneItem
import net.staude.amiscara.agents.core.TabItem
import net.staude.amiscara.agents.model.PaneModel
import net.staude.amiscara.agents.model.TerminalAppearance

/** Follows a pane while it is on screen; a new session starts a new follower. */
@Composable
private fun rememberPane(session: HostSession, paneId: String, live: Boolean): PaneModel {
    val model = remember(session, paneId) { PaneModel(session, paneId, live) }
    DisposableEffect(model) { onDispose { model.stop() } }
    LaunchedEffect(model, live) { model.setLive(live) }
    return model
}

/** The terminal theme from the settings and the app's look. */
@Composable
fun rememberTerminalTheme(app: AmiscaraApp): Pair<TerminalTheme, Float> {
    val prefs by app.settings.terminal.collectAsStateWithLifecycle()
    val systemDark = isSystemInDarkTheme()
    val dark = when (prefs.appearance) {
        TerminalAppearance.APP -> systemDark
        TerminalAppearance.LIGHT -> false
        TerminalAppearance.DARK -> true
    }
    val theme = remember(prefs.scheme, dark, prefs.minContrast) { TerminalTheme.of(prefs.scheme, dark, prefs.minContrast) }
    return theme to prefs.fontSize
}

/**
 * One space: its tabs, the selected pane's terminal and the input bar. On
 * a wide screen a split tab shows its panes side by side as herdr draws
 * them; on a phone a row of chips picks the pane.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WorkspaceScreen(
    app: AmiscaraApp,
    hostId: String,
    workspaceId: String,
    initialPaneId: String?,
    wide: Boolean,
    back: (() -> Unit)?,
) {
    val hosts by app.hosts.hosts.collectAsStateWithLifecycle()
    val updates by app.connections.updates.collectAsStateWithLifecycle()
    val host = hosts.firstOrNull { it.id == hostId }
    val update = updates[hostId]
    val workspace = update?.workspaces?.firstOrNull { it.workspaceId == workspaceId }
    val connected = update?.status == HostStatus.Live

    var tabId by rememberSaveable(hostId, workspaceId, initialPaneId) {
        mutableStateOf(
            workspace?.tabs?.firstOrNull { tab -> tab.panes.any { it.paneId == initialPaneId } }?.tabId
                ?: workspace?.activeTabId,
        )
    }
    val tab = workspace?.tabs?.firstOrNull { it.tabId == tabId } ?: workspace?.tabs?.firstOrNull()
    var paneId by rememberSaveable(hostId, workspaceId, initialPaneId) { mutableStateOf(initialPaneId) }
    val pane = tab?.panes?.firstOrNull { it.paneId == paneId } ?: tab?.let(::defaultPane)

    var searching by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    var currentHit by remember { mutableIntStateOf(0) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(workspace?.name ?: "", maxLines = 1)
                        host?.let { Text(it.name, style = MaterialTheme.typography.bodySmall) }
                    }
                },
                navigationIcon = {
                    back?.let {
                        IconButton(onClick = it) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                        }
                    }
                },
                actions = {
                    IconButton(onClick = { searching = !searching }) {
                        Icon(Icons.Default.Search, contentDescription = stringResource(R.string.search))
                    }
                },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding()) {
            if (host == null || workspace == null || tab == null || pane == null) {
                Text(
                    stringResource(if (update == null || !connected) R.string.no_connection else R.string.space_gone),
                    Modifier.padding(16.dp),
                )
                return@Column
            }
            if (workspace.tabs.size > 1) {
                PrimaryScrollableTabRow(selectedTabIndex = workspace.tabs.indexOf(tab).coerceAtLeast(0), edgePadding = 8.dp) {
                    workspace.tabs.forEach { item ->
                        Tab(
                            selected = item.tabId == tab.tabId,
                            onClick = {
                                tabId = item.tabId
                                paneId = null
                            },
                            text = {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    AgentDot(item.agentState.takeIf { item.panes.any { it.agent != null } })
                                    Text(item.label, maxLines = 1)
                                }
                            },
                        )
                    }
                }
            }
            val split = wide && tab.panes.size > 1 && tab.layout != null
            if (!split && tab.panes.size > 1) {
                LazyRow(Modifier.padding(horizontal = 8.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    items(tab.panes, key = { it.paneId }) { item ->
                        FilterChip(
                            selected = item.paneId == pane.paneId,
                            onClick = { paneId = item.paneId },
                            label = { Text(paneLabel(item), maxLines = 1) },
                            leadingIcon = { AgentDot(item.agentState.takeIf { item.agent != null }) },
                        )
                    }
                }
            }

            val session = app.connections.session(hostId)
            val (theme, fontSize) = rememberTerminalTheme(app)
            val setFont = { size: Float -> app.settings.setTerminal(app.settings.terminal.value.copy(fontSize = size)) }
            if (session == null) {
                Text(stringResource(R.string.no_connection), Modifier.padding(16.dp).weight(1f))
            } else {
                val selected = rememberPane(session, pane.paneId, live = true)
                val state by selected.flow.collectAsStateWithLifecycle()
                val hits = remember(state.content, query, searching) { if (searching) searchHits(state.content, query) else emptyList() }
                if (searching) {
                    SearchBar(query, { query = it; currentHit = 0 }, hits.size, currentHit, { currentHit = it }) {
                        searching = false
                        query = ""
                    }
                }
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    val selectedView = @Composable {
                        TerminalView(
                            state, theme, fontSize, Modifier.fillMaxSize(),
                            onFontSize = setFont,
                            onLoadMore = selected::loadMoreHistory,
                            onHideHistory = selected::hideHistory,
                            hits = hits,
                            currentHit = currentHit,
                        )
                    }
                    if (split) {
                        SplitPanes(tab, pane.paneId, session, theme, fontSize, onSelect = { paneId = it }, selectedView = selectedView)
                    } else {
                        selectedView()
                    }
                }
            }
            InputBar(app, host, pane, connected)
        }
    }
}

/** The pane a tab opens with: herdr's focused one, else its first agent. */
private fun defaultPane(tab: TabItem): PaneItem? =
    tab.panes.firstOrNull { it.focused } ?: tab.panes.firstOrNull { it.agent != null } ?: tab.panes.firstOrNull()

@Composable
private fun paneLabel(pane: PaneItem): String = pane.name ?: pane.agent ?: pane.title.ifEmpty { stringResource(R.string.shell) }

/**
 * A split tab as herdr draws it: every pane at its place, the selected one
 * live and framed, the others read slowly. A tap selects a pane.
 */
@Composable
private fun SplitPanes(
    tab: TabItem,
    selectedId: String,
    session: HostSession,
    theme: TerminalTheme,
    fontSize: Float,
    onSelect: (String) -> Unit,
    selectedView: @Composable () -> Unit,
) {
    val layout = tab.layout ?: return
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val cellW = maxWidth / layout.columns.toInt().coerceAtLeast(1)
        val cellH = maxHeight / layout.rows.toInt().coerceAtLeast(1)
        for (frame in layout.panes) {
            val isSelected = frame.paneId == selectedId
            Box(
                Modifier
                    .offset(cellW * frame.x.toInt(), cellH * frame.y.toInt())
                    .size(cellW * frame.width.toInt(), cellH * frame.height.toInt())
                    .padding(1.dp)
                    .border(if (isSelected) 2.dp else 1.dp, if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant)
                    .then(if (isSelected) Modifier else Modifier.clickable { onSelect(frame.paneId) }),
            ) {
                if (isSelected) {
                    selectedView()
                } else {
                    // The selected pane has its own live follower above.
                    val model = rememberPane(session, frame.paneId, live = false)
                    val state by model.flow.collectAsStateWithLifecycle()
                    TerminalView(state, theme, fontSize * 0.85f, Modifier.fillMaxSize(), interactive = false)
                }
            }
        }
    }
}

@Composable
private fun SearchBar(
    query: String,
    onQuery: (String) -> Unit,
    count: Int,
    current: Int,
    onCurrent: (Int) -> Unit,
    close: () -> Unit,
) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        TextField(
            value = query,
            onValueChange = onQuery,
            placeholder = { Text(stringResource(R.string.search_placeholder)) },
            singleLine = true,
            modifier = Modifier.weight(1f).focusRequester(focus),
        )
        Text(
            when {
                query.isBlank() -> ""
                count == 0 -> stringResource(R.string.search_none)
                else -> stringResource(R.string.search_count, current + 1, count)
            },
            Modifier.padding(horizontal = 8.dp),
            style = MaterialTheme.typography.bodySmall,
        )
        IconButton(onClick = { onCurrent((current - 1 + count) % count) }, enabled = count > 0) {
            Icon(Icons.Default.KeyboardArrowUp, contentDescription = stringResource(R.string.search_previous))
        }
        IconButton(onClick = { onCurrent((current + 1) % count) }, enabled = count > 0) {
            Icon(Icons.Default.KeyboardArrowDown, contentDescription = stringResource(R.string.search_next))
        }
        IconButton(onClick = close) { Icon(Icons.Default.Close, contentDescription = stringResource(R.string.search_close)) }
    }
}
