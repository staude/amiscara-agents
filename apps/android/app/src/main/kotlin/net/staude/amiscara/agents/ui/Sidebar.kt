package net.staude.amiscara.agents.ui

import android.content.ClipData
import android.content.ClipDescription
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.draganddrop.dragAndDropSource
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Menu
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
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.DragAndDropTransferData
import androidx.compose.ui.draganddrop.mimeTypes
import androidx.compose.ui.draganddrop.toAndroidDragEvent
import androidx.compose.ui.draw.alpha
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
import net.staude.amiscara.agents.model.GROUP_KEY_PREFIX
import net.staude.amiscara.agents.model.SpaceBlock
import net.staude.amiscara.agents.model.SpaceEntry
import net.staude.amiscara.agents.model.SpaceSelection
import net.staude.amiscara.agents.model.SpaceSortMode
import net.staude.amiscara.agents.model.arrange
import net.staude.amiscara.agents.model.blocks
import net.staude.amiscara.agents.core.sessionNameOfSocket
import net.staude.amiscara.agents.model.HostConfig
import net.staude.amiscara.agents.model.closingState
import net.staude.amiscara.agents.model.linkedWorktrees
import net.staude.amiscara.agents.model.moveSpace
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
    /** Opens the editor for a new host on `hostId`'s machine with that socket. */
    addSession: (hostId: String, socketPath: String) -> Unit,
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
    var sessionsOf by remember { mutableStateOf<HostConfig?>(null) }

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
                            supportingContent = hostSubtitle(host, if (live) null else statusSummary(update, startError)),
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
                                        DropdownMenuItem(text = { Text(stringResource(R.string.menu_add_session)) }, onClick = {
                                            hostMenu = false
                                            sessionsOf = host
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
                    val sort = host.spaceSort ?: SpaceSortMode.HERDR
                    if (entries.isNotEmpty()) {
                        item(key = "spaces-${host.id}") {
                            SpacesLabel(sort) { mode ->
                                val order = if (mode == SpaceSortMode.MANUAL) entries.map { it.workspace.workspaceId } else null
                                app.hosts.setSpaceSort(host.id, mode, order)
                            }
                        }
                    }
                    val drag = if (sort == SpaceSortMode.MANUAL) {
                        SpaceDrag(host.id, entries) { app.hosts.setSpaceSort(host.id, SpaceSortMode.MANUAL, it) }
                    } else {
                        null
                    }
                    for (block in blocks(entries)) {
                        when (block) {
                            is SpaceBlock.Space -> item(key = "space-${host.id}-${block.entry.workspace.workspaceId}") {
                                SpaceRow(block.entry, update.workspaces, host.id, writable, selected, grouped = false, drag, openSpace, manage)
                            }
                            is SpaceBlock.Group -> {
                                item(key = "group-${host.id}-${block.name}") { GroupLabel(block.name, drag) }
                                for (entry in block.entries) {
                                    item(key = "space-${host.id}-${entry.workspace.workspaceId}") {
                                        SpaceRow(entry, update.workspaces, host.id, writable, selected, grouped = true, drag, openSpace, manage)
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
    sessionsOf?.let { host ->
        SessionPicker(app, host, dismiss = { sessionsOf = null }) {
            sessionsOf = null
            addSession(host.id, it)
        }
    }
}

/**
 * The line under a host's name: its herdr session unless it is the
 * default one (#213), and `status` while not connected.
 */
private fun hostSubtitle(host: HostConfig, status: String?): (@Composable () -> Unit)? {
    val session = sessionNameOfSocket(host.socketPath)
    if (session == null && status == null) return null
    return {
        Column {
            session?.let { Text(stringResource(R.string.host_session, it)) }
            status?.let { Text(it) }
        }
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

/** "Spaces" with the menu of sort modes (#245); on this device, also without input. */
@Composable
private fun SpacesLabel(current: SpaceSortMode, choose: (SpaceSortMode) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        SectionLabel(stringResource(R.string.spaces))
        Box {
            TextButton(onClick = { menu = true }) {
                Text(stringResource(SORT_LABELS.first { it.first == current }.second), style = MaterialTheme.typography.labelMedium)
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                for ((mode, label) in SORT_LABELS) {
                    DropdownMenuItem(
                        text = { Text(stringResource(label)) },
                        leadingIcon = {
                            Icon(Icons.Default.Check, contentDescription = null, Modifier.alpha(if (mode == current) 1f else 0f))
                        },
                        onClick = {
                            menu = false
                            choose(mode)
                        },
                    )
                }
            }
        }
    }
}

private val SORT_LABELS = listOf(
    SpaceSortMode.HERDR to R.string.sort_herdr,
    SpaceSortMode.NAME_ASCENDING to R.string.sort_name_ascending,
    SpaceSortMode.NAME_DESCENDING to R.string.sort_name_descending,
    SpaceSortMode.MANUAL to R.string.sort_manual,
)

/** Moving a host's spaces by their handle in the manual order (#245). */
private class SpaceDrag(val hostId: String, val entries: List<SpaceEntry>, val save: (List<String>) -> Unit)

/**
 * The handle that drags the row of `key` (a workspace ID or a group's
 * key) after a long press. Outside the row's own long press, which keeps
 * opening its menu.
 */
@Composable
private fun DragHandle(drag: SpaceDrag, key: String) {
    Box(
        Modifier
            .size(40.dp)
            .dragAndDropSource { _ -> DragAndDropTransferData(ClipData.newPlainText("space", "${drag.hostId}\n$key")) },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.Default.Menu,
            contentDescription = stringResource(R.string.move_space),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * A row that takes spaces of its own host dropped on it; `content` gets
 * whether one hovers. Without `drag` (not the manual order) just the row.
 */
@Composable
private fun SpaceDropZone(drag: SpaceDrag?, key: String, content: @Composable (over: Boolean) -> Unit) {
    if (drag == null) {
        content(false)
        return
    }
    var over by remember { mutableStateOf(false) }
    val current by rememberUpdatedState(drag)
    val target = remember(key) {
        object : DragAndDropTarget {
            override fun onDrop(event: DragAndDropEvent): Boolean {
                over = false
                val clip = event.toAndroidDragEvent().clipData ?: return false
                val text = clip.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString() ?: return false
                val prefix = "${current.hostId}\n"
                if (!text.startsWith(prefix)) return false
                val order = moveSpace(current.entries, text.removePrefix(prefix), key) ?: return false
                current.save(order)
                return true
            }

            override fun onEntered(event: DragAndDropEvent) {
                over = true
            }

            override fun onExited(event: DragAndDropEvent) {
                over = false
            }

            override fun onEnded(event: DragAndDropEvent) {
                over = false
            }
        }
    }
    Box(
        Modifier.dragAndDropTarget(
            shouldStartDragAndDrop = { ClipDescription.MIMETYPE_TEXT_PLAIN in it.mimeTypes() },
            target = target,
        ),
    ) {
        content(over)
    }
}

@Composable
private fun GroupLabel(name: String, drag: SpaceDrag?) {
    val key = GROUP_KEY_PREFIX + name
    SpaceDropZone(drag, key) { over ->
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp)
                .clip(MaterialTheme.shapes.small)
                .background(if (over) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                name,
                Modifier.weight(1f).padding(start = 16.dp, top = 8.dp, bottom = 2.dp),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            drag?.let { DragHandle(it, key) }
        }
    }
}

/**
 * A space; a long press opens rename, new worktree and close. In the
 * manual order a handle at the end moves it.
 */
@Composable
private fun SpaceRow(
    entry: SpaceEntry,
    all: List<WorkspaceItem>,
    hostId: String,
    writable: Boolean,
    selected: SpaceSelection?,
    grouped: Boolean,
    drag: SpaceDrag?,
    open: (SpaceSelection) -> Unit,
    manage: (ManageDialog) -> Unit,
) {
    val workspace = entry.workspace
    val indent = (if (grouped) 16 else 0) + (if (entry.nested) 16 else 0)
    val isSelected = selected?.hostId == hostId && selected.workspaceId == workspace.workspaceId
    val hasAgents = workspace.tabs.any { tab -> tab.panes.any { it.agent != null } }
    val details = listOfNotNull(workspace.branch) + workspace.tokens.map { it.value }
    var menu by remember { mutableStateOf(false) }
    SpaceDropZone(drag, workspace.workspaceId) { over ->
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) {
                CompactRow(
                    selected = isSelected || over,
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
            drag?.let {
                Box(Modifier.padding(end = 8.dp)) { DragHandle(it, workspace.workspaceId) }
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
