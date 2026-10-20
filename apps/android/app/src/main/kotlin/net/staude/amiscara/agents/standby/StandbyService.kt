package net.staude.amiscara.agents.standby

import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.MainActivity
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.AgentState
import net.staude.amiscara.agents.core.HostStatus
import net.staude.amiscara.agents.core.SessionUpdate
import net.staude.amiscara.agents.model.HostConfig

/**
 * The standby: a foreground service that keeps the app's process, and with
 * it the host sessions in [AmiscaraApp.connections], running in the
 * background, like the desktop app in the tray. Its ongoing notification
 * tells how many hosts are connected and agents wait.
 */
class StandbyService : Service() {
    private var watch: Job? = null

    private val app get() = application as AmiscaraApp

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            app.setStandby(false)
            return START_NOT_STICKY
        }
        // First of all: a service started with startForegroundService must
        // show its notification in time, even when it ends right away.
        try {
            ServiceCompat.startForeground(this, ID, notification(status(app.hosts.hosts.value, app.connections.updates.value)), SPECIAL_USE)
        } catch (e: IllegalStateException) {
            // Started again by the system while the app may not start a
            // foreground service; the app starts it when opened.
            stopSelf()
            return START_NOT_STICKY
        }
        if (!app.settings.standby.value) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (watch == null) {
            watch = app.scope.launch {
                combine(app.hosts.hosts, app.connections.updates, ::status).collect(::show)
            }
        }
        // Back after the system ended it for memory; only with the app's
        // permission to start a foreground service, see above.
        return START_STICKY
    }

    override fun onDestroy() {
        watch?.cancel()
        super.onDestroy()
    }

    /** Hosts, how many of them are live, waiting agents. */
    private data class Status(val hosts: Int, val live: Int, val waiting: Int)

    private fun status(hosts: List<HostConfig>, updates: Map<String, SessionUpdate>) = Status(
        hosts.size,
        hosts.count { updates[it.id]?.status is HostStatus.Live },
        hosts.sumOf { host -> updates[host.id]?.board?.count { it.agentState == AgentState.BLOCKED } ?: 0 },
    )

    @Suppress("MissingPermission") // without it, Android lists the service in the task manager only
    private fun show(status: Status) {
        NotificationManagerCompat.from(this).notify(ID, notification(status))
    }

    private fun notification(status: Status) =
        NotificationCompat.Builder(this, Notifier.CHANNEL_STANDBY)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(getString(R.string.standby))
            .setContentText(
                listOfNotNull(
                    resources.getQuantityString(R.plurals.standby_hosts, status.hosts, status.live, status.hosts),
                    status.waiting.takeIf { it > 0 }?.let { resources.getQuantityString(R.plurals.standby_waiting, it, it) },
                ).joinToString(" · "),
            )
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(
                PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE),
            )
            .addAction(
                NotificationCompat.Action.Builder(
                    null,
                    getString(R.string.standby_stop),
                    PendingIntent.getService(this, 0, Intent(this, StandbyService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE),
                ).build(),
            )
            .build()

    companion object {
        private const val ID = 2
        private const val ACTION_STOP = "net.staude.amiscara.agents.STOP_STANDBY"
        private val SPECIAL_USE =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0

        /**
         * Starts or ends the service as the setting says. Starting fails
         * while the app may not start a foreground service from the
         * background; it is tried again when the app comes to the front.
         */
        fun apply(context: Context, on: Boolean) {
            val intent = Intent(context, StandbyService::class.java)
            if (!on) {
                context.stopService(intent)
                return
            }
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (e: IllegalStateException) {
                // ForegroundServiceStartNotAllowedException, see above.
            }
        }
    }
}
