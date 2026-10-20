package net.staude.amiscara.agents.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.AgentState

// Agent states as in `StatusStyle.swift`: blocked orange, working blue,
// done green.

@Composable
fun AgentState.color(): Color = when (this) {
    AgentState.BLOCKED -> Color(0xFFFF9F0A)
    AgentState.WORKING -> Color(0xFF0A84FF)
    AgentState.DONE -> Color(0xFF34C759)
    AgentState.IDLE -> MaterialTheme.colorScheme.onSurfaceVariant
    AgentState.UNKNOWN -> Color(0xFF8E8E93)
}

@Composable
fun AgentState.label(): String = stringResource(
    when (this) {
        AgentState.BLOCKED -> R.string.state_blocked
        AgentState.WORKING -> R.string.state_working
        AgentState.DONE -> R.string.state_done
        AgentState.IDLE -> R.string.state_idle
        AgentState.UNKNOWN -> R.string.state_unknown
    },
)

/** A filled dot for an agent, a ring for a plain shell (`state` null). */
@Composable
fun AgentDot(state: AgentState?, modifier: Modifier = Modifier) {
    if (state == null) {
        Box(modifier.size(8.dp).border(1.dp, MaterialTheme.colorScheme.onSurfaceVariant, CircleShape))
    } else {
        Box(modifier.size(8.dp).background(state.color(), CircleShape))
    }
}
