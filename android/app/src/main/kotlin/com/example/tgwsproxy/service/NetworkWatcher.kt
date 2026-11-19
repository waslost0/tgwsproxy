// Purpose: reports meaningful Android network switches to the proxy service.
package com.example.tgwsproxy.service

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.util.Log

/**
 * Wraps [ConnectivityManager.registerDefaultNetworkCallback].
 *
 * The default callback fires once for the current network, so the first
 * `onAvailable` is not a change. Only a replacement network or a restore after
 * `onLost` is reported; this prevents a restart immediately after service
 * creation.
 */
class NetworkWatcher(
    context: Context,
    private val onEvent: (Event) -> Unit,
) {
    enum class Event { Lost, Restored, Changed }

    private val manager =
        context.getSystemService(ConnectivityManager::class.java)
    private var current: Network? = null
    private var lost = false
    private var registered = false

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val wasLost = lost
            val changed = current != null && current != network
            current = network
            lost = false
            when {
                wasLost -> onEvent(Event.Restored)
                changed -> onEvent(Event.Changed)
            }
        }

        override fun onLost(network: Network) {
            if (network != current) return
            current = null
            lost = true
            onEvent(Event.Lost)
        }
    }

    fun start() {
        if (registered) return
        runCatching {
            manager.registerDefaultNetworkCallback(callback)
            registered = true
        }.onFailure {
            Log.w("NetworkWatcher", "network callback not registered", it)
        }
    }

    fun stop() {
        if (!registered) return
        runCatching { manager.unregisterNetworkCallback(callback) }
        registered = false
    }
}
