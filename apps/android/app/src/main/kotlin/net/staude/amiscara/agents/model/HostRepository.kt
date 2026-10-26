package net.staude.amiscara.agents.model

import android.content.Context
import android.os.Build
import android.util.AtomicFile
import java.io.File
import java.io.FileNotFoundException
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import net.staude.amiscara.agents.core.AddHostLink
import net.staude.amiscara.agents.core.defaultRemoteSocket
import net.staude.amiscara.agents.core.generateSshKey
import net.staude.amiscara.agents.R

/** A host could not be saved; the message is German and meant for the user. */
class HostException(message: String) : Exception(message)

/**
 * The hosts the user added, as `hosts.json` in the app's files (same
 * format as the desktop app), with their private keys in the [KeyVault].
 * Writes are synchronized; the list is published as a flow.
 */
/** `hosts.json`'s format; a sort mode of a newer app reads as missing. */
internal val hostJson = Json {
    ignoreUnknownKeys = true
    coerceInputValues = true
    prettyPrint = true
}

class HostRepository(context: Context, private val vault: KeyVault) {
    private val file = AtomicFile(File(context.filesDir, "hosts.json"))
    private val state = MutableStateFlow(load())

    /** Whether the screenshot demo replaced the hosts; then nothing is written. */
    private var demo = false

    /** The hosts in the order the user sees them. */
    val hosts: StateFlow<List<HostConfig>> = state.asStateFlow()

    fun get(id: String): HostConfig? = state.value.firstOrNull { it.id == id }

    fun privateKey(id: String): String? = vault.load(id)

    /**
     * Checks and stores `draft`, adding or replacing the host with its id.
     * A new host (empty id) gets an id and a key of its own.
     */
    @Synchronized
    fun save(draft: HostConfig): HostConfig {
        // The editor holds an older copy; the sidebar's order stays as stored.
        val stored = get(draft.id)
        var host = draft.copy(
            id = draft.id.ifEmpty { UUID.randomUUID().toString() },
            spaceSort = stored?.spaceSort,
            spaceOrder = stored?.spaceOrder,
            name = draft.name.trim(),
            host = draft.host.trim(),
            user = draft.user.trim(),
            socketPath = draft.socketPath.trim(),
        )
        if (host.host.isEmpty() || host.user.isEmpty()) throw HostException(Texts.get(R.string.error_host_user_missing))
        if (host.port !in 1..65535) throw HostException(Texts.get(R.string.error_port_range))
        if (!host.socketPath.startsWith("/")) {
            throw HostException(Texts.get(R.string.error_socket_absolute))
        }
        if (host.name.isEmpty()) host = host.copy(name = host.host)
        if (host.publicKey == null || vault.load(host.id) == null) {
            host = host.copy(publicKey = newKey(host.id))
        }
        put(host)
        return host
    }

    @Synchronized
    fun remove(id: String) {
        vault.delete(id)
        write(state.value.filter { it.id != id })
    }

    /** Replaces the host's key; the old line in `authorized_keys` stops working. */
    @Synchronized
    fun regenerateKey(id: String): HostConfig {
        val host = get(id)?.copy(publicKey = newKey(id)) ?: throw HostException(Texts.get(R.string.error_host_gone))
        put(host)
        return host
    }

    /** The screenshot demo's host instead of the saved ones until the app ends (#199). */
    @Synchronized
    fun useDemo(host: HostConfig, privateKey: String) {
        demo = true
        vault.store(host.id, privateKey)
        state.value = listOf(host)
    }

    /** Stores how the host's spaces are ordered, `order` for [SpaceSortMode.MANUAL]. */
    @Synchronized
    fun setSpaceSort(id: String, mode: SpaceSortMode, order: List<String>?) {
        val host = get(id) ?: return
        put(host.copy(spaceSort = mode, spaceOrder = order))
    }

    /** Pins `key` after the user confirmed its fingerprint. */
    @Synchronized
    fun trustHostKey(id: String, key: String) {
        val host = get(id) ?: return
        put(host.copy(pinnedHostKey = key))
    }

    /**
     * Adds the host of a confirmed link with a key of its own.
     * `trustHostKey` pins the link's host key: only for links the user
     * scanned or pasted. A link opened from elsewhere can come from any web
     * page, so its key is not trusted and the first connection asks for the
     * fingerprint as usual.
     */
    @Synchronized
    fun addFromLink(link: AddHostLink, trustHostKey: Boolean): HostConfig {
        if (trustHostKey) {
            hostKeyConflict(state.value, link.host, link.port.toInt(), link.hostKey)?.let { throw HostException(it) }
        }
        return save(
            HostConfig(
                id = "",
                name = link.name.ifEmpty { link.host },
                host = link.host,
                port = link.port.toInt(),
                user = link.user,
                socketPath = link.socketPath.ifEmpty { defaultRemoteSocket(link.user) },
                pinnedHostKey = if (trustHostKey) link.hostKey else null,
            ),
        )
    }

    private fun newKey(hostId: String): String {
        val key = generateSshKey("amiscara-agents ${Build.MODEL}")
        vault.store(hostId, key.privateOpenssh)
        return key.publicOpenssh
    }

    private fun put(host: HostConfig) {
        val hosts = state.value
        write(if (hosts.any { it.id == host.id }) hosts.map { if (it.id == host.id) host else it } else hosts + host)
    }

    private fun write(hosts: List<HostConfig>) {
        if (demo) {
            state.value = hosts
            return
        }
        val out = file.startWrite()
        try {
            out.write(hostJson.encodeToString(hosts).toByteArray())
            file.finishWrite(out)
        } catch (e: Exception) {
            file.failWrite(out)
            throw e
        }
        state.value = hosts
    }

    private fun load(): List<HostConfig> = try {
        hostJson.decodeFromString(String(file.readFully()))
    } catch (_: FileNotFoundException) {
        emptyList()
    }
}
