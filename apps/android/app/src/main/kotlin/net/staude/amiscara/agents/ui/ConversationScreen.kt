package net.staude.amiscara.agents.ui

import android.content.ClipData
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.FfiException
import net.staude.amiscara.agents.core.TranscriptCursor
import net.staude.amiscara.agents.core.TranscriptEntry
import net.staude.amiscara.agents.core.TranscriptKind
import net.staude.amiscara.agents.model.inputErrorMessage
import net.staude.amiscara.agents.model.Texts

/**
 * The conversation of a Claude Code pane from its session file on the host
 * (#102): herdr keeps no scrollback for full-screen programs. Read only;
 * needs SFTP for the host's key.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConversationScreen(app: AmiscaraApp, hostId: String, paneId: String, back: () -> Unit) {
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboard.current
    var entries by remember { mutableStateOf(emptyList<TranscriptEntry>()) }
    var older by remember { mutableStateOf<TranscriptCursor?>(null) }
    var loading by remember { mutableStateOf(false) }
    var loaded by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val list = rememberLazyListState()

    fun load(reset: Boolean) {
        if (loading) return
        val session = app.connections.session(hostId) ?: run {
            error = Texts.get(R.string.no_connection)
            loaded = true
            return
        }
        scope.launch {
            loading = true
            try {
                val cursor = if (reset) null else older
                val page = withContext(Dispatchers.IO) { session.claudeHistory(paneId, cursor) }
                entries = if (reset) page.entries else page.entries + entries
                older = if (page.start > 0u) TranscriptCursor(page.sessionPath, page.start) else null
                error = null
                // Newest at the bottom; older entries above keep the view in place.
                if (reset) list.scrollToItem(entries.size) else list.scrollToItem(page.entries.size + 1)
            } catch (e: FfiException) {
                // The screen says "Verlauf nicht lesbar" already.
                error = if (e is FfiException.Files) e.message else inputErrorMessage(e)
            } finally {
                loading = false
                loaded = true
            }
        }
    }
    LaunchedEffect(paneId) { load(reset = true) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.conversation_title)) },
                navigationIcon = {
                    IconButton(onClick = back) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
                actions = {
                    TextButton(enabled = entries.isNotEmpty(), onClick = {
                        val text = entries.joinToString("\n\n") {
                            when (it.kind) {
                                TranscriptKind.USER -> "> ${it.text}"
                                TranscriptKind.TOOL -> "· ${it.text}"
                                TranscriptKind.ASSISTANT -> it.text
                            }
                        }
                        scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText(Texts.get(R.string.conversation_title), text))) }
                    }) { Text(stringResource(R.string.conversation_copy)) }
                    IconButton(enabled = !loading, onClick = { load(reset = true) }) {
                        Icon(Icons.Default.Refresh, contentDescription = stringResource(R.string.conversation_reload))
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                error != null && entries.isEmpty() ->
                    Text(stringResource(R.string.conversation_error, error.orEmpty()), Modifier.padding(16.dp))
                !loaded -> Text(stringResource(R.string.conversation_searching), Modifier.padding(16.dp))
                entries.isEmpty() -> Text(stringResource(R.string.conversation_empty), Modifier.padding(16.dp))
                else -> SelectionContainer {
                    LazyColumn(state = list, contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        item {
                            if (older != null) {
                                TextButton(enabled = !loading, onClick = { load(reset = false) }) {
                                    Text(stringResource(R.string.conversation_older))
                                }
                            } else {
                                Text(stringResource(R.string.conversation_start), style = MaterialTheme.typography.bodySmall)
                            }
                        }
                        items(entries) { Entry(it) }
                    }
                }
            }
        }
    }
}

@Composable
private fun Entry(entry: TranscriptEntry) {
    val time = entry.timestamp?.let(::shortTime)
    when (entry.kind) {
        TranscriptKind.USER -> Column(
            Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.secondaryContainer, MaterialTheme.shapes.medium).padding(10.dp),
        ) {
            Text(listOfNotNull(stringResource(R.string.conversation_you), time).joinToString(" · "), style = MaterialTheme.typography.labelSmall)
            Text(entry.text)
        }
        TranscriptKind.ASSISTANT -> Column(Modifier.padding(horizontal = 4.dp)) {
            time?.let { Text(it, style = MaterialTheme.typography.labelSmall) }
            Text(entry.text)
        }
        TranscriptKind.TOOL -> Text(
            "· ${entry.text}",
            Modifier.padding(horizontal = 4.dp),
            fontFamily = FontFamily.Monospace,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 4,
        )
    }
}

/** "14:05" today, else date and time, in German. */
private fun shortTime(stamp: String): String? = runCatching {
    val time = OffsetDateTime.parse(stamp).atZoneSameInstant(ZoneId.systemDefault())
    val pattern = if (time.toLocalDate() == LocalDate.now()) {
        DateTimeFormatter.ofPattern("HH:mm")
    } else {
        DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withLocale(Locale.GERMANY)
    }
    time.format(pattern)
}.getOrNull()
