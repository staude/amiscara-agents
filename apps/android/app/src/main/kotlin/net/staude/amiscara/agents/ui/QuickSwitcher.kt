package net.staude.amiscara.agents.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.model.SpaceSelection
import net.staude.amiscara.agents.model.filterSwitcher
import net.staude.amiscara.agents.model.switcherEntries

/** Ctrl+K: spaces and agents on all hosts by name, like `QuickSwitcher.swift`. */
@Composable
fun QuickSwitcher(app: AmiscaraApp, dismiss: () -> Unit, open: (SpaceSelection) -> Unit) {
    val hosts by app.hosts.hosts.collectAsStateWithLifecycle()
    val updates by app.connections.updates.collectAsStateWithLifecycle()
    var query by remember { mutableStateOf("") }
    val all = remember(hosts, updates) { switcherEntries(hosts, updates) }
    val hits = remember(all, query) { filterSwitcher(all, query) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }

    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text(stringResource(R.string.switcher)) },
        text = {
            Column {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    placeholder = { Text(stringResource(R.string.switcher_placeholder)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { hits.firstOrNull()?.let { open(it.selection) } }),
                    modifier = Modifier.fillMaxWidth().focusRequester(focus),
                )
                if (hits.isEmpty()) {
                    Text(stringResource(R.string.switcher_empty), Modifier.padding(top = 12.dp))
                }
                LazyColumn(Modifier.heightIn(max = 360.dp).padding(top = 8.dp)) {
                    items(hits, key = { "${it.selection}" }) { entry ->
                        ListItem(
                            modifier = Modifier.clickable { open(entry.selection) },
                            leadingContent = { AgentDot(entry.state.takeIf { entry.isAgent || it != null }) },
                            headlineContent = { Text(entry.title, maxLines = 1) },
                            supportingContent = {
                                Text(
                                    listOfNotNull(entry.subtitle, entry.hostName.takeIf { hosts.size > 1 }).joinToString(" · "),
                                    maxLines = 1,
                                    style = MaterialTheme.typography.bodySmall,
                                )
                            },
                        )
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.cancel)) } },
    )
}
