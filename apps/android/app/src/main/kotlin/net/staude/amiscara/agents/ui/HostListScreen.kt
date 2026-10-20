package net.staude.amiscara.agents.ui

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.AgentState

/** Start screen: all hosts with their connection state. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HostListScreen(
    app: AmiscaraApp,
    openHost: (String) -> Unit,
    addHost: () -> Unit,
    scan: () -> Unit,
    addLink: (String) -> Unit,
    askLocalNetwork: () -> Unit,
) {
    val hosts by app.hosts.hosts.collectAsStateWithLifecycle()
    val updates by app.connections.updates.collectAsStateWithLifecycle()
    val startErrors by app.connections.startErrors.collectAsStateWithLifecycle()
    val localNetwork by app.localNetworkAllowed.collectAsStateWithLifecycle()
    var menu by remember { mutableStateOf(false) }
    var pasting by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.app_name)) },
                actions = {
                    Box {
                        IconButton(onClick = { menu = true }) {
                            Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.more))
                        }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(text = { Text(stringResource(R.string.scan_qr)) }, onClick = {
                                menu = false
                                scan()
                            })
                            DropdownMenuItem(text = { Text(stringResource(R.string.paste_link)) }, onClick = {
                                menu = false
                                pasting = true
                            })
                        }
                    }
                },
            )
        },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = addHost,
                icon = { Icon(Icons.Default.Add, contentDescription = null) },
                text = { Text(stringResource(R.string.host_add)) },
            )
        },
    ) { padding ->
        if (hosts.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding).padding(24.dp), contentAlignment = Alignment.Center) {
                Text(stringResource(R.string.hosts_empty), style = MaterialTheme.typography.bodyLarge)
            }
        } else {
            LazyColumn(Modifier.fillMaxSize().padding(padding)) {
                if (!localNetwork) {
                    item { LocalNetworkCard(askLocalNetwork) }
                }
                items(hosts, key = { it.id }) { host ->
                    val update = updates[host.id]
                    val startError = startErrors[host.id]
                    val waiting = update?.board?.count { it.agentState == AgentState.BLOCKED } ?: 0
                    ListItem(
                        modifier = Modifier.clickable { openHost(host.id) },
                        leadingContent = { StatusDot(update, startError) },
                        headlineContent = { Text(host.name) },
                        supportingContent = {
                            Column {
                                Text("${host.user}@${host.host}")
                                Text(
                                    if (waiting > 0) {
                                        pluralStringResource(R.plurals.agents_waiting, waiting, waiting)
                                    } else {
                                        statusSummary(update, startError)
                                    },
                                )
                            }
                        },
                    )
                }
            }
        }
    }

    if (pasting) {
        PasteLinkDialog(
            dismiss = { pasting = false },
            confirm = {
                pasting = false
                addLink(it)
            },
        )
    }
}

@Composable
private fun PasteLinkDialog(dismiss: () -> Unit, confirm: (String) -> Unit) {
    var text by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text(stringResource(R.string.paste_link)) },
        text = {
            Column {
                Text(stringResource(R.string.paste_link_hint), style = MaterialTheme.typography.bodyMedium)
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
                    placeholder = { Text("amiscara-agents://add-host?v=1&…") },
                    minLines = 3,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { confirm(text.trim()) }, enabled = text.isNotBlank()) {
                Text(stringResource(R.string.next))
            }
        },
        dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/**
 * Shown while Android 17 blocks private addresses. After "Nicht erlauben"
 * the system no longer asks, so the settings are offered as well.
 */
@Composable
private fun LocalNetworkCard(ask: () -> Unit) {
    val context = LocalContext.current
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
        modifier = Modifier.fillMaxWidth().padding(16.dp),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.local_network_missing))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = ask) { Text(stringResource(R.string.local_network_allow)) }
                OutlinedButton(onClick = {
                    context.startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)),
                    )
                }) { Text(stringResource(R.string.open_settings)) }
            }
        }
    }
}
