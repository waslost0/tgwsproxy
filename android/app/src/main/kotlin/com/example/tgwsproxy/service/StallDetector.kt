// Purpose: detects successful handshakes that never receive downstream data.
package com.example.tgwsproxy.service

import android.os.SystemClock

/**
 * Telegram may connect, complete the proxy handshake and then receive nothing
 * when the Cloudflare route is blocked. [onStats] returns true at most once per
 * window after several such attempts, so the service can probe and restart.
 *
 * No traffic at all is not a stall: if users are idle, `total` does not grow and
 * the window simply expires.
 */
class StallDetector(
    private val windowMs: Long = 60_000,
    private val minAttempts: Int = 3,
    private val now: () -> Long = SystemClock::elapsedRealtime,
) {
    private var windowStart = now()
    private var startTotal = 0L
    private var startDown = 0L

    fun onStats(total: Long, bytesDown: Long): Boolean {
        val time = now()
        if (total < startTotal || bytesDown > startDown) {
            reset(total, bytesDown, time)
            return false
        }

        val windowExpired = time - windowStart >= windowMs
        if (windowExpired && total - startTotal >= minAttempts) {
            reset(total, bytesDown, time)
            return true
        }

        // Do not keep a stale window forever while the proxy is idle.
        if (time - windowStart >= windowMs * 2) {
            reset(total, bytesDown, time)
        }
        return false
    }

    private fun reset(total: Long, bytesDown: Long, time: Long) {
        windowStart = time
        startTotal = total
        startDown = bytesDown
    }
}
