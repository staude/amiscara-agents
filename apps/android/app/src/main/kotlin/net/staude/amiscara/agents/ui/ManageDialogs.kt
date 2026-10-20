package net.staude.amiscara.agents.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.AgentState
import net.staude.amiscara.agents.core.Created
import net.staude.amiscara.agents.core.HostSession
import net.staude.amiscara.agents.core.NewWorktree
import net.staude.amiscara.agents.model.SpaceSelection
import net.staude.amiscara.agents.model.renameMessage

/** Which dialog for creating, renaming or closing is open. */
sealed interface ManageDialog {
    val hostId: String

    data class NewSpace(override val hostId: String) : ManageDialog

    data class NewTab(override val hostId: String, val workspaceId: String) : ManageDialog

    /** An agent in a pane that runs a plain shell. */
    data class StartAgent(override val hostId: String, val paneId: String) : ManageDialog

    data class NewWorktree(override val hostId: String, val repositoryId: String, val repositoryLabel: String) : ManageDialog

    enum class Target { SPACE, TAB, AGENT }

    data class Rename(override val hostId: String, val target: Target, val id: String, val current: String) : ManageDialog

    /** `worktrees`: linked worktree spaces that close with a repository's space. */
    data class Close(
        override val hostId: String,
        val target: Target,
        val id: String,
        val name: String,
        val state: AgentState,
        val worktrees: Int,
    ) : ManageDialog
}

/**
 * The open dialog (`NewSpaceView`, `RenameView`, `CloseView` of the Mac
 * app, `ManageDialogs.svelte`). `created` shows a new space or tab.
 */
