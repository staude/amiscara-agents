package net.staude.amiscara.agents.ui

import android.content.ClipData
import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.HostStatus
import net.staude.amiscara.agents.core.authorizedKeysLine
import net.staude.amiscara.agents.model.HostConfig

/** One host: state, host key confirmation and the line for `authorized_keys`. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HostDetailScreen(app: AmiscaraApp, hostId: String, back: () -> Unit, edit: () -> Unit) {
    val hosts by app.hosts.hosts.collectAsStateWithLifecycle()
    val updates by app.connections.updates.collectAsStateWithLifecycle()
    val startErrors by app.connections.startErrors.collectAsStateWithLifecycle()
    val host = hosts.firstOrNull { it.id == hostId }
    var removing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(host == null) { if (host == null) back() }
    if (host == null) return
    val update = updates[host.id]
    val startError = startErrors[host.id]

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(host.name) },
                navigationIcon = {
                    IconButton(onClick = back) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
                actions = {
                    IconButton(onClick = edit) {
                        Icon(Icons.Default.Edit, contentDescription = stringResource(R.string.edit))
                    }
                    IconButton(onClick = { removing = true }) {
                        Icon(Icons.Default.Delete, contentDescription = stringResource(R.string.remove))
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(statusSummary(update, startError), style = MaterialTheme.typography.titleMedium)
            statusDetail(update, startError)?.let {
                SelectionContainer { Text(it, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
            }
            statusHint(update)?.let { Text(it) }
            if (update != null && update.serverVersion != null && !update.protocolSupported) {
                Text(stringResource(R.string.protocol_unsupported), color = MaterialTheme.colorScheme.error)
            }
            OutlinedButton(onClick = { app.connections.reconnect(host.id) }) {
                Text(stringResource(R.string.connect_now))
            }

            when (val status = update?.status) {
                is HostStatus.HostKeyUnknown -> HostKeyCard(host, status.key, status.fingerprint, changed = false, app)
                is HostStatus.HostKeyChanged -> HostKeyCard(host, status.key, status.fingerprint, changed = true, app)
                else -> {}
            }

            DeviceKeyCard(host, app) { error = it }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }

    if (removing) {
        AlertDialog(
            onDismissRequest = { removing = false },
            title = { Text(stringResource(R.string.remove_title, host.name)) },
            text = { Text(stringResource(R.string.remove_text)) },
            confirmButton = {
                TextButton(onClick = {
                    removing = false
                    app.hosts.remove(host.id)
                }) { Text(stringResource(R.string.remove)) }
            },
            dismissButton = { TextButton(onClick = { removing = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

@Composable
private fun HostKeyCard(host: HostConfig, key: String, fingerprint: String, changed: Boolean, app: AmiscaraApp) {
    val colors = if (changed) {
        CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)
    } else {
        CardDefaults.cardColors()
    }
    Card(colors = colors, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                stringResource(if (changed) R.string.key_changed_text else R.string.key_unknown_text, host.host),
            )
            SelectionContainer { Text(fingerprint, fontFamily = FontFamily.Monospace) }
            Text(stringResource(R.string.key_check_command), style = MaterialTheme.typography.bodySmall)
            Button(onClick = { app.hosts.trustHostKey(host.id, key) }) {
                Text(stringResource(R.string.trust_host_key))
            }
        }
    }
}

@Composable
private fun DeviceKeyCard(host: HostConfig, app: AmiscaraApp, showError: (String) -> Unit) {
    val publicKey = host.publicKey ?: return
    val allowSftp = host.allowUpload ?: false
    val line = remember(publicKey, allowSftp, host.customSocket) {
        runCatching { authorizedKeysLine(publicKey, allowSftp, host.customSocket) }
    }
    val clipboard = LocalClipboard.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var copied by remember { mutableStateOf(false) }
    var regenerating by remember { mutableStateOf(false) }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.device_key), style = MaterialTheme.typography.titleSmall)
            Text(
                stringResource(if (allowSftp) R.string.device_key_text_sftp else R.string.device_key_text, host.host),
                style = MaterialTheme.typography.bodySmall,
            )
            line.fold(
                onSuccess = { text ->
                    SelectionContainer { Text(text, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = {
                            scope.launch {
                                clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("authorized_keys", text)))
                                copied = true
                                delay(1500)
                                copied = false
                            }
                        }) { Text(stringResource(if (copied) R.string.copied else R.string.copy_line)) }
                        OutlinedButton(onClick = {
                            val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
                            context.startActivity(Intent.createChooser(send, null))
                        }) { Text(stringResource(R.string.share_line)) }
                        OutlinedButton(onClick = { regenerating = true }) { Text(stringResource(R.string.new_key)) }
                    }
                },
                onFailure = { Text(it.message ?: it.toString(), color = MaterialTheme.colorScheme.error) },
            )
        }
    }

    if (regenerating) {
        AlertDialog(
            onDismissRequest = { regenerating = false },
            title = { Text(stringResource(R.string.new_key_title)) },
            text = { Text(stringResource(R.string.new_key_text)) },
            confirmButton = {
                TextButton(onClick = {
                    regenerating = false
                    runCatching { app.hosts.regenerateKey(host.id) }.onFailure { showError(it.message ?: it.toString()) }
                }) { Text(stringResource(R.string.create)) }
            },
            dismissButton = { TextButton(onClick = { regenerating = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}
