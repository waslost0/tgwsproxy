// Purpose: Quick Settings tile that mirrors the service state and toggles it.
package com.example.tgwsproxy.service

import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.example.tgwsproxy.data.ProxyStateRepository

class ProxyTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        val state = ProxyStateRepository.state.value
        if (state.running || state.starting) {
            ProxyController.stop(this)
        } else {
            ProxyController.start(this)
        }
        updateTile()
    }

    private fun updateTile() {
        val state = ProxyStateRepository.state.value
        qsTile?.apply {
            // Tile state is optimistic: the service will correct it on the next
            // onStartListening after a start/stop broadcast.
            this.state = if (state.running || state.starting) {
                Tile.STATE_ACTIVE
            } else {
                Tile.STATE_INACTIVE
            }
            label = "TG WS Proxy"
            updateTile()
        }
    }
}
