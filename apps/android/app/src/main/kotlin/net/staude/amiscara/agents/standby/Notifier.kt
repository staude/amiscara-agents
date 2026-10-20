package net.staude.amiscara.agents.standby

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.net.toUri
import net.staude.amiscara.agents.MainActivity
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.AgentState
import net.staude.amiscara.agents.core.BoardItem
import net.staude.amiscara.agents.model.HostRepository

/**
 * Notifications when an agent starts waiting or finishes, from the core's
 * `SessionUpdate.attention`, as in the other apps: one per pane, a tap opens
 * the pane, a waiting agent's notification carries answer buttons.
 *
 * Without the standby they only come while Android lets the app run.
 */
class Notifier(private val context: Context, private val hosts: HostRepository) {
    private val manager = NotificationManagerCompat.from(context)

    /** The pane on screen, which gets no notification while the app is in front. */
    @Volatile
    var visiblePane: Pair<String, String>? = null
        set(value) {
            field = value
            if (value != null) cancel(value.first, value.second)
        }

    /** Whether the app is in front; set from the process lifecycle. */
    @Volatile
    var appActive = false
        set(value) {
            field = value
            if (value) visiblePane?.let { cancel(it.first, it.second) }
        }

    init {
        manager.createNotificationChannelsCompat(
            listOf(
                NotificationChannelCompat.Builder(CHANNEL_WAITING, NotificationManagerCompat.IMPORTANCE_HIGH)
                    .setName(context.getString(R.string.channel_waiting))
                    .setDescription(context.getString(R.string.channel_waiting_text))
                    .build(),
                // Heads-up, but silent: the Apple apps play no sound either.
                NotificationChannelCompat.Builder(CHANNEL_DONE, NotificationManagerCompat.IMPORTANCE_HIGH)
                    .setName(context.getString(R.string.channel_done))
                    .setDescription(context.getString(R.string.channel_done_text))
                    .setSound(null, null)
                    .build(),
                NotificationChannelCompat.Builder(CHANNEL_STANDBY, NotificationManagerCompat.IMPORTANCE_LOW)
                    .setName(context.getString(R.string.standby))
                    .setDescription(context.getString(R.string.channel_standby_text))
                    .setShowBadge(false)
                    .build(),
            ),
        )
    }

    /** Whether notifications may show (Android 13 asks for it). */
    fun allowed(): Boolean = manager.areNotificationsEnabled() &&
        (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)

    /** Posts one notification per agent that needs the user; any thread. */
    fun notify(hostId: String, items: List<BoardItem>) {
        val host = hosts.get(hostId) ?: return
        if (host.notify == false || !allowed()) return
        for (item in items) {
            if (appActive && visiblePane == (hostId to item.paneId)) continue
            post(hostId, host.name, item)
        }
    }

    fun cancel(hostId: String, paneId: String) = manager.cancel(tag(hostId, paneId), ID)

    @Suppress("MissingPermission") // checked in allowed()
    private fun post(hostId: String, hostName: String, item: BoardItem) {
        val blocked = item.agentState == AgentState.BLOCKED
        val agent = item.agent.ifEmpty { "Agent" }
        val place = item.workspaceGroup?.let { "${item.workspaceName} ($it)" } ?: item.workspaceName
        val subtitle = "$hostName · $place · Tab ${item.tabLabel}"
        val tag = tag(hostId, item.paneId)
        val open = Intent(Intent.ACTION_VIEW, openLink(hostId, item.workspaceId, item.paneId), context, MainActivity::class.java)
        val builder = NotificationCompat.Builder(context, if (blocked) CHANNEL_WAITING else CHANNEL_DONE)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(context.getString(if (blocked) R.string.notify_waiting else R.string.notify_done, agent))
            .setContentText(subtitle)
            .setStyle(NotificationCompat.BigTextStyle().bigText(listOf(subtitle, item.title).filter { it.isNotBlank() }.joinToString("\n")))
            .setCategory(if (blocked) NotificationCompat.CATEGORY_REMINDER else NotificationCompat.CATEGORY_STATUS)
            .setGroup(hostId)
            .setAutoCancel(true)
            .setContentIntent(PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_IMMUTABLE))
        if (blocked) {
            // Android shows three buttons at most; 1, 2 and 3 answer the
            // agents' dialogs (Enter takes the first choice, 3 says no).
            for (key in ANSWERS) {
                val answer = Intent(context, AnswerReceiver::class.java)
                    .putExtra(AnswerReceiver.HOST, hostId)
                    .putExtra(AnswerReceiver.PANE, item.paneId)
                    .putExtra(AnswerReceiver.KEY, key)
                val pending = PendingIntent.getBroadcast(context, "$tag/$key".hashCode(), answer, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                builder.addAction(
                    // An answer can approve what an agent does: a locked
                    // device asks for unlocking first, as on the iPhone.
                    NotificationCompat.Action.Builder(null, key, pending).setAuthenticationRequired(true).build(),
                )
            }
        }
        manager.notify(tag, ID, builder.build())
    }

    companion object {
        const val CHANNEL_WAITING = "waiting"
        const val CHANNEL_DONE = "done"
        const val CHANNEL_STANDBY = "standby"

        /** All agent notifications share the id; the tag tells host and pane. */
        private const val ID = 1
        private val ANSWERS = listOf("1", "2", "3")

        private fun tag(hostId: String, paneId: String) = "$hostId/$paneId"

        /** The same link `amiscara-agents://open` that other apps may open. */
        private fun openLink(hostId: String, workspaceId: String, paneId: String) =
            "amiscara-agents://open".toUri().buildUpon()
                .appendQueryParameter("host", hostId)
                .appendQueryParameter("workspace", workspaceId)
                .appendQueryParameter("pane", paneId)
                .build()
    }
}
