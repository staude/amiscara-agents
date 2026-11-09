package net.staude.amiscara.agents.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.R

/**
 * "Neuigkeiten" (#382): the notes of the new versions once after an update,
 * from Settings all versions. Shown while `AmiscaraApp.whatsNew` has
 * entries; German when the device language is German, else English.
 */
@Composable
fun WhatsNewDialog(app: AmiscaraApp) {
    val entries by app.whatsNew.collectAsState()
    if (entries.isEmpty()) return
    val german = LocalConfiguration.current.locales[0].language == "de"
    val close = { app.whatsNew.value = emptyList() }
    AlertDialog(
        onDismissRequest = close,
        title = { Text(stringResource(R.string.whats_new_title)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                entries.forEach { entry ->
                    Text(
                        stringResource(R.string.whats_new_version, entry.version),
                        style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.padding(top = 8.dp, bottom = 4.dp),
                    )
                    entry.notes(german).forEach { note ->
                        Text("•  $note", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(bottom = 4.dp))
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = close) { Text(stringResource(R.string.close_button)) } },
    )
}
