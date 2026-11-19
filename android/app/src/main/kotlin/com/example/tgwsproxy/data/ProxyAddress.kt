package com.example.tgwsproxy.data

/// Addresses accepted for the local listener. Keep this in sync with the
/// Flutter address dialog; imports must not be able to bind a random port.
object ProxyAddress {
    fun isValidHost(value: String): Boolean {
        val host = value.trim()
        if (host == "localhost" || host == "0.0.0.0") return true
        val parts = host.split('.')
        if (parts.size != 4) return false
        return parts.all { part ->
            part.isNotEmpty() && part.all(Char::isDigit) && part.toIntOrNull() in 0..255
        }
    }

    fun isValidPort(value: Int): Boolean = value in 1..65535
}
