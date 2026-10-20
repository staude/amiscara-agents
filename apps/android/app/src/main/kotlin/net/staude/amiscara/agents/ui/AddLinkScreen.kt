package net.staude.amiscara.agents.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.decodeAddHostLink
import net.staude.amiscara.agents.core.publicKeyFingerprint

/**
 * Shows what an "add host" link says before the host is added. `trusted`:
 * scanned or pasted by the user, so its host key is pinned; a link opened
 * from elsewhere is not trusted (see `HostRepository.addFromLink`).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddLinkScreen(app: AmiscaraApp, text: String, trusted: Boolean, back: () -> Unit, added: (String) -> Unit) {
    val link = remember(text) { runCatching { decodeAddHostLink(text) } }
    val fingerprint = remember(link) { link.getOrNull()?.let { runCatching { publicKeyFingerprint(it.hostKey) }.getOrNull() } }
    var error by remember { mutableStateOf<String?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.link_title)) },
                navigationIcon = {
                    IconButton(onClick = back) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            link.fold(
                onSuccess = { link ->
                    Field(stringResource(R.string.field_name), link.name.ifEmpty { link.host })
                    Field(stringResource(R.string.field_host), "${link.user}@${link.host}:${link.port}")
                    Field(stringResource(R.string.field_socket), link.socketPath.ifEmpty { stringResource(R.string.link_socket_default) })
                    Field(stringResource(R.string.link_host_key), fingerprint ?: link.hostKey, monospace = true)
                    Text(
                        stringResource(if (trusted) R.string.link_trusted else R.string.link_untrusted),
                        color = if (trusted) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.error,
                    )
                    Button(onClick = {
                        runCatching { app.hosts.addFromLink(link, trustHostKey = trusted) }
                            .onSuccess { added(it.id) }
                            .onFailure { error = it.message }
                    }) { Text(stringResource(R.string.link_add)) }
                },
                onFailure = { Text(it.message ?: it.toString(), color = MaterialTheme.colorScheme.error) },
            )
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }
}

@Composable
private fun Field(label: String, value: String, monospace: Boolean = false) {
    Column {
        Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, fontFamily = if (monospace) FontFamily.Monospace else null)
    }
}
