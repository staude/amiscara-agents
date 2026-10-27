package net.staude.amiscara.agents.model

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import net.staude.amiscara.agents.core.BoardItem
import net.staude.amiscara.agents.core.FfiException
import net.staude.amiscara.agents.core.HostSession
import net.staude.amiscara.agents.core.HostStatus
import net.staude.amiscara.agents.core.OpenRequest
import net.staude.amiscara.agents.core.SessionObserver
import net.staude.amiscara.agents.core.SessionUpdate
import net.staude.amiscara.agents.R

/**
 * One live [HostSession] per host, kept in step with the [HostRepository]:
 * a new or changed host (address, key, trusted host key) starts its session
 * again, a removed one stops. Runs on the main thread; the core reports on
 * background threads into [updates], and agents that started waiting or
 * finished into [attention] (on that thread).
 */
class Connections(
    private val hosts: HostRepository,
    private val scope: CoroutineScope,
    private val attention: (hostId: String, items: List<BoardItem>) -> Unit = { _, _ -> },
) {
    private class Running(val config: HostConfig, val session: HostSession)

    private val running = mutableMapOf<String, Running>()
    /** Updates of a stopped session arrive late; only the current one counts. */
    private val generations = ConcurrentHashMap<String, Long>()
    private val nextGeneration = AtomicLong()

    private val updateState = MutableStateFlow<Map<String, SessionUpdate>>(emptyMap())
    private val startErrorState = MutableStateFlow<Map<String, String>>(emptyMap())

    /** The latest state per host id. */
    val updates: StateFlow<Map<String, SessionUpdate>> = updateState.asStateFlow()

    /** Why a host's session could not even start, per host id. */
    val startErrors: StateFlow<Map<String, String>> = startErrorState.asStateFlow()

    /** Open requests hidden on this device with "Ignorieren", by [PendingOpen.key]. */
    private val ignoredState = MutableStateFlow<Set<String>>(emptySet())

    /**
     * Pages agents on the hosts want opened (#247), in host order, without
     * those ignored here. A request leaves once any device opened it or its
     * time ran out.
     */
    val openRequests: StateFlow<List<PendingOpen>> =
        combine(hosts.hosts, updateState, ignoredState) { list, updates, ignored ->
            list.flatMap { host ->
                updates[host.id]?.openRequests.orEmpty().map { PendingOpen(host.id, host.name, it) }
            }.filter { it.key !in ignored }
        }.stateIn(scope, SharingStarted.Eagerly, emptyList())

    /** Hides a request on this device only. */
    fun ignore(request: PendingOpen) {
        ignoredState.update { it + request.key }
    }

    /**
     * The address to open for [request]: a page on the host's localhost is
     * forwarded to a port on this device, other URLs come back unchanged.
     * A failure carries a message for the user ([HostException]).
     */
    suspend fun openAddress(request: PendingOpen): Result<String> {
        val session = running[request.hostId]?.session
            ?: return Result.failure(HostException(Texts.get(R.string.no_connection)))
        return withContext(Dispatchers.IO) {
            try {
                Result.success(session.openUrl(request.request.url))
            } catch (e: FfiException) {
                Result.failure(HostException(inputErrorMessage(e)))
            } catch (e: IllegalStateException) {
                Result.failure(HostException(Texts.get(R.string.no_connection)))
            }
        }
    }

    /**
     * Takes [request] back on the host, so other devices drop it too; best
     * effort. It writes to herdr, so not on a read-only host.
     */
    fun dismiss(request: PendingOpen) {
        ignore(request)
        if (hosts.get(request.hostId)?.allowInput == false) return
        val session = running[request.hostId]?.session ?: return
        scope.launch(Dispatchers.IO) {
            runCatching { session.dismissOpenRequest(request.request.paneId, request.request.requestId) }
        }
    }

    init {
        scope.launch { hosts.hosts.collect(::sync) }
    }

    /** Starts the host's session again right away, e.g. "Jetzt verbinden". */
    fun reconnect(id: String) {
        hosts.get(id)?.let(::start)
    }

    /** The live session of a host, for following panes; `null` while stopped. */
    fun session(id: String): HostSession? = running[id]?.session

    /**
     * Runs one input action (prompt, keys, upload) off the main thread.
     * A failure carries a German message for the user ([HostException]).
     * Call from the main thread.
     */
    suspend fun <T> input(hostId: String, action: (HostSession) -> T): Result<T> {
        if (hosts.get(hostId)?.allowInput == false) {
            return Result.failure(HostException(Texts.get(R.string.input_off)))
        }
        val session = running[hostId]?.session
            ?: return Result.failure(HostException(Texts.get(R.string.no_connection)))
        return withContext(Dispatchers.IO) {
            try {
                Result.success(action(session))
            } catch (e: FfiException) {
                Result.failure(HostException(inputErrorMessage(e)))
            } catch (e: IllegalStateException) {
                // The session was stopped meanwhile (host changed or removed).
                Result.failure(HostException(Texts.get(R.string.no_connection)))
            }
        }
    }

    /**
     * Sends keys from outside the app's screens, e.g. a notification's
     * answer button: waits for the host to be live first. `fresh` starts a
     * new connection before, for when the old one may have died unnoticed
     * while the app was frozen in the background. Not repeated on failure:
     * the key may have arrived.
     */
    suspend fun sendWhenLive(hostId: String, paneId: String, keys: List<String>, fresh: Boolean): Result<Unit> {
        val status = updates.value[hostId]?.status
        if (fresh || status is HostStatus.Retrying || status is HostStatus.Failed) reconnect(hostId)
        withTimeoutOrNull(LIVE_TIMEOUT_MS) { updates.first { it[hostId]?.status is HostStatus.Live } }
            ?: return Result.failure(HostException(Texts.get(R.string.no_connection)))
        return input(hostId) { it.sendKeys(paneId, keys) }
    }

    /** Starts every session again, e.g. once the local network is allowed. */
    fun reconnectAll() {
        running.values.map { it.config }.forEach(::start)
    }

    /**
     * Back in the foreground: sessions that wait for their next attempt or
     * were refused try again now (the key may have been added meanwhile).
     * Waiting sessions keep their state, so changes meanwhile notify (#264).
     */
    fun reconnectStale() {
        for ((id, entry) in running.toMap()) {
            when (updates.value[id]?.status) {
                is HostStatus.Retrying -> reconnectKeeping(id, entry)
                is HostStatus.Failed -> start(entry.config)
                else -> {}
            }
        }
    }

    /**
     * Back after a long pause: every session connects again, live or not.
     * The SSH link may have died meanwhile while the session still counts
     * as live until the keepalives give up a minute later (#258). Sessions
     * keep their state and panes follow the new connection, so agents that
     * finished meanwhile still notify (#264).
     */
    fun reconnectRemote() {
        for ((id, entry) in running.toMap()) {
            when (updates.value[id]?.status) {
                is HostStatus.HostKeyUnknown, is HostStatus.HostKeyChanged -> {}
                else -> reconnectKeeping(id, entry)
            }
        }
    }

    /** Connects again at once with the known state; a refused session starts over. */
    private fun reconnectKeeping(id: String, entry: Running) {
        if (updates.value[id]?.status is HostStatus.Failed) start(entry.config) else entry.session.reconnect()
    }

    private fun sync(list: List<HostConfig>) {
        val ids = list.map { it.id }.toSet()
        running.keys.filter { it !in ids }.forEach(::stop)
        for (host in list) {
            val entry = running[host.id]
            if (entry == null || host.connectsDifferentlyThan(entry.config)) {
                start(host)
            } else {
                if (host.spaceSort != entry.config.spaceSort || host.spaceOrder != entry.config.spaceOrder) {
                    entry.session.setSpaceSort(host.spaceSorting)
                }
                running[host.id] = Running(host, entry.session)
            }
        }
    }

    private fun start(host: HostConfig) {
        stop(host.id)
        val generation = nextGeneration.incrementAndGet()
        generations[host.id] = generation
        val observer = object : SessionObserver {
            override fun onUpdate(update: SessionUpdate) {
                if (generations[host.id] != generation) return
                updateState.update { it + (host.id to update) }
                if (update.attention.isNotEmpty()) attention(host.id, update.attention)
            }
        }
        try {
            val key = hosts.privateKey(host.id) ?: throw HostException(Texts.get(R.string.error_key_missing))
            running[host.id] = Running(host, HostSession.start(host.endpoint(key), observer, host.groupSpacesByName, host.spaceSorting))
            startErrorState.update { it - host.id }
        } catch (e: FfiException) {
            startErrorState.update { it + (host.id to (e.message ?: e.toString())) }
        } catch (e: HostException) {
            startErrorState.update { it + (host.id to (e.message ?: e.toString())) }
        }
    }

    private fun stop(id: String) {
        generations.remove(id)
        running.remove(id)?.session?.let {
            it.stop()
            it.close()
        }
        updateState.update { it - id }
    }

    private companion object {
        /** How long [sendWhenLive] waits for the connection. */
        const val LIVE_TIMEOUT_MS = 15_000L
    }
}

/** Text for a failed input, as `inputErrorMessage` in the Apple apps. */
fun inputErrorMessage(error: FfiException): String = when (error) {
    is FfiException.AgentBlocked -> Texts.get(R.string.error_agent_blocked)
    is FfiException.NotConnected -> Texts.get(R.string.no_connection)
    is FfiException.Upload -> Texts.get(R.string.error_upload, error.message.orEmpty())
    is FfiException.Files -> Texts.get(R.string.error_files, error.message.orEmpty())
    is FfiException.AgentWorking -> Texts.get(R.string.error_agent_working)
    is FfiException.Forward -> Texts.get(R.string.error_forward)
    else -> error.message ?: error.toString()
}

/** A page an agent on a host wants opened, with its host. */
data class PendingOpen(val hostId: String, val hostName: String, val request: OpenRequest) {
    /** Unique over hosts and panes; a new request of the pane gets a new one. */
    val key: String get() = "$hostId|${request.paneId}|${request.requestId}"
}