@Composable
fun ManageDialogView(app: AmiscaraApp, dialog: ManageDialog, dismiss: () -> Unit, created: (SpaceSelection) -> Unit) {
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // The space exists but its agent did not start: "Anlegen" again would make a second one.
    var createdWithoutAgent by remember { mutableStateOf(false) }
    val host = app.hosts.get(dialog.hostId)
    val groupHint = if (host?.groupSpacesByName != false) stringResource(R.string.group_hint) else null
    val agentFailed = stringResource(R.string.created_without_agent)

    fun run(action: suspend () -> Unit) {
        scope.launch {
            busy = true
            error = null
            try {
                action()
            } catch (e: Exception) {
                error = renameMessage(e.message ?: e.toString())
            } finally {
                busy = false
            }
        }
    }

    /** Creates, shows the new pane, then starts the agent if one was picked. */
    fun create(agent: String?, make: (HostSession) -> Created) = run {
        val made = app.connections.input(dialog.hostId, make).getOrThrow()
        created(SpaceSelection(dialog.hostId, made.workspaceId, made.paneId))
        if (agent != null) {
            app.connections.input(dialog.hostId) { it.startAgent(made.paneId, agent, null) }.onFailure {
                createdWithoutAgent = true
                throw IllegalStateException(agentFailed.format(it.message))
            }
        }
        dismiss()
    }

    when (dialog) {
        is ManageDialog.NewSpace -> {
            var name by remember { mutableStateOf("") }
            var directory by remember { mutableStateOf("~") }
            var agent by remember { mutableStateOf(app.settings.agentKind("newSpace")) }
            FormDialog(
                title = stringResource(R.string.new_space_title, host?.name.orEmpty()),
                confirm = stringResource(R.string.create_button),
                canConfirm = !busy && !createdWithoutAgent,
                cancelLabel = stringResource(if (createdWithoutAgent) R.string.close_button else R.string.cancel),
                error = error,
                dismiss = dismiss,
                onConfirm = { create(agent) { it.createWorkspace(name.trim().ifEmpty { null }, directory.trim().ifEmpty { "~" }) } },
            ) {
                Field(name, { name = it }, stringResource(R.string.field_name), stringResource(if (groupHint != null) R.string.placeholder_space_group else R.string.placeholder_space))
                Field(directory, { directory = it }, stringResource(R.string.field_directory), "~/dev/projekt")
                groupHint?.let { Hint(it) }
                AgentPicker(app, dialog.hostId, agent) {
                    agent = it
                    app.settings.setAgentKind("newSpace", it)
                }
            }
        }
        is ManageDialog.NewTab -> {
            var agent by remember { mutableStateOf(app.settings.agentKind("newTab")) }
            FormDialog(
                title = stringResource(R.string.new_tab_title),
                confirm = stringResource(R.string.create_button),
                canConfirm = !busy && !createdWithoutAgent,
                cancelLabel = stringResource(if (createdWithoutAgent) R.string.close_button else R.string.cancel),
                error = error,
                dismiss = dismiss,
                onConfirm = { create(agent) { it.createTab(dialog.workspaceId, null) } },
            ) {
                AgentPicker(app, dialog.hostId, agent) {
                    agent = it
                    app.settings.setAgentKind("newTab", it)
                }
            }
        }
        is ManageDialog.StartAgent -> {
            var agent by remember { mutableStateOf(app.settings.agentKind("startAgent") ?: "claude") }
            var name by remember { mutableStateOf("") }
            FormDialog(
                title = stringResource(R.string.agent_start),
                confirm = stringResource(R.string.start_button),
                canConfirm = !busy,
                cancelLabel = stringResource(R.string.cancel),
                error = error,
                dismiss = dismiss,
                onConfirm = {
                    run {
                        app.connections.input(dialog.hostId) { it.startAgent(dialog.paneId, agent, name.trim().ifEmpty { null }) }.getOrThrow()
                        dismiss()
                    }
                },
            ) {
                AgentPicker(app, dialog.hostId, agent, allowNone = false) {
                    agent = it ?: agent
                    app.settings.setAgentKind("startAgent", it)
                }
                Field(name, { name = it }, stringResource(R.string.field_name), stringResource(R.string.name_agent_placeholder))
            }
        }
        is ManageDialog.NewWorktree -> {
            var branch by remember { mutableStateOf("") }
            var base by remember { mutableStateOf("") }
            var name by remember { mutableStateOf("") }
            var agent by remember { mutableStateOf(app.settings.agentKind("newWorktree")) }
            FormDialog(
                title = stringResource(R.string.new_worktree_title, dialog.repositoryLabel),
                confirm = stringResource(R.string.create_button),
                canConfirm = !busy && !createdWithoutAgent,
                cancelLabel = stringResource(if (createdWithoutAgent) R.string.close_button else R.string.cancel),
                error = error,
                dismiss = dismiss,
                onConfirm = {
                    create(agent) {
                        it.createWorktree(
                            dialog.repositoryId,
                            NewWorktree(branch.trim().ifEmpty { null }, base.trim().ifEmpty { null }, name.trim().ifEmpty { null }, null),
                        )
                    }
                },
            ) {
                Field(branch, { branch = it }, stringResource(R.string.field_branch), stringResource(R.string.placeholder_branch))
                Field(base, { base = it }, stringResource(R.string.field_base), "HEAD")
                Field(name, { name = it }, stringResource(R.string.field_name), branch.ifEmpty { stringResource(R.string.placeholder_worktree_name) })
                Hint(stringResource(R.string.worktree_hint))
                AgentPicker(app, dialog.hostId, agent) {
                    agent = it
                    app.settings.setAgentKind("newWorktree", it)
                }
                if (busy) Hint(stringResource(R.string.worktree_running))
            }
        }
        is ManageDialog.Rename -> {
            // The current name selected, so typing replaces it.
            var field by remember { mutableStateOf(TextFieldValue(dialog.current, TextRange(0, dialog.current.length))) }
            val name = field.text
            val focus = remember { FocusRequester() }
            LaunchedEffect(Unit) { focus.requestFocus() }
            val isAgent = dialog.target == ManageDialog.Target.AGENT
            FormDialog(
                title = stringResource(
                    when (dialog.target) {
                        ManageDialog.Target.SPACE -> R.string.rename_space_title
                        ManageDialog.Target.TAB -> R.string.rename_tab_title
                        ManageDialog.Target.AGENT -> R.string.name_agent_title
                    },
                ),
                confirm = stringResource(R.string.save),
                canConfirm = !busy && (isAgent || name.isNotBlank()),
                cancelLabel = stringResource(R.string.cancel),
                error = error,
                dismiss = dismiss,
                onConfirm = {
                    run {
                        val value = name.trim()
                        app.connections.input(dialog.hostId) {
                            when (dialog.target) {
                                ManageDialog.Target.SPACE -> it.renameWorkspace(dialog.id, value)
                                ManageDialog.Target.TAB -> it.renameTab(dialog.id, value)
                                ManageDialog.Target.AGENT -> it.renameAgent(dialog.id, value.ifEmpty { null })
                            }
                        }.getOrThrow()
                        dismiss()
                    }
                },
            ) {
                OutlinedTextField(
                    value = field,
                    onValueChange = { field = it },
                    label = { Text(stringResource(R.string.field_name)) },
                    placeholder = { if (isAgent) Text(stringResource(R.string.name_agent_placeholder)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().focusRequester(focus),
                )
                when {
                    isAgent -> Hint(stringResource(R.string.name_agent_hint))
                    dialog.target == ManageDialog.Target.SPACE && groupHint != null -> Hint(groupHint)
                }
            }
        }
        is ManageDialog.Close -> {
            val isSpace = dialog.target == ManageDialog.Target.SPACE
            val state = stringResource(
                when (dialog.state) {
                    AgentState.WORKING -> R.string.close_working
                    AgentState.BLOCKED -> R.string.close_blocked
                    else -> R.string.close_plain
                },
            )
            val worktrees = when {
                dialog.worktrees == 1 -> stringResource(R.string.close_worktree_one) + " "
                dialog.worktrees > 1 -> pluralStringResource(R.plurals.close_worktree_many, dialog.worktrees, dialog.worktrees) + " "
                else -> ""
            }
            AlertDialog(
                onDismissRequest = dismiss,
                title = { Text(stringResource(if (isSpace) R.string.close_space_title else R.string.close_tab_title, dialog.name)) },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(worktrees + state)
                        error?.let { Text(stringResource(R.string.close_failed, it), color = MaterialTheme.colorScheme.error) }
                    }
                },
                confirmButton = {
                    TextButton(enabled = !busy, onClick = {
                        run {
                            app.connections.input(dialog.hostId) {
                                if (isSpace) it.closeWorkspace(dialog.id, dialog.worktrees > 0) else it.closeTab(dialog.id)
                            }.getOrThrow()
                            dismiss()
                        }
                    }) {
                        Text(
                            stringResource(if (isSpace) R.string.menu_close_space else R.string.menu_close_tab).removeSuffix(" …"),
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                },
                dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.cancel)) } },
            )
        }
    }
}

