package net.staude.amiscara.agents.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings as SystemSettings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.BuildConfig
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.supportedProtocol
import net.staude.amiscara.agents.model.TerminalAppearance
import net.staude.amiscara.agents.model.TerminalPrefs
import net.staude.amiscara.agents.model.TerminalScheme

/**
 * Settings of this device: standby and notifications, terminal look and
 * font, quick replies, the keyboard shortcuts. Per host settings are in the
 * host editor.
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

    val context = LocalContext.current
    val standby by app.settings.standby.collectAsStateWithLifecycle()
    val standbyOnBoot by app.settings.standbyOnBoot.collectAsStateWithLifecycle()
    // Both can change in the system settings meanwhile.
    var notificationsAllowed by remember { mutableStateOf(app.notifier.allowed()) }
    var batteryExempt by remember { mutableStateOf(context.batteryExempt()) }
    LifecycleResumeEffect(Unit) {
        notificationsAllowed = app.notifier.allowed()
        batteryExempt = context.batteryExempt()
        onPauseOrDispose {}
    }
    // Android asks twice at most; after a refusal the system settings help.
    var refused by remember { mutableStateOf(false) }
    val askNotifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        notificationsAllowed = app.notifier.allowed()
        refused = !granted
    }
    val allowNotifications = {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !refused &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            context.startActivity(
                Intent(SystemSettings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(SystemSettings.EXTRA_APP_PACKAGE, context.packageName),
            )
        }
    }

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
            Section(stringResource(R.string.settings_notifications))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.standby))
                    Text(stringResource(R.string.settings_standby_text), style = MaterialTheme.typography.bodySmall)
                }
                Switch(
                    checked = standby,
                    onCheckedChange = {
                        app.setStandby(it)
                        if (it && !notificationsAllowed) allowNotifications()
                    },
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.settings_standby_boot), Modifier.weight(1f))
                Switch(checked = standbyOnBoot, onCheckedChange = app.settings::setStandbyOnBoot, enabled = standby)
            }
            if (!notificationsAllowed) {
                Hint(stringResource(R.string.settings_notifications_off), stringResource(R.string.settings_notifications_allow), allowNotifications)
            }
            if (standby && !batteryExempt) {
                Hint(stringResource(R.string.settings_battery_hint), stringResource(R.string.settings_battery_open)) {
                    context.startActivity(Intent(SystemSettings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                }
            }
            Text(stringResource(R.string.settings_notifications_text), style = MaterialTheme.typography.bodySmall)

            HorizontalDivider()
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
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.settings_wrap_lines))
                    Text(stringResource(R.string.settings_wrap_lines_hint), style = MaterialTheme.typography.bodySmall)
                }
                Switch(checked = terminal.wrapLines, onCheckedChange = { app.settings.setTerminal(terminal.copy(wrapLines = it)) })
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

/** A note with a button that fixes it. */
@Composable
private fun Hint(text: String, action: String, onClick: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(text, Modifier.weight(1f), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
        TextButton(onClick = onClick) { Text(action) }
    }
}

private fun Context.batteryExempt(): Boolean =
    getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)

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
