package net.staude.amiscara.agents.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.FfiException
import net.staude.amiscara.agents.core.isValidSessionName
import net.staude.amiscara.agents.core.sessionNameOfSocket
import net.staude.amiscara.agents.core.sessionSocketPath
import net.staude.amiscara.agents.model.HostConfig
import net.staude.amiscara.agents.model.HostException

/**
 * Adds a host (`hostId` null) or edits one; nothing changes until "Sichern".
 * `sessionOf` and `sessionSocket` start a new host as a copy of another
 * one for a further herdr session on the same machine (#213): same address
 * and host key, but a key of its own, since a key line serves one socket.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HostEditorScreen(
    app: AmiscaraApp,
    hostId: String?,
    back: () -> Unit,
    saved: (String) -> Unit,
    sessionOf: String? = null,
    sessionSocket: String? = null,
) {
    val sessionLabel = stringResource(R.string.add_session_default)
    val initial = remember {
        hostId?.let { app.hosts.get(it) } ?: sessionOf?.let { app.hosts.get(it) }?.let { source ->
            val socket = sessionSocket ?: source.socketPath
            source.copy(
                id = "",
                name = "${source.name} (${sessionNameOfSocket(socket) ?: sessionLabel})",
                socketPath = socket,
                publicKey = null,
                allowUpload = false,
            )
        }
    }
    val adding = hostId == null
    var name by remember { mutableStateOf(initial?.name ?: "") }
    var host by remember { mutableStateOf(initial?.host ?: "") }
    var port by remember { mutableStateOf((initial?.port ?: 22).toString()) }
    var user by remember { mutableStateOf(initial?.user ?: "") }
    var macHost by remember { mutableStateOf(initial?.socketPath?.startsWith("/home/") != true) }
    var socket by remember { mutableStateOf(initial?.socketPath ?: "") }
    // A new host's socket follows user and system until typed in by hand.
    var socketTouched by remember { mutableStateOf(initial != null) }
    var allowInput by remember { mutableStateOf(initial?.allowInput ?: true) }
    var allowUpload by remember { mutableStateOf(initial?.allowUpload ?: false) }
    var groupSpaces by remember { mutableStateOf(initial?.groupSpacesByName ?: true) }
    var notify by remember { mutableStateOf(initial?.notify ?: true) }
    var session by remember { mutableStateOf(initial?.socketPath?.let(::sessionNameOfSocket) ?: "") }
    var error by remember { mutableStateOf<String?>(null) }

    fun validSession(name: String) = name.isBlank() || isValidSessionName(name.trim())
    val sessionValid = validSession(session)
    // Session `name`'s socket next to `base`; null if it cannot be built.
    fun socketFor(base: String, name: String): String? =
        if (base.isEmpty() || !validSession(name)) null else try {
            sessionSocketPath(base, name.trim())
        } catch (_: FfiException) {
            null
        }
    val defaultSocket = if (user.isBlank()) "" else HostConfig.defaultSocket(user.trim(), macHost)
    val effectiveSocket = if (socketTouched) socket else socketFor(defaultSocket, session) ?: defaultSocket

    fun save() {
        val draft = (initial ?: HostConfig(id = "", name = "", host = "", user = "", socketPath = "")).copy(
            name = name,
            host = host,
            port = port.toIntOrNull() ?: -1,
            user = user,
            socketPath = effectiveSocket,
            allowInput = allowInput,
            allowUpload = allowUpload,
            groupSpaces = groupSpaces,
            notify = notify,
        )
        try {
            saved(app.hosts.save(draft).id)
        } catch (e: HostException) {
            error = e.message
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(if (adding) R.string.host_add else R.string.host_edit)) },
                navigationIcon = {
                    IconButton(onClick = back) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
                actions = { TextButton(onClick = ::save, enabled = sessionValid) { Text(stringResource(R.string.save)) } },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text(stringResource(R.string.field_name)) },
                placeholder = { Text(stringResource(R.string.field_name_placeholder)) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = host,
                onValueChange = { host = it },
                label = { Text(stringResource(R.string.field_host)) },
                placeholder = { Text(stringResource(R.string.field_host_placeholder)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
                modifier = Modifier.fillMaxWidth(),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = user,
                    onValueChange = { user = it },
                    label = { Text(stringResource(R.string.field_user)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false),
                    modifier = Modifier.weight(2f),
                )
                OutlinedTextField(
                    value = port,
                    onValueChange = { port = it.filter(Char::isDigit).take(5) },
                    label = { Text(stringResource(R.string.field_port)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f),
                )
            }
            Text(stringResource(R.string.field_system), style = MaterialTheme.typography.labelLarge)
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                listOf(true to "macOS", false to "Linux").forEachIndexed { index, (mac, label) ->
                    SegmentedButton(
                        selected = macHost == mac,
                        onClick = {
                            macHost = mac
                            socketTouched = false
                        },
                        shape = SegmentedButtonDefaults.itemShape(index, 2),
                    ) { Text(label) }
                }
            }
            OutlinedTextField(
                value = effectiveSocket,
                onValueChange = {
                    socket = it
                    socketTouched = true
                    session = sessionNameOfSocket(it) ?: ""
                },
                label = { Text(stringResource(R.string.field_socket)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = session,
                onValueChange = {
                    session = it
                    // A socket typed by hand moves to the session next to it.
                    if (socketTouched) socketFor(socket, it)?.let { path -> socket = path }
                },
                label = { Text(stringResource(R.string.field_session)) },
                placeholder = { Text(stringResource(R.string.link_socket_default)) },
                supportingText = {
                    Text(stringResource(if (sessionValid) R.string.field_session_hint else R.string.error_session_name))
                },
                isError = !sessionValid,
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false),
                modifier = Modifier.fillMaxWidth(),
            )
            SwitchRow(stringResource(R.string.allow_input), allowInput) { allowInput = it }
            SwitchRow(stringResource(R.string.allow_upload), allowUpload) { allowUpload = it }
            SwitchRow(stringResource(R.string.group_spaces), groupSpaces) { groupSpaces = it }
            SwitchRow(stringResource(R.string.host_notify), notify) { notify = it }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(label, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange)
    }
}
