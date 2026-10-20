package net.staude.amiscara.agents.standby

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import net.staude.amiscara.agents.AmiscaraApp

/**
 * Brings the standby back after the device started (if wanted) and after
 * an app update, which ends the service.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val settings = (context.applicationContext as AmiscaraApp).settings
        val start = when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED -> settings.standby.value && settings.standbyOnBoot.value
            Intent.ACTION_MY_PACKAGE_REPLACED -> settings.standby.value
            else -> false
        }
        if (start) StandbyService.apply(context, true)
    }
}
