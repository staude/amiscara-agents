package net.staude.amiscara.agents.model

import android.net.Uri
import net.staude.amiscara.agents.R

// Helpers for "add host" links and host keys. The link format and its
// strict checks live in Rust (`herdr_session::link`); this only connects
// them to the app, like `HostLink.swift`.

/** "Mac.Example.Internal." and "mac.example.internal" are one host. */
fun normalizedHost(host: String): String = host.trim().lowercase().trimEnd('.')

/** Same algorithm and key data; the comment does not matter. */
fun sameKey(a: String, b: String): Boolean {
    fun fields(line: String) = line.trim().split(Regex("\\s+")).take(2)
    return fields(a) == fields(b)
}

/**
 * Why `key` from a link must not be pinned for `host`:`port`, or `null`. A
 * link never replaces a host key the user already trusts at that address:
 * that is exactly what a forged link would try.
 */
fun hostKeyConflict(hosts: List<HostConfig>, host: String, port: Int, key: String): String? {
    val address = normalizedHost(host)
    val other = hosts.firstOrNull {
        normalizedHost(it.host) == address && it.port == port &&
            it.pinnedHostKey != null && !sameKey(it.pinnedHostKey, key)
    } ?: return null
    return Texts.get(R.string.error_host_key_conflict, other.name)
}

/** What an opened `amiscara-agents://` link asks for. */
sealed interface AppLink {
    /** `amiscara-agents://add-host?v=1&...`; decoded by the core. */
    data class AddHost(val text: String) : AppLink

    /** `amiscara-agents://open?host=...&workspace=...&pane=...`. */
    data class Open(val hostId: String, val workspaceId: String?, val paneId: String?) : AppLink {
        /** The link itself, for notifications and the widget. */
        fun uri(): Uri = Uri.Builder().scheme("amiscara-agents").authority("open")
            .appendQueryParameter("host", hostId)
            .apply {
                workspaceId?.let { appendQueryParameter("workspace", it) }
                paneId?.let { appendQueryParameter("pane", it) }
            }
            .build()
    }

    /** The screenshot demo's screen, see [Demo]; never from a link. */
    data class Demo(val view: String, val paneId: String?) : AppLink

    companion object {
        fun parse(uri: Uri): AppLink? {
            if (uri.scheme?.lowercase() != "amiscara-agents") return null
            return when (uri.host?.lowercase()) {
                "add-host" -> AddHost(uri.toString())
                "open" -> uri.getQueryParameter("host")?.let {
                    Open(it, uri.getQueryParameter("workspace"), uri.getQueryParameter("pane"))
                }
                else -> null
            }
        }
    }
}
