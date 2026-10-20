package net.staude.amiscara.agents

import android.app.Application
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.flow.MutableStateFlow
import net.staude.amiscara.agents.model.AppLink
import net.staude.amiscara.agents.model.Connections
import net.staude.amiscara.agents.model.HostRepository
import net.staude.amiscara.agents.model.KeyVault

/** Holds the app-wide state: hosts, their sessions and opened links. */
class AmiscaraApp : Application() {
    lateinit var hosts: HostRepository
        private set
    lateinit var connections: Connections
        private set

    /** A link opened from outside the app, until the UI took it. */
    val openedLink = MutableStateFlow<AppLink?>(null)

    /**
     * Whether the app may reach private addresses: the home network, VPN
     * addresses and the emulator's host. Android 17 blocks them for apps
     * that target it until the user allows it.
     */
    val localNetworkAllowed = MutableStateFlow(true)

    /** Whether the app asked for the local network in this run already. */
    var localNetworkAsked = false

    override fun onCreate() {
        super.onCreate()
        hosts = HostRepository(this, KeyVault(this))
        connections = Connections(hosts, MainScope())
        localNetworkAllowed.value = hasLocalNetwork()
        // Coming back after a while: try failed hosts at once instead of
        // waiting for the next attempt.
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) = connections.reconnectStale()
        })
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
