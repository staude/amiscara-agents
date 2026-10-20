package net.staude.amiscara.agents.ui

import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.InputChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.AgentState
import net.staude.amiscara.agents.core.HostSession
import net.staude.amiscara.agents.core.PaneItem
import net.staude.amiscara.agents.model.HostConfig
import net.staude.amiscara.agents.model.liveEdit
import net.staude.amiscara.agents.model.shellQuoted

/** A picked file before it is uploaded with the prompt. */
private class Attachment(val data: ByteArray, val fileName: String?, val extension: String?, val preview: ImageBitmap?)

private val CompactButton = Modifier.height(36.dp)
private val CompactPadding = PaddingValues(horizontal = 14.dp)

/** Keys of the key bar: label and herdr key name. */
private val KEYS = listOf("Esc" to "esc", "Tab" to "tab", "⌃C" to "ctrl+c", "↑" to "up", "↓" to "down", "←" to "left", "→" to "right", "↩" to "enter")

/**
 * Under the pane: one-tap answers while an agent waits, quick replies, a
 * key bar, attachments and the composer (`InputBar.swift`,
 * `InputBar.svelte`). Prompts go to an agent with `agent.prompt`, to a
 * shell as typed text plus Enter.
 */
@Composable
fun InputBar(app: AmiscaraApp, host: HostConfig, pane: PaneItem, connected: Boolean, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val replies by app.settings.quickReplies.collectAsStateWithLifecycle()
    val isAgent = pane.agent != null
    val isBlocked = isAgent && pane.agentState == AgentState.BLOCKED
    val inputAllowed = host.allowInput != false
    val uploadAllowed = host.allowUpload == true
    val enabled = connected && inputAllowed

    var text by remember(pane.paneId) { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var error by remember(pane.paneId) { mutableStateOf<String?>(null) }
    val attachments = remember(pane.paneId) { mutableStateListOf<Attachment>() }
    var attachMenu by remember { mutableStateOf(false) }
    val uploadOff = stringResource(R.string.upload_off, host.name)

    // Live mode: while an agent's composer starts with "/", or after a
    // suggestion was taken with Tab, every change goes straight into the
    // agent's own input line, so Claude Code shows its suggestions. Never
    // while the agent waits: typed keys would answer its dialog.
    var liveTyped by remember(pane.paneId, isBlocked) { mutableStateOf("") }
    var liveAfterTab by remember(pane.paneId, isBlocked) { mutableStateOf(false) }
    val isLive = isAgent && !isBlocked && attachments.isEmpty() && (text.startsWith("/") || liveAfterTab)
    // Live input in order, without blocking the bar.
    val liveQueue = remember(pane.paneId) { Channel<(HostSession) -> Unit>(Channel.UNLIMITED) }
    LaunchedEffect(liveQueue) {
        for (step in liveQueue) app.connections.input(host.id, step).onFailure { error = it.message }
    }

    fun perform(action: suspend () -> Unit) {
        scope.launch {
            sending = true
            error = null
            try {
                action()
            } catch (e: Exception) {
                error = e.message
            } finally {
                sending = false
            }
        }
    }

    fun sendKeys(keys: List<String>) = perform { app.connections.input(host.id) { it.sendKeys(pane.paneId, keys) }.getOrThrow() }

    suspend fun submitText(full: String) = app.connections.input(host.id) { session ->
        if (isAgent) {
            session.sendPrompt(pane.paneId, full)
        } else {
            session.sendText(pane.paneId, full)
            session.sendKeys(pane.paneId, listOf("enter"))
        }
    }

    fun liveKey(key: String) {
        liveQueue.trySend { it.sendKeys(pane.paneId, listOf(key)) }
    }

    /** Brings the agent's input line to the composer text; newlines would submit. */
    fun syncLive(value: String, afterTab: Boolean) {
        if (!isAgent || isBlocked || attachments.isNotEmpty()) return
        val target = if (value.startsWith("/") || afterTab) value.replace("\n", " ") else ""
        val (erase, insert) = liveEdit(liveTyped, target)
        if (erase == 0 && insert.isEmpty()) return
        liveTyped = target
        liveQueue.trySend { session ->
            if (erase > 0) session.sendKeys(pane.paneId, List(erase) { "backspace" })
            if (insert.isNotEmpty()) session.sendText(pane.paneId, insert)
        }
    }

    /** A key of the bar; in live mode Enter, Tab and Esc also reset the composer. */
    fun barKey(key: String) {
        if (isLive && key in setOf("enter", "tab", "esc", "up", "down")) {
            liveKey(key)
            if (key in setOf("enter", "tab", "esc")) {
                liveAfterTab = key == "tab"
                liveTyped = ""
                text = ""
            }
        } else {
            sendKeys(listOf(key))
        }
    }

    fun submit() {
        if (isLive) {
            barKey("enter")
            return
        }
        val prompt = text.trim()
        if (prompt.isEmpty() && attachments.isEmpty()) {
            sendKeys(listOf("enter"))
            return
        }
        val pending = attachments.toList()
        perform {
            val paths = pending.map { item ->
                app.connections.input(host.id) { session ->
                    if (item.fileName != null) {
                        session.uploadNamedFile(item.data, item.fileName)
                    } else {
                        session.uploadFile(item.data, item.extension ?: "bin")
                    }
                }.getOrThrow()
            }
            // In a shell the paths become arguments: quoted, so no name adds a command.
            val shown = if (isAgent) paths else paths.map(::shellQuoted)
            val full = (listOf(prompt) + shown).filter { it.isNotEmpty() }.joinToString(if (isAgent) "\n" else " ")
            submitText(full).getOrThrow()
            text = ""
            attachments.removeAll(pending)
        }
    }

    fun add(uris: List<Uri>, images: Boolean) {
        if (!uploadAllowed) {
            error = uploadOff
            return
        }
        scope.launch {
            for (uri in uris) {
                runCatching { withContext(Dispatchers.IO) { readAttachment(context, uri, images) } }
                    .onSuccess { attachments += it }
                    .onFailure { error = it.message }
            }
        }
    }

    val pickPhotos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { add(it, images = true) }
    val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { add(it, images = false) }

    Surface(modifier.fillMaxWidth(), tonalElevation = 2.dp) {
        Column(Modifier.padding(vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            if (!inputAllowed) {
                Text(stringResource(R.string.input_off), Modifier.padding(horizontal = 12.dp), style = MaterialTheme.typography.bodySmall)
                return@Column
            }
            if (isBlocked) {
                LazyRow(
                    contentPadding = PaddingValues(horizontal = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    item {
                        Text(
                            stringResource(R.string.waiting_answer),
                            color = AgentState.BLOCKED.color(),
                            style = MaterialTheme.typography.labelLarge,
                        )
                    }
                    items(listOf("1", "2", "3")) { key ->
                        OutlinedButton(onClick = { sendKeys(listOf(key)) }, enabled = enabled && !sending, modifier = CompactButton, contentPadding = CompactPadding) {
                            Text(key)
                        }
                    }
                    item {
                        Button(onClick = { sendKeys(listOf("enter")) }, enabled = enabled && !sending, modifier = CompactButton, contentPadding = CompactPadding) {
                            Text(stringResource(R.string.answer_confirm))
                        }
                    }
                    item {
                        OutlinedButton(onClick = { sendKeys(listOf("esc")) }, enabled = enabled && !sending, modifier = CompactButton, contentPadding = CompactPadding) {
                            Text(stringResource(R.string.cancel))
                        }
                    }
                }
            }
            // Keys first, then the quick replies: one row keeps the terminal tall.
            LazyRow(
                contentPadding = PaddingValues(horizontal = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                items(KEYS) { (label, key) ->
                    AssistChip(onClick = { barKey(key) }, label = { Text(label) }, enabled = enabled && !sending)
                }
                item { VerticalDivider(Modifier.height(24.dp).padding(horizontal = 4.dp)) }
                items(replies) { reply ->
                    AssistChip(
                        onClick = { perform { submitText(reply).getOrThrow() } },
                        label = { Text(reply, maxLines = 1) },
                        enabled = enabled && !sending,
                    )
                }
            }
            if (attachments.isNotEmpty()) {
                LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    items(attachments.toList()) { item ->
                        InputChip(
                            selected = false,
                            onClick = { attachments.remove(item) },
                            label = { Text(item.fileName ?: item.extension.orEmpty(), maxLines = 1) },
                            avatar = item.preview?.let { { Image(it, contentDescription = null, Modifier.size(24.dp)) } },
                            trailingIcon = { Icon(Icons.Default.Close, contentDescription = stringResource(R.string.remove), Modifier.size(16.dp)) },
                        )
                    }
                }
            }
            if (isLive) {
                Text(stringResource(R.string.live_hint), Modifier.padding(horizontal = 12.dp), style = MaterialTheme.typography.bodySmall)
            }
            Row(Modifier.padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Box {
                    IconButton(onClick = { attachMenu = true }, enabled = enabled && !sending) {
                        Icon(Icons.Default.Add, contentDescription = stringResource(R.string.attach))
                    }
                    DropdownMenu(expanded = attachMenu, onDismissRequest = { attachMenu = false }) {
                        DropdownMenuItem(text = { Text(stringResource(R.string.attach_photo)) }, onClick = {
                            attachMenu = false
                            pickPhotos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                        })
                        DropdownMenuItem(text = { Text(stringResource(R.string.attach_file)) }, onClick = {
                            attachMenu = false
                            pickFiles.launch(arrayOf("*/*"))
                        })
                    }
                }
                OutlinedTextField(
                    value = text,
                    onValueChange = {
                        text = it
                        syncLive(it, liveAfterTab)
                    },
                    enabled = enabled,
                    placeholder = {
                        Text(if (isAgent) stringResource(R.string.composer_agent, pane.agent.orEmpty()) else stringResource(R.string.composer_shell))
                    },
                    maxLines = 6,
                    modifier = Modifier.weight(1f).onPreviewKeyEvent { event ->
                        // Hardware keyboard: Enter sends, Shift+Enter starts a new line.
                        if (event.type == KeyEventType.KeyDown && event.key == Key.Enter && !event.isShiftPressed) {
                            submit()
                            true
                        } else {
                            false
                        }
                    },
                )
                IconButton(onClick = ::submit, enabled = enabled && !sending) {
                    Icon(Icons.AutoMirrored.Filled.Send, contentDescription = stringResource(R.string.send))
                }
            }
            error?.let {
                Text(it, Modifier.padding(horizontal = 12.dp), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

/** Reads a picked file; images get a small preview and keep only their extension. */
private fun readAttachment(context: Context, uri: Uri, image: Boolean): Attachment {
    val resolver = context.contentResolver
    val data = resolver.openInputStream(uri)?.use { it.readBytes() } ?: error("Datei nicht lesbar")
    val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) cursor.getString(0) else null
    }
    val extension = name?.substringAfterLast('.', "")?.takeIf { it.isNotEmpty() }
        ?: resolver.getType(uri)?.substringAfter('/')
    val preview = if (image) {
        val options = BitmapFactory.Options().apply { inSampleSize = 8 }
        BitmapFactory.decodeByteArray(data, 0, data.size, options)?.asImageBitmap()
    } else {
        null
    }
    return Attachment(data, if (image) null else name, extension, preview)
}
