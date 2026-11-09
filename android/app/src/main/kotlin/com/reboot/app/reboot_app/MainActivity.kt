package com.reboot.app.reboot_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "reboot/settings")
            .setMethodCallHandler { call, result ->
                val preferences = getSharedPreferences("reboot_settings", MODE_PRIVATE)
                when (call.method) {
                    "loadSettings" -> result.success(
                        mapOf(
                            "profileName" to preferences.getString("profileName", "Александр Иванов"),
                            "notifications" to preferences.getBoolean("notifications", true),
                            "weeklySummary" to preferences.getBoolean("weeklySummary", true),
                            "goalHours" to preferences.getFloat("goalHours", 6.0f).toDouble(),
                            "themeId" to preferences.getString("themeId", "dark"),
                        ),
                    )
                    "saveSettings" -> {
                        val settings = call.arguments as? Map<*, *>
                        val notifications = settings?.get("notifications") as? Boolean
                        val profileName = (settings?.get("profileName") as? String)?.trim()
                        val weeklySummary = settings?.get("weeklySummary") as? Boolean
                        val goalHours = (settings?.get("goalHours") as? Number)?.toDouble()
                        val themeId = settings?.get("themeId") as? String
                        if (profileName.isNullOrEmpty() || profileName.length > 80 ||
                            notifications == null || weeklySummary == null ||
                            goalHours == null || !goalHours.isFinite() || goalHours !in 2.0..10.0 ||
                            themeId !in setOf("dark", "light", "violet", "midnightBlue", "emerald")
                        ) {
                            result.error("invalid_settings", "Invalid settings payload.", null)
                        } else {
                            val saved = preferences.edit()
                                .putString("profileName", profileName)
                                .putBoolean("notifications", notifications)
                                .putBoolean("weeklySummary", weeklySummary)
                                .putFloat("goalHours", goalHours.toFloat())
                                .putString("themeId", themeId)
                                .commit()
                            if (saved) result.success(null)
                            else result.error("storage_error", "Could not persist settings.", null)
                        }
                    }
                    "deleteSettings" -> {
                        val deleted = preferences.edit()
                            .remove("profileName")
                            .remove("notifications")
                            .remove("weeklySummary")
                            .remove("goalHours")
                            .remove("themeId")
                            .commit()
                        if (deleted) result.success(null)
                        else result.error("storage_error", "Could not delete settings.", null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
