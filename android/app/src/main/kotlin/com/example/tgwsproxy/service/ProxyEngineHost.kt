package com.example.tgwsproxy.service

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Owns the headless FlutterEngine that runs the Dart proxy.
 *
 * The Android service is the lifecycle owner; this class only starts/stops the
 * engine and speaks the small JSON control protocol on [CHANNEL]. Proxy traffic
 * never crosses this channel: it stays on Dart sockets.
 */
class ProxyEngineHost(
    private val context: Context,
    private val listener: Listener,
) {
    interface Listener {
        fun onStarted(port: Int, botApiPort: Int?, botApiError: String?)
        fun onStopped()
        fun onStats(stats: Map<*, *>)
        fun onLog(record: Map<*, *>)
        fun onError(code: String, message: String)
    }

    companion object {
        private const val TAG = "ProxyEngineHost"
        private const val CHANNEL = "com.example.tgwsproxy/engine"
        private const val READY_TIMEOUT_MS = 30_000L
        private const val START_TIMEOUT_MS = 20_000L
        private const val STOP_TIMEOUT_MS = 5_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    // Reuse one group: a new group per start leaks shared engine resources and
    // makes subsequent Dart isolates hang before sending `ready`.
    private val engineGroup by lazy { FlutterEngineGroup(context) }
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var running = false

    val isRunning: Boolean
        get() = running

    /**
     * Starts the engine and waits for its `ready` event before sending config.
     *
     * The channel can only be used after the Dart handler is installed, hence
     * the explicit ready handshake instead of firing `start` immediately.
     */
    suspend fun start(configJson: String): Map<*, *> = withContext(Dispatchers.Main) {
        check(engine == null) { "Proxy engine is already started" }

        val ready = CompletableDeferred<Unit>()
        val entrypoint = DartEntrypoint("package:tgwsproxy/main.dart", "proxyMain")
        val options = FlutterEngineGroup.Options(context).apply {
            setDartEntrypoint(entrypoint)
            // The service engine must not initialize plugins: it has no
            // Activity and only needs dart:io plus this MethodChannel.
            setAutomaticallyRegisterPlugins(false)
        }

        val newEngine = engineGroup.createAndRunEngine(options)
        Log.d(TAG, "engine created")
        val newChannel = MethodChannel(newEngine.dartExecutor.binaryMessenger, CHANNEL)
        newChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    Log.d(TAG, "engine ready")
                    ready.complete(Unit)
                }
                "started" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    listener.onStarted(
                        (args["port"] as? Number)?.toInt() ?: 0,
                        (args["botApiPort"] as? Number)?.toInt(),
                        args["botApiError"] as? String,
                    )
                }
                "stopped" -> {
                    running = false
                    listener.onStopped()
                }
                "stats" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    listener.onStats(args)
                }
                "log" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    listener.onLog(args)
                }
                "error" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    listener.onError(
                        args["code"] as? String ?: "ENGINE_ERROR",
                        args["message"] as? String ?: "Dart engine error",
                    )
                }
            }
            // Dart waits for a reply even for fire-and-forget events; without
            // this, the start call would hang until the Kotlin timeout.
            result.success(null)
        }

        engine = newEngine
        channel = newChannel

        try {
            Log.d(TAG, "waiting for ready")
            withTimeout(READY_TIMEOUT_MS) { ready.await() }
            Log.d(TAG, "sending start")
            val result = withTimeout(START_TIMEOUT_MS) {
                invoke(newChannel, "start", mapOf("config" to configJson))
            } as? Map<*, *> ?: emptyMap<Any, Any>()
            running = true
            Log.d(TAG, "engine started: $result")
            result
        } catch (error: Throwable) {
            Log.e(TAG, "engine start failed", error)
            // A failed handshake must not leave a half-created engine behind.
            running = false
            newChannel.setMethodCallHandler(null)
            newEngine.destroy()
            engine = null
            channel = null
            throw error
        }
    }

    suspend fun stop() = withContext(Dispatchers.Main) {
        val current = channel
        if (current != null && running) {
            try {
                withTimeout(STOP_TIMEOUT_MS) { invoke(current, "stop") }
            } catch (_: Throwable) {
                // The service is going away regardless; destroy below.
            }
        }
        running = false
        channel?.setMethodCallHandler(null)
        channel = null
        engine?.destroy()
        engine = null
    }

    suspend fun getStats(): Map<*, *> = withContext(Dispatchers.Main) {
        val current = channel ?: return@withContext emptyMap<Any, Any>()
        invoke(current, "getStats") as? Map<*, *> ?: emptyMap<Any, Any>()
    }

    /**
     * Asks the Dart engine to check Cloudflare over TLS and plain HTTP.
     * The probe uses the same user CF domains and DC IP as the live router.
     */
    suspend fun probeCf(): Map<*, *> = withContext(Dispatchers.Main) {
        val current = channel ?: return@withContext emptyMap<Any, Any>()
        invoke(current, "probeCf") as? Map<*, *> ?: emptyMap<Any, Any>()
    }

    suspend fun ping(): Boolean = withContext(Dispatchers.Main) {
        val current = channel ?: return@withContext false
        invoke(current, "ping") == true
    }

    private suspend fun invoke(
        target: MethodChannel,
        method: String,
        arguments: Any? = null,
    ): Any? = suspendCancellableCoroutine { continuation ->
        target.invokeMethod(method, arguments, object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (continuation.isActive) continuation.resume(result)
            }

            override fun error(code: String, message: String?, details: Any?) {
                if (continuation.isActive) {
                    continuation.resumeWithException(
                        IllegalStateException("$code: ${message ?: "engine error"}"),
                    )
                }
            }

            override fun notImplemented() {
                if (continuation.isActive) {
                    continuation.resumeWithException(
                        UnsupportedOperationException("Engine method not implemented: $method"),
                    )
                }
            }
        })
    }

    /** Runs [block] on the main thread; used by the notification ticker. */
    fun post(block: () -> Unit) {
        mainHandler.post(block)
    }
}
