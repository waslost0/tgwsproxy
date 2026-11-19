// Purpose: Method/EventChannel boundary between the Flutter UI and the
// Android service. It only controls the proxy; packet traffic never crosses it.
package com.example.tgwsproxy.core

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.example.tgwsproxy.data.ProxyLogRepository
import com.example.tgwsproxy.data.ProxySettings
import com.example.tgwsproxy.data.ProxyStateRepository
import com.example.tgwsproxy.data.SecretStore
import com.example.tgwsproxy.data.SettingsStore
import com.example.tgwsproxy.service.ProxyController
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch
import org.json.JSONObject

class ProxyBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val settingsStore = SettingsStore(context)
    private val secretStore = SecretStore(context)
    private val methods = MethodChannel(messenger, "com.example.tgwsproxy/proxy")
    private val events = EventChannel(messenger, "com.example.tgwsproxy/proxy_events")
    private var sink: EventChannel.EventSink? = null
    private var stateJob: Job? = null

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // DataStore reads are suspend, so every method that reads settings is
        // answered from a main-scoped coroutine.
        when (call.method) {
            "getBootstrap" -> scope.launch {
                result.success(bootstrap())
            }

            "start" -> {
                ProxyController.start(context)
                result.success(mapOf("ok" to true))
            }

            "stop" -> {
                ProxyController.stop(context)
                result.success(mapOf("ok" to true))
            }

            "restart" -> {
                ProxyController.restart(context)
                result.success(mapOf("ok" to true))
            }

            "getState" -> result.success(ProxyStateRepository.state.value.toMap())

            "getStats" -> result.success(ProxyStateRepository.state.value.toMap())

            "updateSettings" -> scope.launch {
                val args = (call.arguments as? Map<*, *>)?.entries
                    ?.associate { it.key.toString() to it.value }
                    ?: emptyMap()
                settingsStore.update(args)
                if (ProxyStateRepository.state.value.running) {
                    ProxyController.restart(context)
                }
                result.success(settingsStore.current().toUiMap())
            }

            "getSecret" -> result.success(secretStore.getOrCreate())

            "regenerateSecret" -> scope.launch {
                secretStore.regenerate()
                if (ProxyStateRepository.state.value.running) {
                    ProxyController.restart(context)
                }
                result.success(secretStore.getOrCreate())
            }

            "getProxyLink" -> scope.launch {
                val settings = settingsStore.current()
                result.success(buildLink(settings, secretStore.getOrCreate()))
            }

            "openInTelegram" -> scope.launch {
                val settings = settingsStore.current()
                openTelegram(buildLink(settings, secretStore.getOrCreate()))
                result.success(true)
            }

            "getLogs" -> result.success(emptyList<Map<String, Any>>())

            "clearLogs" -> result.success(true)

            "exportLogs" -> result.success("")

            "exportSettings" -> scope.launch {
                val settings = settingsStore.current()
                result.success(JSONObject(settings.toUiMap() as Map<*, *>).toString())
            }

            "importSettings" -> scope.launch {
                val raw = call.arguments as? String
                if (raw.isNullOrBlank()) {
                    result.error("INVALID_CONFIG", "empty settings", null)
                    return@launch
                }
                runCatching {
                    val json = JSONObject(raw)
                    val map = json.keys().asSequence().associateWith { json.get(it) }
                    settingsStore.update(map)
                }.onSuccess {
                    result.success(true)
                }.onFailure {
                    result.error("INVALID_CONFIG", it.message, null)
                }
            }

            "getDiagnostics" -> scope.launch {
                result.success(
                    mapOf(
                        "version" to appVersion(),
                        "android" to Build.VERSION.RELEASE,
                        "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
                        "abi" to Build.SUPPORTED_ABIS.joinToString(","),
                        "state" to ProxyStateRepository.state.value.toMap(),
                    ),
                )
            }

            "openBatterySettings" -> {
                openBatterySettings()
                result.success(true)
            }

            "installUpdate" -> result.success(false)

            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        stateJob?.cancel()
        // One stream carries both lifecycle and 2-second stats; Flutter routes
        // them by the "type" field.
        stateJob = scope.launch {
            merge(
                ProxyStateRepository.state.map { state ->
                    mapOf("type" to "state") + state.toMap()
                },
                ProxyLogRepository.logs.map { record ->
                    mapOf("type" to "log") + record
                },
            ).collect { event -> sink?.success(event) }
        }
    }

    override fun onCancel(arguments: Any?) {
        stateJob?.cancel()
        stateJob = null
        sink = null
    }

    fun dispose() {
        stateJob?.cancel()
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        scope.cancel()
    }

    private suspend fun bootstrap(): Map<String, Any?> {
        val settings = settingsStore.current()
        val secret = secretStore.getOrCreate()
        return mapOf(
            "engineVersion" to "0.1.0",
            "settings" to settings.toUiMap(),
            "state" to ProxyStateRepository.state.value.toMap(),
            "link" to buildLink(settings, secret),
            "secret" to secret,
        )
    }

    private fun buildLink(settings: ProxySettings, secret: String): String {
        val prefix = if (settings.fakeTlsDomain.isBlank()) {
            "dd$secret"
        } else {
            // FakeTLS links carry the masking domain as ASCII hex after the
            // 16-byte secret, matching the desktop core.
            "ee$secret" + settings.fakeTlsDomain.toByteArray().joinToString("") {
                "%02x".format(it)
            }
        }
        return "tg://proxy?server=${settings.host}&port=${settings.port}&secret=$prefix"
    }

    private fun openTelegram(link: String) {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(link)).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }

    private fun openBatterySettings() {
        val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }

    private fun appVersion(): String = runCatching {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName
    }.getOrNull() ?: "unknown"
}
