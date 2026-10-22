package net.staude.amiscara.agents

import android.app.Application
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch
import androidx.glance.appwidget.updateAll
import kotlinx.coroutines.flow.MutableStateFlow
import net.staude.amiscara.agents.model.AppLink
import net.staude.amiscara.agents.model.Connections
import net.staude.amiscara.agents.model.HostRepository
import net.staude.amiscara.agents.model.KeyVault
import net.staude.amiscara.agents.model.Settings
import net.staude.amiscara.agents.model.Shortcuts
import net.staude.amiscara.agents.standby.Notifier
import net.staude.amiscara.agents.standby.StandbyService
import net.staude.amiscara.agents.standby.StandbyTile
import net.staude.amiscara.agents.widget.AgentsWidget
import net.staude.amiscara.agents.widget.WidgetData
import net.staude.amiscara.agents.widget.WidgetSnapshot
import net.staude.amiscara.agents.model.Texts

/** Holds the app-wide state: hosts, their sessions, notifications and opened links. */
class AmiscaraApp : Application() {
    lateinit var hosts: HostRepository
        private set
    lateinit var connections: Connections
        private set
    lateinit var settings: Settings
        private set
    lateinit var notifier: Notifier
        private set
    lateinit var widgetData: WidgetData
        private set

    /** Main thread work that outlives the screens: sessions, standby, answers. */
    val scope: CoroutineScope = MainScope()

    /**
     * The link the user just scanned or pasted. Only this one may pin its
     * host key; the trust never travels in a route or intent, which another
     * app could set when starting the exported activity.
     */
    private var trustedLink: String? = null

    fun trustLink(text: String) {
        trustedLink = text
    }

    /** Whether `text` is the link the user scanned or pasted; asks once. */
    fun takeTrust(text: String): Boolean = (trustedLink == text).also { if (it) trustedLink = null }

    /** Hardware keyboard shortcuts of the screens on display. */
    val shortcuts = Shortcuts()

    /** A link opened from outside the app, until the UI took it. */
    val openedLink = MutableStateFlow<AppLink?>(null)

    /**
     * Whether the app may reach private addresses: the home network, VPN
     * addresses and the emulator's host. Android 17 blocks them for apps
     * that target it until the user allows it.
     */
    val localNetworkAllowed = MutableStateFlow(true)

    /** Whether the app asked for the local network and notifications in this run. */
    var permissionsAsked = false

    override fun onCreate() {
        super.onCreate()
        Texts.init(this)
        settings = Settings(this)
        hosts = HostRepository(this, KeyVault(this))
        notifier = Notifier(this, hosts)
        connections = Connections(hosts, scope, notifier::notify)
        localNetworkAllowed.value = hasLocalNetwork()
        widgetData = WidgetData(this)
        // The widget follows the live hosts, at most once a second.
        scope.launch {
            combine(hosts.hosts, connections.updates) { list, updates -> WidgetSnapshot.of(list, updates, System.currentTimeMillis()) }
                .filterNotNull()
                .conflate()
                .collect {
                    if (widgetData.save(it)) AgentsWidget().updateAll(this@AmiscaraApp)
                    delay(1_000)
                }
        }
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                // Coming back after a while: try failed hosts at once
                // instead of waiting for the next attempt.
                connections.reconnectStale()
                // In front, the app may start the service, e.g. after the
                // system ended it.
                StandbyService.apply(this@AmiscaraApp, settings.standby.value)
            }

            override fun onResume(owner: LifecycleOwner) {
                notifier.appActive = true
            }

            override fun onPause(owner: LifecycleOwner) {
                notifier.appActive = false
            }
        })
    }

    /** Turns the standby on or off, from the settings, the tile or its notification. */
    fun setStandby(on: Boolean) {
        settings.setStandby(on)
        StandbyService.apply(this, on)
        StandbyTile.refresh(this)
    }

    /** Checks the permission again; sessions start over once it is there. */
    fun refreshLocalNetwork() {
        val allowed = hasLocalNetwork()
        if (allowed && !localNetworkAllowed.value) connections.reconnectAll()
        localNetworkAllowed.value = allowed
    }

    private fun hasLocalNetwork() = Build.VERSION.SDK_INT < LOCAL_NETWORK_SDK ||
        checkSelfPermission(LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED

    fun open(uri: Uri) {
        AppLink.parse(uri)?.let { openedLink.value = it }
    }

    companion object {
        /** `Manifest.permission.ACCESS_LOCAL_NETWORK`, from Android 17 (API 37). */
        const val LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
        const val LOCAL_NETWORK_SDK = 37
    }
}
