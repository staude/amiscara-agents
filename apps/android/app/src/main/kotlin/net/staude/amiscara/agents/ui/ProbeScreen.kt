package net.staude.amiscara.agents.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.generateSshKey
import net.staude.amiscara.agents.core.maxHistoryLines
import net.staude.amiscara.agents.core.supportedProtocol

/**
 * First screen of the Android app (#173): shows that the Rust core loads
 * and answers. Hosts and the real views follow in #174 and #175.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProbeScreen() {
    val core = remember { runCatching { supportedProtocol() to maxHistoryLines() } }
    var key by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    Scaffold(topBar = { TopAppBar(title = { Text(stringResource(R.string.app_name)) }) }) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            core.fold(
                onSuccess = { (protocol, history) ->
                    Text(stringResource(R.string.probe_core_loaded), style = MaterialTheme.typography.titleMedium)
                    Text(stringResource(R.string.probe_protocol, protocol.toInt()))
                    Text(pluralStringResource(R.plurals.probe_history, history.toInt(), history.toInt()))
                    Button(onClick = {
                        scope.launch {
                            key = withContext(Dispatchers.Default) {
                                runCatching { generateSshKey("amiscara-android") }
                                    .fold({ "${it.fingerprint}\n\n${it.publicOpenssh}" }, { it.message ?: it.toString() })
                            }
                        }
                    }) {
                        Text(stringResource(R.string.probe_generate_key))
                    }
                    key?.let {
                        SelectionContainer {
                            Text(it, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                },
                onFailure = {
                    Text(stringResource(R.string.probe_core_failed, it.message ?: it.toString()))
                },
            )
        }
    }
}
