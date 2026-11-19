// Purpose: canonical proxy settings shared by the service, tile and Flutter UI.
package com.example.tgwsproxy.data

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import org.json.JSONArray
import org.json.JSONObject

private val Context.proxyDataStore by preferencesDataStore(name = "proxy_settings")

data class ProxySettings(
    val host: String = "127.0.0.1",
    val port: Int = 1443,
    val dcRedirects: Map<Int, String> = mapOf(
        2 to "149.154.167.220",
        4 to "149.154.167.220",
    ),
    val poolSize: Int = 4,
    val cfproxyEnabled: Boolean = true,
    val cfUserDomains: List<String> = emptyList(),
    val cfWorkerDomains: List<String> = emptyList(),
    val cfWorkerEnabled: Boolean = false,
    val fakeTlsDomain: String = "",
    val forceTestDc: Boolean = false,
    val noSecure: Boolean = false,
    val proxyProtocol: Boolean = false,
    val botApiEnabled: Boolean = true,
    val botApiPort: Int = 8081,
    val autoStart: Boolean = true,
    val checkUpdates: Boolean = true,
    val autoPortPicked: Boolean = false,
) {
    /**
     * Builds the single JSON document consumed by ProxyConfig.fromJson.
     * Keeping the secret out of DataStore means settings can be exported
     * without leaking the proxy credential.
     */
    fun toEngineJson(secret: String): String = JSONObject().apply {
        put("host", host)
        put("port", port)
        put("secret", secret)
        put("dcRedirects", JSONObject(dcRedirects.mapKeys { it.key.toString() }))
        put("poolSize", poolSize)
        put("cfproxy", cfproxyEnabled)
        put("cfproxyUserDomains", JSONArray(cfUserDomains))
        put("cfproxyWorkerDomains", JSONArray(cfWorkerDomains))
        put("cfWorkerEnabled", cfWorkerEnabled)
        put("fakeTlsDomain", fakeTlsDomain)
        put("forceTestDc", forceTestDc)
        put("disableSecure", noSecure)
        put("proxyProtocol", proxyProtocol)
        put("botApiEnabled", botApiEnabled)
        put("botApiPort", botApiPort)
    }.toString()

    /** Flat shape used by the Flutter settings screen and JSON export. */
    fun toUiMap(): Map<String, Any?> = mapOf(
        "host" to host,
        "port" to port,
        "dcRedirects" to dcRedirects.mapKeys { it.key.toString() },
        "poolSize" to poolSize,
        "cfproxyEnabled" to cfproxyEnabled,
        "cfUserDomains" to cfUserDomains,
        "cfWorkerDomains" to cfWorkerDomains,
        "cfWorkerEnabled" to cfWorkerEnabled,
        "fakeTlsDomain" to fakeTlsDomain,
        "forceTestDc" to forceTestDc,
        "noSecure" to noSecure,
        "proxyProtocol" to proxyProtocol,
        "botApiEnabled" to botApiEnabled,
        "botApiPort" to botApiPort,
        "autoStart" to autoStart,
        "checkUpdates" to checkUpdates,
        "autoPortPicked" to autoPortPicked,
    )
}

class SettingsStore(private val context: Context) {
    val flow: Flow<ProxySettings> = context.proxyDataStore.data.map { it.toSettings() }

    suspend fun current(): ProxySettings = flow.first()

    suspend fun save(settings: ProxySettings) {
        context.proxyDataStore.edit { it.write(settings) }
    }

    /** Applies a partial update from the Flutter MethodChannel. */
    suspend fun update(values: Map<String, Any?>) {
        context.proxyDataStore.edit { prefs ->
            values["host"]?.toString()?.takeIf(ProxyAddress::isValidHost)?.let {
                prefs[KEY_HOST] = it
            }
            values["port"]?.let {
                val port = asInt(it, prefs[KEY_PORT] ?: 1443)
                if (ProxyAddress.isValidPort(port)) prefs[KEY_PORT] = port
            }
            values["dcRedirects"]?.let { prefs[KEY_DC] = encodeDcMap(it) }
            values["poolSize"]?.let { prefs[KEY_POOL] = asInt(it, prefs[KEY_POOL] ?: 4) }
            values["cfproxyEnabled"]?.let { prefs[KEY_CF] = asBool(it, true) }
            values["cfUserDomains"]?.let { prefs[KEY_CF_USER] = asStringSet(it) }
            values["cfWorkerDomains"]?.let { prefs[KEY_CF_WORKER] = asStringSet(it) }
            values["cfWorkerEnabled"]?.let { prefs[KEY_CF_WORKER_ENABLED] = asBool(it, false) }
            values["fakeTlsDomain"]?.let { prefs[KEY_FAKE_TLS] = it.toString() }
            values["forceTestDc"]?.let { prefs[KEY_TEST_DC] = asBool(it, false) }
            values["noSecure"]?.let { prefs[KEY_NO_SECURE] = asBool(it, false) }
            values["proxyProtocol"]?.let { prefs[KEY_PROXY_PROTOCOL] = asBool(it, false) }
            values["botApiEnabled"]?.let { prefs[KEY_BOT_API] = asBool(it, true) }
            values["botApiPort"]?.let {
                prefs[KEY_BOT_PORT] = asInt(it, 8081).coerceIn(1, 65535)
            }
            values["autoStart"]?.let { prefs[KEY_AUTO_START] = asBool(it, true) }
            values["checkUpdates"]?.let { prefs[KEY_UPDATES] = asBool(it, true) }
            values["autoPortPicked"]?.let { prefs[KEY_AUTO_PORT] = asBool(it, false) }
        }
    }
}

