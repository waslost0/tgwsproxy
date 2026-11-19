// Purpose: in-process bus for engine log records.
//
// The headless Flutter engine cannot write into the UI isolate, so the service
// forwards each Talker record here and ProxyBridge relays it to the attached
// Flutter logs screen.
package com.example.tgwsproxy.data

import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow

object ProxyLogRepository {
    private val _logs = MutableSharedFlow<Map<String, Any?>>(
        extraBufferCapacity = 256,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    val logs = _logs

    fun emit(record: Map<*, *>) {
        _logs.tryEmit(
            record.entries.associate { it.key.toString() to it.value },
        )
    }
}