@Composable
private fun FormDialog(
    title: String,
    confirm: String,
    canConfirm: Boolean,
    cancelLabel: String,
    error: String?,
    dismiss: () -> Unit,
    onConfirm: () -> Unit,
    content: @Composable () -> Unit,
) {
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                content()
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = { TextButton(onClick = onConfirm, enabled = canConfirm) { Text(confirm) } },
        dismissButton = { TextButton(onClick = dismiss) { Text(cancelLabel) } },
    )
}

@Composable
private fun Field(value: String, onChange: (String) -> Unit, label: String, placeholder: String) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        placeholder = { Text(placeholder) },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun Hint(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** None, or one of the agent kinds the host's herdr can start. */
@Composable
private fun AgentPicker(app: AmiscaraApp, hostId: String, kind: String?, allowNone: Boolean = true, onChange: (String?) -> Unit) {
    var kinds by remember { mutableStateOf(emptyList<String>()) }
    var open by remember { mutableStateOf(false) }
    LaunchedEffect(hostId) {
        app.connections.session(hostId)?.let { session ->
            kinds = withContext(Dispatchers.IO) { runCatching { session.agentKinds() }.getOrDefault(emptyList()) }
        }
    }
    // The remembered choice stays selectable before the list has arrived.
    val options = if (kind != null && kind !in kinds) listOf(kind) + kinds else kinds
    Column {
        Text(stringResource(if (allowNone) R.string.agent_start else R.string.agent_kind), style = MaterialTheme.typography.labelLarge)
        Box {
            OutlinedButton(onClick = { open = true }, modifier = Modifier.fillMaxWidth()) {
                Text(kind ?: stringResource(R.string.agent_none))
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                if (allowNone) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.agent_none)) }, onClick = {
                        open = false
                        onChange(null)
                    })
                }
                options.forEach { option ->
                    DropdownMenuItem(text = { Text(option) }, onClick = {
                        open = false
                        onChange(option)
                    })
                }
            }
        }
    }
}
