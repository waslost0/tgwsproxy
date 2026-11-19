// Purpose: Restore the proxy after reboot when the user enabled autostart.
package com.example.tgwsproxy.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.example.tgwsproxy.data.SettingsStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }

        // BroadcastReceiver must not block the main thread on DataStore.
        val pending = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                if (SettingsStore(context.applicationContext).current().autoStart) {
                    ProxyController.start(context.applicationContext)
                }
            } finally {
                pending.finish()
            }
        }
    }
}
