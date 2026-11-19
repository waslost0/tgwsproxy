// Purpose: Starts and stops ProxyService from UI, tile and boot receiver.
package com.example.tgwsproxy.service

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

object ProxyController {
    const val ACTION_START = "com.example.tgwsproxy.action.START"
    const val ACTION_STOP = "com.example.tgwsproxy.action.STOP"
    const val ACTION_RESTART = "com.example.tgwsproxy.action.RESTART"

    fun start(context: Context) {
        val intent = Intent(context, ProxyService::class.java).setAction(ACTION_START)
        ContextCompat.startForegroundService(context, intent)
    }

    fun stop(context: Context) {
        val intent = Intent(context, ProxyService::class.java).setAction(ACTION_STOP)
        context.startService(intent)
    }

    fun restart(context: Context) {
        val intent = Intent(context, ProxyService::class.java).setAction(ACTION_RESTART)
        context.startService(intent)
    }
}
