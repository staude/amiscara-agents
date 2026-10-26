package net.staude.amiscara.agents.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import net.staude.amiscara.agents.core.Endpoint
import net.staude.amiscara.agents.core.SpaceSort

/**
 * One host; the fields and their JSON names follow `HostConfig` of the
 * other apps (`apps/desktop/src-tauri/src/hosts.rs`). Android only knows
 * SSH with a key of its own: no local socket, no SSH agent.
 */
@Serializable
data class HostConfig(
    val id: String,
    val name: String,
    val host: String,
    val port: Int = 22,
    val user: String,
    /** Absolute path of `herdr.sock` on the server. */
    val socketPath: String,
    /** Trusted host key as an OpenSSH public key line, once confirmed. */
    val pinnedHostKey: String? = null,
    /** Public half of this device's key, for `authorized_keys`. */
    val publicKey: String? = null,
    /** Whether the app may send prompts and keys; missing means on. */
    val allowInput: Boolean? = null,
    /** Whether files may be uploaded over SFTP; missing means off. */
    val allowUpload: Boolean? = null,
    /** Whether the key's line lets pages on the host's localhost through (#247); missing means off. */
    val allowWebForward: Boolean? = null,
    /** Notifications when an agent waits or finishes; missing means on. */
    val notify: Boolean? = null,
    /** Grouping of "Bereich/Name" spaces; missing means on. */
    val groupSpaces: Boolean? = null,
    /** Order of the sidebar's spaces (#245); missing means herdr's. */
    val spaceSort: SpaceSortMode? = null,
    /** Workspace IDs in the user's order, for [SpaceSortMode.MANUAL]. */
    val spaceOrder: List<String>? = null,
) {
    val groupSpacesByName: Boolean get() = groupSpaces ?: true

    /** The order for the core; a running session takes it without restarting. */
    val spaceSorting: SpaceSort
        get() = when (spaceSort) {
            null, SpaceSortMode.HERDR -> SpaceSort.Herdr
            SpaceSortMode.NAME_ASCENDING -> SpaceSort.NameAscending
            SpaceSortMode.NAME_DESCENDING -> SpaceSort.NameDescending
            SpaceSortMode.MANUAL -> SpaceSort.Manual(spaceOrder.orEmpty())
        }

    /**
     * The socket for an `authorized_keys` line: `null` for the default
     * below the login's home directory, which the line reaches via `$HOME`.
     */
    val customSocket: String?
        get() = socketPath.trim().takeIf { it.isNotEmpty() && !it.endsWith(DEFAULT_SOCKET_SUFFIX) }

    /** Whether a running session must restart after this change. */
    fun connectsDifferentlyThan(other: HostConfig): Boolean =
        host != other.host || port != other.port || user != other.user ||
            socketPath != other.socketPath || pinnedHostKey != other.pinnedHostKey ||
            publicKey != other.publicKey || groupSpacesByName != other.groupSpacesByName

    fun endpoint(privateKey: String) = Endpoint.Ssh(
        host = host,
        port = port.toUShort(),
        user = user,
        privateKeyOpenssh = privateKey,
        pinnedHostKey = pinnedHostKey,
        socketPath = socketPath,
    )

    companion object {
        const val DEFAULT_SOCKET_SUFFIX = "/.config/herdr/herdr.sock"

        /** Default socket of `user`: `/Users/...` on macOS, `/home/...` on Linux. */
        fun defaultSocket(user: String, macHost: Boolean) =
            "${if (macHost) "/Users" else "/home"}/$user$DEFAULT_SOCKET_SUFFIX"
    }
}

/** How the sidebar orders spaces; the JSON names follow `hosts.rs`. */
@Serializable
enum class SpaceSortMode {
    @SerialName("herdr") HERDR,
    @SerialName("nameAscending") NAME_ASCENDING,
    @SerialName("nameDescending") NAME_DESCENDING,
    @SerialName("manual") MANUAL,
}
