package com.example.tgwsproxy.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * Snapshot of the proxy state shared by the service, the UI bridge and the
 * quick-settings tile. It intentionally contains only plain values so it can
 * be copied into a MethodChannel map without touching the Flutter engine.
 */
data class ProxySnapshot(
    val running: Boolean = false,
    val starting: Boolean = false,
    val port: Int = 1443,
    val botApiPort: Int? = null,
    val botApiError: String? = null,
    val activeConnections: Int = 0,
    val totalConnections: Int = 0,
    val bytesUp: Long = 0,
    val bytesDown: Long = 0,
    val ws: Int = 0,
    val cf: Int = 0,
    val tcpFallback: Int = 0,
    val error: String? = null,
    val coreVersion: String = "0.1.0",
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "running" to running,
        "starting" to starting,
        "port" to port,
        "botApiPort" to botApiPort,
        "botApiError" to botApiError,
        "active" to activeConnections,
        "total" to totalConnections,
        "bytesUp" to bytesUp,
        "bytesDown" to bytesDown,
        "ws" to ws,
        "cf" to cf,
        "tcpFallback" to tcpFallback,
        "error" to error,
        "coreVersion" to coreVersion,
    )
}

object ProxyStateRepository {
    private val _state = MutableStateFlow(ProxySnapshot())
    val state: StateFlow<ProxySnapshot> = _state.asStateFlow()

    fun update(transform: (ProxySnapshot) -> ProxySnapshot) {
        _state.update(transform)
    }

    fun setStarting(port: Int) {
        _state.update {
            it.copy(starting = true, running = false, port = port, error = null)
        }
    }

    fun setRunning(port: Int, botApiPort: Int?, botApiError: String?) {
        _state.update {
            it.copy(
                running = true,
                starting = false,
                port = port,
                botApiPort = botApiPort,
                botApiError = botApiError,
                error = null,
            )
        }
    }

    fun setStopped() {
        _state.update {
            ProxySnapshot(
                port = it.port,
                coreVersion = it.coreVersion,
            )
        }
    }

    fun setError(message: String) {
        _state.update {
            it.copy(running = false, starting = false, error = message)
        }
    }

    fun setStats(map: Map<*, *>) {
        fun int(key: String) = (map[key] as? Number)?.toInt() ?: 0
        fun long(key: String) = (map[key] as? Number)?.toLong() ?: 0L
        _state.update {
            it.copy(
                activeConnections = int("active"),
                totalConnections = int("total"),
                bytesUp = long("bytesUp"),
                bytesDown = long("bytesDown"),
                ws = int("ws"),
                cf = int("cf"),
                tcpFallback = int("tcpFallback"),
            )
        }
    }
}
