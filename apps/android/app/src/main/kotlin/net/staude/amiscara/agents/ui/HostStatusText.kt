package net.staude.amiscara.agents.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.HostStatus
import net.staude.amiscara.agents.core.SessionUpdate

// Texts for a host's connection state, as in the other apps
// (`HostPanel.svelte`, `HostConnection.statusSummary`).

@Composable
fun statusSummary(update: SessionUpdate?, startError: String?): String = when {
    startError != null -> stringResource(R.string.status_not_started)
    else -> when (val status = update?.status) {
        null, HostStatus.Connecting -> stringResource(R.string.status_connecting)
        HostStatus.Live -> update.serverVersion?.let { stringResource(R.string.status_live_version, it) }
            ?: stringResource(R.string.status_live)
        is HostStatus.Retrying -> stringResource(R.string.status_retrying, status.attempt.toInt())
        is HostStatus.HostKeyUnknown -> stringResource(R.string.status_key_unknown)
        is HostStatus.HostKeyChanged -> stringResource(R.string.status_key_changed)
        is HostStatus.Failed -> stringResource(R.string.status_failed)
    }
}

/** The error behind the state, for showing as is. */
fun statusDetail(update: SessionUpdate?, startError: String?): String? = startError ?: when (val status = update?.status) {
    is HostStatus.Retrying -> status.error
    is HostStatus.Failed -> status.error
    else -> null
}

/** What the user can check, guessed from the error. */
@Composable
fun statusHint(update: SessionUpdate?): String? = when (val status = update?.status) {
    is HostStatus.Failed -> stringResource(R.string.hint_failed)
    is HostStatus.Retrying -> {
        val text = status.error.lowercase()
        when {
            listOf("timed out", "timeout", "unreachable", "no route", "lookup", "resolve").any { it in text } ->
                stringResource(R.string.hint_unreachable)
            "refused" in text -> stringResource(R.string.hint_refused)
            "channel" in text || "no such file" in text -> stringResource(R.string.hint_socket)
            else -> null
        }
    }
    else -> null
}

private val Green = Color(0xFF34C759)
private val Orange = Color(0xFFFF9F0A)
private val Red = Color(0xFFFF3B30)
private val Gray = Color(0xFF8E8E93)

/** A dot in the colors of `HostStatusLabel.swift`. */
@Composable
fun StatusDot(update: SessionUpdate?, startError: String?, modifier: Modifier = Modifier) {
    val color = when {
        startError != null -> Red
        else -> when (update?.status) {
            HostStatus.Live -> Green
            is HostStatus.Retrying, is HostStatus.HostKeyUnknown, is HostStatus.HostKeyChanged -> Orange
            is HostStatus.Failed -> Red
            null, HostStatus.Connecting -> Gray
        }
    }
    Box(modifier.size(10.dp).background(color, CircleShape))
}
