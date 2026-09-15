package com.sansebas.nexus.mobile

import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sansebas.nexus.mobile/audio_recording")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForegroundRecording" -> {
                        ContextCompat.startForegroundService(this, Intent(this, AudioRecordingService::class.java))
                        result.success(null)
                    }
                    "stopForegroundRecording" -> {
                        stopService(Intent(this, AudioRecordingService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
