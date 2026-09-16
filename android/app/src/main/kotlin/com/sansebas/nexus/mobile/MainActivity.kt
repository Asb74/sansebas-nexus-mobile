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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sansebas.nexus.mobile/audio_recovery")
            .setMethodCallHandler { call, result ->
                if (call.method != "splitM4a") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val input = call.argument<String>("inputPath")
                val output = call.argument<String>("outputDirectory")
                val baseName = call.argument<String>("baseName")
                val partCount = call.argument<Number>("partCount")?.toInt()
                if (input == null || output == null || baseName == null || partCount == null || partCount < 2) {
                    result.error("invalid_arguments", "Missing splitM4a arguments", null)
                    return@setMethodCallHandler
                }
                Thread {
                    try {
                        val paths = M4aSegmenter.split(input, output, baseName, partCount)
                        runOnUiThread { result.success(paths) }
                    } catch (error: Exception) {
                        runOnUiThread { result.error("m4a_resegmentation_failed", error.message, null) }
                    }
                }.start()
            }
    }
}
