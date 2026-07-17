package com.airstaffs.soundtouch_control

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.airstaffs.soundtouch_control/wifi"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "disconnect" -> {
                    try {
                        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        @Suppress("DEPRECATION")
                        val ok = wifiManager.disconnect()
                        result.success(ok)
                    } catch (e: Exception) {
                        result.error("DISCONNECT_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
