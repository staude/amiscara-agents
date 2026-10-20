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
import net.staude.amiscara.agents.model.HostConfig
import net.staude.amiscara.agents.model.HostException

/** Adds a host (`hostId` null) or edits one; nothing changes until "Sichern". */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HostEditorScreen(app: AmiscaraApp, hostId: String?, back: () -> Unit, saved: (String) -> Unit) {
    val initial = remember { hostId?.let { app.hosts.get(it) } }
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
    var error by remember { mutableStateOf<String?>(null) }

    val effectiveSocket = if (socketTouched) socket else if (user.isBlank()) "" else HostConfig.defaultSocket(user.trim(), macHost)

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
                title = { Text(stringResource(if (initial == null) R.string.host_add else R.string.host_edit)) },
                navigationIcon = {
                    IconButton(onClick = back) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
                actions = { TextButton(onClick = ::save) { Text(stringResource(R.string.save)) } },
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
                },
                label = { Text(stringResource(R.string.field_socket)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
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
