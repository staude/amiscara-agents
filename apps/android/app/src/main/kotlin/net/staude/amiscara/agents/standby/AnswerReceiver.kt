package net.staude.amiscara.agents.standby

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.widget.Toast
import kotlinx.coroutines.launch
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.R

/**
 * An answer button of a waiting agent's notification: sends its key to the
 * pane, also when the app was not in front or not running at all. Not
 * exported, only the notifications' intents reach it.
 */
class AnswerReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val hostId = intent.getStringExtra(HOST) ?: return
        val paneId = intent.getStringExtra(PANE) ?: return
        val key = intent.getStringExtra(KEY) ?: return
        val app = context.applicationContext as AmiscaraApp
        val pending = goAsync()
        app.scope.launch {
            try {
                // Without the standby the process may have been frozen and
                // its connection silently dropped: connect afresh.
                val fresh = !app.notifier.appActive && !app.settings.standby.value
                app.connections.sendWhenLive(hostId, paneId, listOf(key), fresh)
                    .onSuccess { app.notifier.cancel(hostId, paneId) }
                    .onFailure {
                        Toast.makeText(app, app.getString(R.string.answer_failed, it.message), Toast.LENGTH_LONG).show()
                    }
            } finally {
                pending.finish()
            }
        }
    }

    companion object {
        const val HOST = "host"
        const val PANE = "pane"
        const val KEY = "key"
    }
}
