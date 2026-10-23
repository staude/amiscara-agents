package net.staude.amiscara.agents.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.FfiException
import net.staude.amiscara.agents.core.HerdrSession
import net.staude.amiscara.agents.core.HostStatus
import net.staude.amiscara.agents.core.isValidSessionName
import net.staude.amiscara.agents.core.sessionNameOfSocket
import net.staude.amiscara.agents.core.sessionSocketPath
import net.staude.amiscara.agents.model.HostConfig

/** What reading a host's sessions gave. */
private sealed interface SessionList {
    data object Loading : SessionList
    data class Read(val sessions: List<HerdrSession>) : SessionList
    data class Failed(val message: String) : SessionList
}

/**
 * Picks a further herdr session on the machine of `host` (#213): the
 * sessions read from the host (needs its live connection and SFTP) or a
 * typed name. `chosen` gets the socket path of the session.
 */
@Composable
fun SessionPicker(app: AmiscaraApp, host: HostConfig, dismiss: () -> Unit, chosen: (String) -> Unit) {
    val hosts by app.hosts.hosts.collectAsStateWithLifecycle()
    val updates by app.connections.updates.collectAsStateWithLifecycle()
    val live = updates[host.id]?.status == HostStatus.Live
    val noSftp = stringResource(R.string.add_session_no_sftp)
    val offline = stringResource(R.string.add_session_offline)
    var list by remember { mutableStateOf<SessionList>(SessionList.Loading) }
    var typed by remember { mutableStateOf("") }

    LaunchedEffect(host.id, live) {
        val session = app.connections.session(host.id)
        list = if (!live || session == null) {
            SessionList.Failed(offline)
        } else {
            withContext(Dispatchers.IO) {
                try {
                    SessionList.Read(session.herdrSessions())
                } catch (_: FfiException.Files) {
                    SessionList.Failed(noSftp)
                } catch (e: FfiException) {
                    SessionList.Failed(e.message ?: e.toString())
                }
            }
        }
    }

    fun socketOf(name: String): String? = try {
        sessionSocketPath(host.socketPath, name)
    } catch (_: FfiException) {
        null
    }

    // Sessions on the same machine that have no entry yet.
    val taken = hosts.filter { it.host == host.host && it.port == host.port && it.user == host.user }
        .map { it.socketPath }
        .toSet()
    val current = sessionNameOfSocket(host.socketPath)
    val offered = buildList {
        if (current != null) add(Triple("", null as Boolean?, socketOf("")))
        (list as? SessionList.Read)?.sessions?.forEach { add(Triple(it.name, it.running, socketOf(it.name))) }
    }.filter { (_, _, socket) -> socket != null && socket !in taken }
    val typedSocket = typed.trim().takeIf { isValidSessionName(it) }?.let(::socketOf)

    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text(stringResource(R.string.add_session_title, host.name)) },
        text = {
            Column(
                Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                when (val state = list) {
                    SessionList.Loading -> Text(stringResource(R.string.add_session_loading))
                    is SessionList.Failed -> Text(state.message, style = MaterialTheme.typography.bodySmall)
                    is SessionList.Read -> if (offered.isEmpty()) {
                        Text(stringResource(R.string.add_session_none), style = MaterialTheme.typography.bodySmall)
                    }
                }
                for ((name, running, socket) in offered) {
                    val label = if (name.isEmpty()) stringResource(R.string.add_session_default) else name
                    ListItem(
                        headlineContent = {
                            Text(if (running == false) stringResource(R.string.add_session_stopped, label) else label)
                        },
                        modifier = Modifier.fillMaxWidth().clickable { socket?.let(chosen) },
                    )
                }
                OutlinedTextField(
                    value = typed,
                    onValueChange = { typed = it },
                    label = { Text(stringResource(R.string.add_session_other)) },
                    isError = typed.isNotBlank() && typedSocket == null,
                    supportingText = if (typed.isNotBlank() && typedSocket == null) {
                        { Text(stringResource(R.string.error_session_name)) }
                    } else {
                        null
                    },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { typedSocket?.let(chosen) }, enabled = typedSocket != null) {
                Text(stringResource(R.string.add_session_continue))
            }
        },
        dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.cancel)) } },
    )
}
