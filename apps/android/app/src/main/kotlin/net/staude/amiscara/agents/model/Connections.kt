package net.staude.amiscara.agents.model

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import net.staude.amiscara.agents.core.FfiException
import net.staude.amiscara.agents.core.HostSession
import net.staude.amiscara.agents.core.HostStatus
import net.staude.amiscara.agents.core.SessionObserver
import net.staude.amiscara.agents.core.SessionUpdate

/**
 * One live [HostSession] per host, kept in step with the [HostRepository]:
 * a new or changed host (address, key, trusted host key) starts its session
 * again, a removed one stops. Runs on the main thread; the core reports on
 * background threads into [updates].
 */
class Connections(private val hosts: HostRepository, scope: CoroutineScope) {
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
            return Result.failure(HostException("Eingaben sind für diesen Host ausgeschaltet."))
        }
        val session = running[hostId]?.session
            ?: return Result.failure(HostException("Keine Verbindung zum Host."))
        return withContext(Dispatchers.IO) {
            try {
                Result.success(action(session))
            } catch (e: FfiException) {
                Result.failure(HostException(inputErrorMessage(e)))
            } catch (e: IllegalStateException) {
                // The session was stopped meanwhile (host changed or removed).
                Result.failure(HostException("Keine Verbindung zum Host."))
            }
        }
    }

    /** Starts every session again, e.g. once the local network is allowed. */
    fun reconnectAll() {
        running.values.map { it.config }.forEach(::start)
    }

    /**
     * Back in the foreground: sessions that wait for their next attempt or
     * were refused try again now (the key may have been added meanwhile).
     */
    fun reconnectStale() {
        for ((id, entry) in running.toMap()) {
            when (updates.value[id]?.status) {
                is HostStatus.Retrying, is HostStatus.Failed -> start(entry.config)
                else -> {}
            }
        }
    }

    private fun sync(list: List<HostConfig>) {
        val ids = list.map { it.id }.toSet()
        running.keys.filter { it !in ids }.forEach(::stop)
        for (host in list) {
            val entry = running[host.id]
            if (entry == null || host.connectsDifferentlyThan(entry.config)) {
                start(host)
            } else {
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
                if (generations[host.id] == generation) updateState.update { it + (host.id to update) }
            }
        }
        try {
            val key = hosts.privateKey(host.id) ?: throw HostException("Für diesen Host fehlt der Schlüssel. Erzeugen Sie einen neuen.")
            running[host.id] = Running(host, HostSession.start(host.endpoint(key), observer, host.groupSpacesByName))
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
}

/** German text for a failed input, as `inputErrorMessage` in the Apple apps. */
fun inputErrorMessage(error: FfiException): String = when (error) {
    is FfiException.AgentBlocked -> "Der Agent wartet auf eine Antwort. Bitte zuerst beantworten."
    is FfiException.NotConnected -> "Keine Verbindung zum Host."
    is FfiException.Upload -> "Hochladen fehlgeschlagen: ${error.message}"
    is FfiException.Files -> "Dateien auf dem Host nicht lesbar: ${error.message}"
    else -> error.message ?: error.toString()
}
