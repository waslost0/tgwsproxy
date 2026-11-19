package com.example.tgwsproxy.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import com.example.tgwsproxy.MainActivity
import com.example.tgwsproxy.R
import com.example.tgwsproxy.data.ProxyLogRepository
import com.example.tgwsproxy.data.ProxyStateRepository
import com.example.tgwsproxy.data.SecretStore
import com.example.tgwsproxy.data.SettingsStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.net.InetSocketAddress
import java.net.ServerSocket

/**
 * Owns the Android side of the proxy lifecycle.
 *
 * The actual proxy runs in a headless FlutterEngine owned by [ProxyEngineHost].
 * This service keeps that engine alive independently of the UI, shows the
 * foreground notification and holds a wake lock while the proxy is running.
 */
class ProxyService : Service(), ProxyEngineHost.Listener {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val settingsStore by lazy { SettingsStore(this) }
    private val secretStore by lazy { SecretStore(this) }
    private var host: ProxyEngineHost? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var lastStats: String = ""
    private var runningHost = "127.0.0.1"
    private var runningPort = 1443
    private var restartJob: Job? = null
    private var probeJob: Job? = null
    private var lastStallRestart = 0L
    private val stallDetector = StallDetector()
    private val networkWatcher by lazy { NetworkWatcher(this, ::onNetworkEvent) }

    override fun onCreate() {
        super.onCreate()
        createChannel()
        acquireWakeLock()
        networkWatcher.start()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopProxy()
                stopSelf()
                return START_NOT_STICKY
            }

            ACTION_RESTART -> restartProxy()

