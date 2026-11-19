package com.example.tgwsproxy

import com.example.tgwsproxy.core.ProxyBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * UI host. The proxy itself lives in [com.example.tgwsproxy.service.ProxyService]
 * and in a separate headless Flutter engine, so destroying this Activity does
 * not stop the relay.
 */
class MainActivity : FlutterActivity() {
    private var bridge: ProxyBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = ProxyBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bridge?.dispose()
        bridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