private val KEY_HOST = stringPreferencesKey("host")
private val KEY_PORT = intPreferencesKey("port")
private val KEY_DC = stringPreferencesKey("dc_redirects")
private val KEY_POOL = intPreferencesKey("pool_size")
private val KEY_CF = booleanPreferencesKey("cfproxy_enabled")
private val KEY_CF_USER = stringSetPreferencesKey("cf_user_domains")
private val KEY_CF_WORKER = stringSetPreferencesKey("cf_worker_domains")
private val KEY_CF_WORKER_ENABLED = booleanPreferencesKey("cf_worker_enabled")
private val KEY_FAKE_TLS = stringPreferencesKey("fake_tls_domain")
private val KEY_TEST_DC = booleanPreferencesKey("force_test_dc")
private val KEY_NO_SECURE = booleanPreferencesKey("no_secure")
private val KEY_PROXY_PROTOCOL = booleanPreferencesKey("proxy_protocol")
private val KEY_BOT_API = booleanPreferencesKey("bot_api_enabled")
private val KEY_BOT_PORT = intPreferencesKey("bot_api_port")
private val KEY_AUTO_START = booleanPreferencesKey("auto_start")
private val KEY_UPDATES = booleanPreferencesKey("check_updates")
private val KEY_AUTO_PORT = booleanPreferencesKey("auto_port_picked")

private fun Preferences.toSettings(): ProxySettings = ProxySettings(
    host = this[KEY_HOST] ?: "127.0.0.1",
    port = this[KEY_PORT] ?: 1443,
    dcRedirects = decodeDcMap(this[KEY_DC]),
    poolSize = (this[KEY_POOL] ?: 4).coerceIn(1, 16),
    cfproxyEnabled = this[KEY_CF] ?: true,
    cfUserDomains = this[KEY_CF_USER]?.toList().orEmpty(),
    cfWorkerDomains = this[KEY_CF_WORKER]?.toList().orEmpty(),
    cfWorkerEnabled = this[KEY_CF_WORKER_ENABLED] ?: false,
    fakeTlsDomain = this[KEY_FAKE_TLS].orEmpty(),
    forceTestDc = this[KEY_TEST_DC] ?: false,
    noSecure = this[KEY_NO_SECURE] ?: false,
    proxyProtocol = this[KEY_PROXY_PROTOCOL] ?: false,
    botApiEnabled = this[KEY_BOT_API] ?: true,
    botApiPort = this[KEY_BOT_PORT] ?: 8081,
    autoStart = this[KEY_AUTO_START] ?: true,
    checkUpdates = this[KEY_UPDATES] ?: true,
    autoPortPicked = this[KEY_AUTO_PORT] ?: false,
)

private fun androidx.datastore.preferences.core.MutablePreferences.write(settings: ProxySettings) {
    this[KEY_HOST] = settings.host
    this[KEY_PORT] = settings.port
    this[KEY_DC] = encodeDcMap(settings.dcRedirects)
    this[KEY_POOL] = settings.poolSize
    this[KEY_CF] = settings.cfproxyEnabled
    this[KEY_CF_USER] = settings.cfUserDomains.toSet()
    this[KEY_CF_WORKER] = settings.cfWorkerDomains.toSet()
    this[KEY_CF_WORKER_ENABLED] = settings.cfWorkerEnabled
    this[KEY_FAKE_TLS] = settings.fakeTlsDomain
    this[KEY_TEST_DC] = settings.forceTestDc
    this[KEY_NO_SECURE] = settings.noSecure
    this[KEY_PROXY_PROTOCOL] = settings.proxyProtocol
    this[KEY_BOT_API] = settings.botApiEnabled
    this[KEY_BOT_PORT] = settings.botApiPort
    this[KEY_AUTO_START] = settings.autoStart
    this[KEY_UPDATES] = settings.checkUpdates
    this[KEY_AUTO_PORT] = settings.autoPortPicked
}

private fun encodeDcMap(value: Any?): String {
    val map = when (value) {
        is Map<*, *> -> value.entries.associate { it.key.toString() to it.value.toString() }
        is JSONObject -> value.keys().asSequence().associateWith { value.getString(it) }
        else -> return "2:149.154.167.220,4:149.154.167.220"
    }
    return map.entries.joinToString(",") { "${it.key}:${it.value}" }
}

private fun decodeDcMap(value: String?): Map<Int, String> {
    if (value.isNullOrBlank()) {
        return mapOf(2 to "149.154.167.220", 4 to "149.154.167.220")
    }
    return value.split(',').mapNotNull { part ->
        val idx = part.indexOf(':')
        if (idx <= 0) return@mapNotNull null
        val dc = part.substring(0, idx).trim().toIntOrNull() ?: return@mapNotNull null
        dc to part.substring(idx + 1).trim()
    }.toMap().ifEmpty { mapOf(2 to "149.154.167.220", 4 to "149.154.167.220") }
}

private fun asInt(value: Any?, fallback: Int): Int =
    when (value) {
        is Number -> value.toInt()
        else -> value.toString().toIntOrNull() ?: fallback
    }

private fun asBool(value: Any?, fallback: Boolean): Boolean =
    when (value) {
        is Boolean -> value
        else -> value.toString().toBooleanStrictOrNull() ?: fallback
    }

private fun asStringSet(value: Any?): Set<String> = when (value) {
    is List<*> -> value.mapNotNull { it?.toString()?.trim()?.takeIf(String::isNotEmpty) }.toSet()
    is JSONArray -> (0 until value.length()).mapNotNull {
        value.optString(it).trim().takeIf(String::isNotEmpty)
    }.toSet()
    else -> value.toString().split(',', ';', ' ')
        .map(String::trim)
        .filter(String::isNotEmpty)
        .toSet()
}
