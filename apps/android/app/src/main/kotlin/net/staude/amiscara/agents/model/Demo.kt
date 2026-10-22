package net.staude.amiscara.agents.model

import android.os.Bundle
import android.util.Base64
import net.staude.amiscara.agents.BuildConfig

/**
 * Screenshot demo (#199): `scripts/screenshots.sh` starts the debug build
 * with these extras. They replace the hosts with the demo session on the
 * Mac, in memory only, and open a screen. Release builds ignore them; the
 * activity still drops every extra afterwards.
 *
 * `demoHost`, `demoPort`, `demoUser`, `demoSocket`: the SSH host;
 * `demoKey`, `demoHostKey`: private key and pinned host key, Base64;
 * `demoPane`: the pane to open; `demoView`: `settings`, `conversation`,
 * `switcher` or `addHost` on top.
 */
object Demo {
    const val HOST_ID = "demo"

    fun read(extras: Bundle?, hosts: HostRepository): AppLink.Demo? {
        if (!BuildConfig.DEBUG || extras == null) return null
        val host = extras.getString("demoHost") ?: return null
        val key = decode(extras.getString("demoKey")) ?: return null
        hosts.useDemo(
            HostConfig(
                id = HOST_ID,
                name = "Mac Studio",
                host = host,
                port = extras.getString("demoPort")?.toIntOrNull() ?: 22,
                user = extras.getString("demoUser").orEmpty(),
                socketPath = extras.getString("demoSocket").orEmpty(),
                pinnedHostKey = decode(extras.getString("demoHostKey")),
                notify = false,
            ),
            key,
        )
        return AppLink.Demo(extras.getString("demoView").orEmpty(), extras.getString("demoPane")?.ifEmpty { null })
    }

    private fun decode(value: String?): String? =
        value?.takeIf { it.isNotEmpty() }?.let { String(Base64.decode(it, Base64.DEFAULT)) }
}
