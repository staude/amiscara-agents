package net.staude.amiscara.agents.standby

import android.content.ComponentName
import android.content.Context
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import net.staude.amiscara.agents.AmiscaraApp

/** Quick Settings tile that turns the standby on and off. */
class StandbyTile : TileService() {
    private val app get() = application as AmiscaraApp

    override fun onStartListening() {
        super.onStartListening()
        show()
    }

    override fun onClick() {
        super.onClick()
        app.setStandby(!app.settings.standby.value)
        show()
    }

    private fun show() {
        val tile = qsTile ?: return
        tile.state = if (app.settings.standby.value) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.updateTile()
    }

    companion object {
        /** Asks the system to show the tile's state again after a change in the app. */
        fun refresh(context: Context) {
            requestListeningState(context, ComponentName(context, StandbyTile::class.java))
        }
    }
}
