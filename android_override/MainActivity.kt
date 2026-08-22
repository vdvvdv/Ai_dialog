package com.example.ai_dialog

import android.content.Context
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ai_dialog/net")
            .setMethodCallHandler { call, result ->
                if (call.method == "cellInfo") {
                    try {
                        val tm = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
                        val op = tm.networkOperatorName ?: ""
                        val mccmnc = tm.networkOperator ?: ""
                        val iso = tm.networkCountryIso ?: ""
                        val t = tm.dataNetworkType
                        val netType = when (t) {
                            TelephonyManager.NETWORK_TYPE_NR -> "5G"
                            TelephonyManager.NETWORK_TYPE_LTE -> "LTE"
                            TelephonyManager.NETWORK_TYPE_HSPAP,
                            TelephonyManager.NETWORK_TYPE_HSPA,
                            TelephonyManager.NETWORK_TYPE_HSDPA,
                            TelephonyManager.NETWORK_TYPE_HSUPA -> "HSPA"
                            TelephonyManager.NETWORK_TYPE_UMTS -> "3G"
                            TelephonyManager.NETWORK_TYPE_EDGE,
                            TelephonyManager.NETWORK_TYPE_GPRS -> "2G"
                            else -> "type$t"
                        }
                        result.success("$op|$mccmnc|$iso|$netType")
                    } catch (e: Exception) {
                        result.success("n/a")
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}
