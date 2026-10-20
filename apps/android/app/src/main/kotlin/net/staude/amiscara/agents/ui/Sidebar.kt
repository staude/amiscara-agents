package net.staude.amiscara.agents.ui

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.HostStatus
import net.staude.amiscara.agents.core.WorkspaceItem
import net.staude.amiscara.agents.model.SpaceBlock
import net.staude.amiscara.agents.model.SpaceEntry
import net.staude.amiscara.agents.model.SpaceSelection
import net.staude.amiscara.agents.model.arrange
import net.staude.amiscara.agents.model.blocks
import net.staude.amiscara.agents.model.closingState
import net.staude.amiscara.agents.model.linkedWorktrees
import net.staude.amiscara.agents.model.place
import net.staude.amiscara.agents.model.repositoryOf
import net.staude.amiscara.agents.model.title

/**
 * The start screen and, on a wide screen, the left column: per host its
 * state, its spaces (name groups, worktrees indented) and its agents,
 * waiting ones first. Like `HostSidebar.swift` and `Sidebar.svelte`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Sidebar(
    app: AmiscaraApp,
    selected: SpaceSelection?,
    openHost: (String) -> Unit,
    openSpace: (SpaceSelection) -> Unit,
    addHost: () -> Unit,
    scan: () -> Unit,
    addLink: (String) -> Unit,
    askLocalNetwork: () -> Unit,
    openSwitcher: () -> Unit,
    openSettings: () -> Unit,
    manage: (ManageDialog) -> Unit,
    modifier: Modifier = Modifier,
) {
    val hosts by app.hosts.hosts.collectAsStateWithLifecycle()
    val updates by app.connections.updates.collectAsStateWithLifecycle()
    val startErrors by app.connections.startErrors.collectAsStateWithLifecycle()
    val localNetwork by app.localNetworkAllowed.collectAsStateWithLifecycle()
    var menu by remember { mutableStateOf(false) }
    var pasting by remember { mutableStateOf(false) }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.app_name)) },
                actions = {
                    IconButton(onClick = openSwitcher, enabled = hosts.isNotEmpty()) {
                        Icon(Icons.Default.Search, contentDescription = stringResource(R.string.switcher))
                    }
                    Box {
                        IconButton(onClick = { menu = true }) {
                            Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.more))
                        }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(text = { Text(stringResource(R.string.host_add)) }, onClick = {
                                menu = false
                                addHost()
                            })
                            DropdownMenuItem(text = { Text(stringResource(R.string.scan_qr)) }, onClick = {
                                menu = false
                                scan()
                            })
                            DropdownMenuItem(text = { Text(stringResource(R.string.paste_link)) }, onClick = {
                                menu = false
                                pasting = true
                            })
                            DropdownMenuItem(text = { Text(stringResource(R.string.settings)) }, onClick = {
                                menu = false
                                openSettings()
                            })
                        }
                    }
                },
            )
        },
    ) { padding ->
        if (hosts.isEmpty()) {
            Column(
                Modifier.fillMaxSize().padding(padding).padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(stringResource(R.string.hosts_empty), style = MaterialTheme.typography.bodyLarge)
                Button(onClick = addHost) { Text(stringResource(R.string.host_add)) }
                OutlinedButton(onClick = scan) { Text(stringResource(R.string.scan_qr)) }
            }
        } else {
            LazyColumn(Modifier.fillMaxSize().padding(padding)) {
                if (!localNetwork) {
                    item { LocalNetworkCard(askLocalNetwork) }
                }
                for (host in hosts) {
                    val update = updates[host.id]
                    val startError = startErrors[host.id]
                    val live = update?.status == HostStatus.Live
                    val writable = live && host.allowInput != false
                    item(key = "host-${host.id}") {
                        var hostMenu by remember { mutableStateOf(false) }
                        ListItem(
                            modifier = Modifier.clickable { openHost(host.id) },
                            leadingContent = { StatusDot(update, startError) },
                            headlineContent = { Text(host.name, style = MaterialTheme.typography.titleMedium) },
                            supportingContent = if (live) null else ({ Text(statusSummary(update, startError)) }),
                            trailingContent = {
                                Box {
                                    IconButton(onClick = { hostMenu = true }) {
                                        Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.more))
                                    }
                                    DropdownMenu(expanded = hostMenu, onDismissRequest = { hostMenu = false }) {
                                        DropdownMenuItem(text = { Text(stringResource(R.string.host_details)) }, onClick = {
                                            hostMenu = false
                                            openHost(host.id)
                                        })
                                        DropdownMenuItem(text = { Text(stringResource(R.string.menu_reconnect)) }, onClick = {
                                            hostMenu = false
                                            app.connections.reconnect(host.id)
                                        })
                                        DropdownMenuItem(
                                            text = { Text(stringResource(R.string.menu_new_space)) },
                                            enabled = writable,
                                            onClick = {
                                                hostMenu = false
                                                manage(ManageDialog.NewSpace(host.id))
                                            },
                                        )
                                    }
                                }
                            },
                        )
                    }
                    if (update == null || !live) continue
                    val entries = arrange(update)
                    if (entries.isNotEmpty()) {
                        item(key = "spaces-${host.id}") { SectionLabel(stringResource(R.string.spaces)) }
                    }
                    for (block in blocks(entries)) {
                        when (block) {
                            is SpaceBlock.Space -> item(key = "space-${host.id}-${block.entry.workspace.workspaceId}") {
                                SpaceRow(block.entry, update.workspaces, host.id, writable, selected, grouped = false, openSpace, manage)
                            }
                            is SpaceBlock.Group -> {
                                item(key = "group-${host.id}-${block.name}") { GroupLabel(block.name) }
                                for (entry in block.entries) {
                                    item(key = "space-${host.id}-${entry.workspace.workspaceId}") {
                                        SpaceRow(entry, update.workspaces, host.id, writable, selected, grouped = true, openSpace, manage)
                                    }
                                }
                            }
                        }
                    }
                    if (update.board.isNotEmpty()) {
                        item(key = "agents-${host.id}") { SectionLabel(stringResource(R.string.agents)) }
                    }
                    for (agent in update.board) {
                        item(key = "agent-${host.id}-${agent.paneId}") {
                            val selection = SpaceSelection(host.id, agent.workspaceId, agent.paneId)
                            CompactRow(
                                selected = selected == selection,
                                onClick = { openSpace(selection) },
                                onLongClick = if (writable) ({ manage(ManageDialog.Rename(host.id, ManageDialog.Target.AGENT, agent.paneId, agent.name.orEmpty())) }) else null,
                                indent = 0,
                                leading = { AgentDot(agent.agentState) },
                                title = agent.title,
                                subtitle = "${agent.place(update)} · ${agent.agentState.label()}",
                            )
                        }
                    }
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

/** A sidebar row, flatter than a Material list item. */
@Composable
private fun CompactRow(
    selected: Boolean,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
    indent: Int,
    leading: @Composable () -> Unit,
    title: String,
    subtitle: String?,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp)
            .clip(MaterialTheme.shapes.small)
            .background(if (selected) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent)
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(start = (8 + indent).dp, end = 8.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        leading()
        Column(Modifier.weight(1f)) {
            Text(title, maxLines = 1, style = MaterialTheme.typography.bodyLarge)
            subtitle?.let {
                Text(it, maxLines = 1, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        Modifier.padding(start = 16.dp, top = 12.dp, bottom = 4.dp),
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
    )
}

@Composable
private fun GroupLabel(name: String) {
    Text(
        name,
        Modifier.padding(start = 24.dp, top = 8.dp, bottom = 2.dp),
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/** A space; a long press opens rename, new worktree and close. */
@Composable
private fun SpaceRow(
    entry: SpaceEntry,
    all: List<WorkspaceItem>,
    hostId: String,
    writable: Boolean,
    selected: SpaceSelection?,
    grouped: Boolean,
    open: (SpaceSelection) -> Unit,
    manage: (ManageDialog) -> Unit,
) {
    val workspace = entry.workspace
    val indent = (if (grouped) 16 else 0) + (if (entry.nested) 16 else 0)
    val isSelected = selected?.hostId == hostId && selected.workspaceId == workspace.workspaceId
    val hasAgents = workspace.tabs.any { tab -> tab.panes.any { it.agent != null } }
    val details = listOfNotNull(workspace.branch) + workspace.tokens.map { it.value }
    var menu by remember { mutableStateOf(false) }
    Box {
        CompactRow(
            selected = isSelected,
            onClick = { open(SpaceSelection(hostId, workspace.workspaceId)) },
            onLongClick = if (writable) ({ menu = true }) else null,
            indent = indent,
            leading = { AgentDot(workspace.agentState.takeIf { hasAgents }) },
            title = workspace.worktreeName ?: workspace.name,
            subtitle = details.joinToString(" · ").ifEmpty { null },
        )
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            SpaceMenuItems(hostId, workspace, all) {
                menu = false
                manage(it)
            }
        }
    }
}

/** Rename, new worktree and close of a space; also in the space's own menu. */
@Composable
fun SpaceMenuItems(hostId: String, workspace: WorkspaceItem, all: List<WorkspaceItem>, manage: (ManageDialog) -> Unit) {
    DropdownMenuItem(text = { Text(stringResource(R.string.menu_rename_space)) }, onClick = {
        manage(ManageDialog.Rename(hostId, ManageDialog.Target.SPACE, workspace.workspaceId, workspace.label))
    })
    repositoryOf(workspace, all)?.let { repo ->
        DropdownMenuItem(text = { Text(stringResource(R.string.menu_new_worktree)) }, onClick = {
            manage(ManageDialog.NewWorktree(hostId, repo.workspaceId, repo.label))
        })
    }
    DropdownMenuItem(
        text = { Text(stringResource(R.string.menu_close_space), color = MaterialTheme.colorScheme.error) },
        onClick = {
            val worktrees = linkedWorktrees(workspace, all)
            manage(
                ManageDialog.Close(
                    hostId,
                    ManageDialog.Target.SPACE,
                    workspace.workspaceId,
                    workspace.worktreeName ?: workspace.name,
                    closingState(listOf(workspace) + worktrees),
                    worktrees.size,
                ),
            )
        },
    )
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
