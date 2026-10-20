package net.staude.amiscara.agents.widget

import android.content.Context
import android.content.Intent
import android.text.format.DateFormat
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.Action
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.MainActivity
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.AgentState
import net.staude.amiscara.agents.model.AppLink

/**
 * Home screen widget like `AgentsWidget.swift`: small, the number of
 * waiting agents (a tap opens the first); larger, the agents of all hosts.
 * It shows what the app last saw: live with the standby, else as of
 * "Stand".
 */
class AgentsWidget : GlanceAppWidget() {
    // The real size, for as many rows as fit.
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val data = (context.applicationContext as AmiscaraApp).widgetData
        provideContent {
            val snapshot by data.snapshot.collectAsState()
            GlanceTheme {
                if (LocalSize.current.width < LIST_WIDTH) Small(snapshot) else AgentList(snapshot)
            }
        }
    }

    private companion object {
        /** From about three cells wide the list. */
        val LIST_WIDTH = 250.dp
    }
}

class AgentsWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = AgentsWidget()
}

@Composable
private fun Small(snapshot: WidgetSnapshot) {
    val context = LocalContext.current
    val waiting = snapshot.waiting
    val first = snapshot.agents.firstOrNull { it.state == AgentState.BLOCKED }
    Column(
        GlanceModifier.fillMaxSize().background(GlanceTheme.colors.widgetBackground).padding(12.dp)
            .clickable(open(context, first)),
    ) {
        Text(
            "$waiting",
            style = TextStyle(
                fontSize = 40.sp,
                fontWeight = FontWeight.Bold,
                color = if (waiting > 0) ColorProvider(ORANGE) else GlanceTheme.colors.onSurfaceVariant,
            ),
        )
        Text(context.getString(if (waiting == 1) R.string.widget_waits else R.string.widget_wait), style = TextStyle(fontWeight = FontWeight.Medium, color = GlanceTheme.colors.onSurface))
        Spacer(GlanceModifier.defaultWeight())
        if (snapshot.working > 0) {
            Text(context.resources.getQuantityString(R.plurals.widget_working, snapshot.working, snapshot.working), style = TextStyle(fontSize = 12.sp, color = ColorProvider(BLUE)))
        }
        Footer(snapshot)
    }
}

@Composable
private fun AgentList(snapshot: WidgetSnapshot) {
    val context = LocalContext.current
    val rows = ((LocalSize.current.height.value - 64) / 34).toInt().coerceAtLeast(1)
    Column(GlanceModifier.fillMaxSize().background(GlanceTheme.colors.widgetBackground).padding(12.dp)) {
        Row(GlanceModifier.fillMaxWidth().clickable(open(context, null)), verticalAlignment = Alignment.CenterVertically) {
            Text(context.getString(R.string.widget_title), style = TextStyle(fontWeight = FontWeight.Bold, color = GlanceTheme.colors.onSurface))
            Spacer(GlanceModifier.defaultWeight())
            if (snapshot.waiting > 0) {
                Text(
                    context.resources.getQuantityString(R.plurals.widget_waiting_count, snapshot.waiting, snapshot.waiting),
                    style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium, color = ColorProvider(ORANGE)),
                )
            }
        }
        Spacer(GlanceModifier.height(6.dp))
        if (snapshot.agents.isEmpty()) {
            Box(GlanceModifier.defaultWeight().fillMaxWidth(), contentAlignment = Alignment.CenterStart) {
                Text(
                    context.getString(if (snapshot.updated == 0L) R.string.widget_no_data else R.string.widget_no_agents),
                    style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant),
                )
            }
        } else {
            val manyHosts = snapshot.agents.distinctBy { it.hostId }.size > 1
            for (agent in snapshot.agents.take(rows)) {
                AgentRow(agent, manyHosts, open(context, agent))
            }
            Spacer(GlanceModifier.defaultWeight())
        }
        Footer(snapshot)
    }
}

@Composable
private fun AgentRow(agent: WidgetSnapshot.Agent, withHost: Boolean, onClick: Action) {
    val context = LocalContext.current
    Row(GlanceModifier.fillMaxWidth().height(34.dp).clickable(onClick), verticalAlignment = Alignment.CenterVertically) {
        Box(GlanceModifier.size(8.dp).cornerRadius(4.dp).background(ColorProvider(agent.state.widgetColor()))) {}
        Spacer(GlanceModifier.width(8.dp))
        Column(GlanceModifier.defaultWeight()) {
            Text(agent.place, maxLines = 1, style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium, color = GlanceTheme.colors.onSurface))
            Text(
                listOfNotNull(agent.name, agent.hostName.takeIf { withHost }).joinToString(" · "),
                maxLines = 1,
                style = TextStyle(fontSize = 11.sp, color = GlanceTheme.colors.onSurfaceVariant),
            )
        }
        Text(context.getString(agent.state.labelRes()), style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium, color = ColorProvider(agent.state.widgetColor())))
    }
}

/** How old the data is: without the standby it only changes while the app runs. */
@Composable
private fun Footer(snapshot: WidgetSnapshot) {
    val context = LocalContext.current
    val text = if (snapshot.updated == 0L) {
        context.getString(R.string.widget_no_data_short)
    } else {
        context.getString(R.string.widget_updated, DateFormat.getTimeFormat(context).format(snapshot.updated))
    }
    Text(text, maxLines = 1, style = TextStyle(fontSize = 11.sp, color = GlanceTheme.colors.outline))
}

/** Opens the agent's pane, or the app. */
private fun open(context: Context, agent: WidgetSnapshot.Agent?): Action {
    val intent = if (agent == null) {
        Intent(context, MainActivity::class.java)
    } else {
        Intent(Intent.ACTION_VIEW, AppLink.Open(agent.hostId, agent.workspaceId, agent.paneId).uri(), context, MainActivity::class.java)
    }
    return actionStartActivity(intent)
}

// As `AgentStyle.kt`, without a Compose theme.
private val ORANGE = Color(0xFFFF9F0A)
private val BLUE = Color(0xFF0A84FF)

private fun AgentState.widgetColor(): Color = when (this) {
    AgentState.BLOCKED -> ORANGE
    AgentState.WORKING -> BLUE
    AgentState.DONE -> Color(0xFF34C759)
    AgentState.IDLE, AgentState.UNKNOWN -> Color(0xFF8E8E93)
}

private fun AgentState.labelRes(): Int = when (this) {
    AgentState.BLOCKED -> R.string.state_blocked
    AgentState.WORKING -> R.string.state_working
    AgentState.DONE -> R.string.state_done
    AgentState.IDLE -> R.string.state_idle
    AgentState.UNKNOWN -> R.string.state_unknown
}
