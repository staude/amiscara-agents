package net.staude.amiscara.agents.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.BuildConfig
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.supportedProtocol
import net.staude.amiscara.agents.model.TerminalAppearance
import net.staude.amiscara.agents.model.TerminalPrefs
import net.staude.amiscara.agents.model.TerminalScheme

/**
 * Settings of this device: terminal look and font, quick replies, the
 * keyboard shortcuts. Per host settings are in the host editor.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(app: AmiscaraApp, back: () -> Unit) {
    val terminal by app.settings.terminal.collectAsStateWithLifecycle()
    // Edited in place; saved when leaving, blank entries dropped.
    val replies = remember { mutableStateListOf<String>().apply { addAll(app.settings.quickReplies.value) } }
    val leave = {
        app.settings.setQuickReplies(replies)
        back()
    }
    BackHandler(onBack = leave)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.settings)) },
                navigationIcon = {
                    IconButton(onClick = leave) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Section(stringResource(R.string.settings_terminal))
            Text(stringResource(R.string.settings_appearance), style = MaterialTheme.typography.labelLarge)
            Choice(
                TerminalAppearance.entries,
                terminal.appearance,
                {
                    stringResource(
                        when (it) {
                            TerminalAppearance.APP -> R.string.appearance_app
                            TerminalAppearance.LIGHT -> R.string.appearance_light
                            TerminalAppearance.DARK -> R.string.appearance_dark
                        },
                    )
                },
            ) { app.settings.setTerminal(terminal.copy(appearance = it)) }
            Text(stringResource(R.string.settings_scheme), style = MaterialTheme.typography.labelLarge)
            Choice(
                TerminalScheme.entries,
                terminal.scheme,
                {
                    stringResource(
                        when (it) {
                            TerminalScheme.STANDARD -> R.string.scheme_standard
                            TerminalScheme.SOLARIZED -> R.string.scheme_solarized
                            TerminalScheme.APPLE -> R.string.scheme_apple
                        },
                    )
                },
            ) { app.settings.setTerminal(terminal.copy(scheme = it)) }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.settings_min_contrast))
                    Text(stringResource(R.string.settings_min_contrast_hint), style = MaterialTheme.typography.bodySmall)
                }
                Switch(checked = terminal.minContrast, onCheckedChange = { app.settings.setTerminal(terminal.copy(minContrast = it)) })
            }
            Text(stringResource(R.string.settings_font_size, terminal.fontSize.toInt()), style = MaterialTheme.typography.labelLarge)
            Slider(
                value = terminal.fontSize,
                onValueChange = { app.settings.setTerminal(terminal.copy(fontSize = kotlin.math.round(it))) },
                valueRange = TerminalPrefs.FONT_RANGE,
                steps = (TerminalPrefs.FONT_RANGE.endInclusive - TerminalPrefs.FONT_RANGE.start).toInt() - 1,
            )

            HorizontalDivider()
            Section(stringResource(R.string.settings_quick_replies))
            Text(stringResource(R.string.settings_quick_replies_hint), style = MaterialTheme.typography.bodySmall)
            replies.forEachIndexed { index, reply ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = reply,
                        onValueChange = { replies[index] = it },
                        singleLine = true,
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = { replies.removeAt(index) }) {
                        Icon(Icons.Default.Delete, contentDescription = stringResource(R.string.remove))
                    }
                }
            }
            TextButton(onClick = { replies.add("") }) {
                Icon(Icons.Default.Add, contentDescription = null)
                Text(stringResource(R.string.settings_reply_add))
            }

            HorizontalDivider()
            Section(stringResource(R.string.settings_shortcuts))
            Text(stringResource(R.string.settings_shortcuts_text), style = MaterialTheme.typography.bodySmall)

            HorizontalDivider()
            Section(stringResource(R.string.settings_about))
            Text(stringResource(R.string.settings_version, BuildConfig.VERSION_NAME, supportedProtocol().toInt()))
        }
    }
}

@Composable
private fun Section(title: String) {
    Text(title, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
}

@Composable
private fun <T> Choice(options: List<T>, selected: T, label: @Composable (T) -> String, onSelect: (T) -> Unit) {
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        options.forEachIndexed { index, option ->
            SegmentedButton(
                selected = option == selected,
                onClick = { onSelect(option) },
                shape = SegmentedButtonDefaults.itemShape(index, options.size),
            ) { Text(label(option), maxLines = 1) }
        }
    }
}