            else -> startProxy()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        networkWatcher.stop()
        restartJob?.cancel()
        probeJob?.cancel()
        stopProxy()
        scope.cancel()
        releaseWakeLock()
        super.onDestroy()
    }

    private fun startProxy() {
        if (host?.isRunning == true) return
        restartJob?.cancel()
        restartJob = scope.launch { startProxyInternal() }
    }

    private suspend fun startProxyInternal() {
        startForegroundCompat(buildNotification("Запуск…", ""))
        ProxyStateRepository.setStarting(1443)
        try {
            var settings = settingsStore.current()
            if (!settings.autoPortPicked && !canBind(settings.host, settings.port)) {
                val free = findFreePort(settings.host, settings.port + 1)
                if (free != null) {
                    settingsStore.update(
                        mapOf("port" to free, "autoPortPicked" to true),
                    )
                    settings = settingsStore.current()
                    Log.i("ProxyService", "auto port: ${settings.port}")
                }
            }

            val secret = secretStore.getOrCreate()
            runningHost = settings.host
            runningPort = settings.port
            ProxyStateRepository.setStarting(settings.port)
            // Keep one host (and its FlutterEngineGroup) for the service
            // lifetime; recreating it per start makes the next Dart
            // isolate hang before `ready`.
            val currentHost = host ?: ProxyEngineHost(
                this@ProxyService,
                this@ProxyService,
            ).also { host = it }
            currentHost.start(settings.toEngineJson(secret))
        } catch (t: Throwable) {
            Log.e("ProxyService", "proxy start failed", t)
            ProxyStateRepository.setError(t.message ?: "ENGINE_START_FAILED")
            updateNotification("Ошибка запуска", t.message ?: "")
            host?.stop()
            host = null
        }
    }

    /** Stops the current engine before starting a new one; avoids start/stop races. */
    private fun restartProxy() {
        restartJob?.cancel()
        restartJob = scope.launch {
            host?.stop()
            startProxyInternal()
        }
    }

    private fun stopProxy() {
        restartJob?.cancel()
        val current = host
        ProxyStateRepository.setStopped()
        scope.launch {
            current?.stop()
            stopForegroundCompat()
        }
    }

    private fun onNetworkEvent(event: NetworkWatcher.Event) {
        if (host?.isRunning != true) return
        when (event) {
            NetworkWatcher.Event.Lost -> {
                updateNotification("Нет сети", "Ждём подключения…")
            }

            NetworkWatcher.Event.Restored -> scheduleRestart(3_000)
            NetworkWatcher.Event.Changed -> scheduleRestart(15_000)
        }
    }

    /** Gives Android time to settle the new default network before rebinding. */
    private fun scheduleRestart(delayMs: Long) {
        restartJob?.cancel()
        restartJob = scope.launch {
            delay(delayMs)
            if (isActive && host?.isRunning == true) {
                host?.stop()
                startProxyInternal()
            }
        }
    }

    private fun canBind(host: String, port: Int): Boolean = runCatching {
        ServerSocket().use { socket ->
            socket.reuseAddress = true
            socket.bind(InetSocketAddress(host, port))
        }
        true
    }.getOrDefault(false)

    private fun findFreePort(host: String, start: Int): Int? {
        for (port in start..start + 50) {
            if (port > 65535) break
            if (canBind(host, port)) return port
        }
        return null
    }

    private fun onStall() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastStallRestart < 10 * 60_000L) return
        lastStallRestart = now
        if (probeJob?.isActive == true) return
        probeJob = scope.launch {
            val result = host?.probeCf().orEmpty()
            val tls = result["tls"] == true
            val plain = result["plain"] == true
            if (!tls && plain && !settingsStore.current().noSecure) {
                settingsStore.update(mapOf("noSecure" to true))
                ProxyStateRepository.setError("CF TLS заблокирован — включён порт 80")
            }
            Log.i("ProxyService", "stall probe tls=$tls plain=$plain")
            restartProxy()
        }
    }

    override fun onStarted(port: Int, botApiPort: Int?, botApiError: String?) {
        runningPort = port
        ProxyStateRepository.setRunning(port, botApiPort, botApiError)
        updateNotification("Прокси работает", "$runningHost:$port")
    }

    override fun onStopped() {
        ProxyStateRepository.setStopped()
        updateNotification("Прокси остановлен", "")
    }

    override fun onStats(stats: Map<*, *>) {
        ProxyStateRepository.setStats(stats)
        val total = (stats["total"] as? Number)?.toLong() ?: 0L
        val active = (stats["active"] as? Number)?.toInt() ?: 0
        val up = (stats["bytesUp"] as? Number)?.toLong() ?: 0L
        val down = (stats["bytesDown"] as? Number)?.toLong() ?: 0L
        lastStats = "Активных: $active · ↑${formatBytes(up)} ↓${formatBytes(down)}"
        updateNotification("Прокси работает", lastStats)
        if (stallDetector.onStats(total, down)) onStall()
    }

    override fun onLog(record: Map<*, *>) = ProxyLogRepository.emit(record)

    override fun onError(code: String, message: String) {
        ProxyStateRepository.setError(message)
        updateNotification("Ошибка прокси", message)
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Прокси",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Локальный MTProto-прокси"
                setShowBadge(false)
            },
        )
    }

    private fun buildNotification(title: String, text: String): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, ProxyService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(openIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .addAction(0, "Остановить", stopIntent)
            .build()
    }

    private fun updateNotification(title: String, text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(title, text))
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun acquireWakeLock() {
        val power = getSystemService(PowerManager::class.java)
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "tgwsproxy:service").apply {
            setReferenceCounted(false)
            acquire(60 * 60 * 1000L)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
    }

    private fun formatBytes(value: Long): String {
        if (value < 1024) return "$value Б"
        val units = arrayOf("КБ", "МБ", "ГБ")
        var size = value.toDouble()
        var unit = -1
        while (size >= 1024 && unit < units.lastIndex) {
            size /= 1024
            unit++
        }
        return "%.1f %s".format(size, units[unit])
    }

    companion object {
        const val ACTION_START = "com.example.tgwsproxy.action.START"
        const val ACTION_STOP = "com.example.tgwsproxy.action.STOP"
        const val ACTION_RESTART = "com.example.tgwsproxy.action.RESTART"
        private const val CHANNEL_ID = "tg_ws_proxy_service"
        private const val NOTIFICATION_ID = 1443
    }
}
