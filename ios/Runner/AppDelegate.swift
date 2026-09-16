import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    FlutterMethodChannel(
      name: "com.sansebas.nexus.mobile/audio_recovery",
      binaryMessenger: controller.binaryMessenger
    ).setMethodCallHandler { call, result in
      guard call.method == "splitM4a",
            let arguments = call.arguments as? [String: Any],
            let input = arguments["inputPath"] as? String,
            let output = arguments["outputDirectory"] as? String,
            let baseName = arguments["baseName"] as? String,
            let partCount = arguments["partCount"] as? NSNumber else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.splitM4a(input: input, outputDirectory: output, baseName: baseName,
                    requestedPartCount: partCount.intValue, result: result)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// AVAssetExportSession remuxes timed media samples into standalone M4A
  /// containers. The original URL is read-only and is never replaced.
  private func splitM4a(input: String, outputDirectory: String, baseName: String,
                        requestedPartCount: Int, result: @escaping FlutterResult) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: input))
    let totalSeconds = CMTimeGetSeconds(asset.duration)
    guard totalSeconds.isFinite, totalSeconds > 0, requestedPartCount >= 2 else {
      result(FlutterError(code: "invalid_m4a", message: "Audio duration is unavailable", details: nil))
      return
    }
    let partCount = requestedPartCount
    let partDurationSeconds = totalSeconds / Double(partCount)
    var paths: [String] = []
    func exportPart(_ index: Int) {
      if index == partCount { result(paths); return }
      let start = Double(index) * partDurationSeconds
      let duration = min(partDurationSeconds, totalSeconds - start)
      let path = URL(fileURLWithPath: outputDirectory)
        .appendingPathComponent(String(format: "%@_%03d.m4a", baseName, index))
      try? FileManager.default.removeItem(at: path)
      guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
        result(FlutterError(code: "export_unavailable", message: "Cannot create M4A exporter", details: nil))
        return
      }
      exporter.outputURL = path
      exporter.outputFileType = .m4a
      exporter.timeRange = CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: 600),
        duration: CMTime(seconds: duration, preferredTimescale: 600)
      )
      exporter.exportAsynchronously {
        DispatchQueue.main.async {
          if exporter.status == .completed {
            paths.append(path.path)
            exportPart(index + 1)
          } else {
            result(FlutterError(code: "m4a_resegmentation_failed",
              message: exporter.error?.localizedDescription ?? "M4A export failed", details: nil))
          }
        }
      }
    }
    exportPart(0)
  }
}
