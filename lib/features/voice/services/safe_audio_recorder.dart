import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../models/recording_session.dart';
import 'audio_limits.dart';
import 'recording_session_store.dart';

String formatAudioDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0
      ? '${hours.toString().padLeft(2, '0')}:$minutes:$seconds'
      : '$minutes:$seconds';
}

class AudioSegmentationPolicy {
  const AudioSegmentationPolicy({
    this.segmentDuration = const Duration(seconds: 1245),
    this.bitsPerSecond = 128000,
    this.safeBytes = recordingSegmentTargetBytes,
  });

  final Duration segmentDuration;
  final int bitsPerSecond;
  final int safeBytes;

  int get estimatedSegmentBytes => (segmentDuration.inSeconds * bitsPerSecond / 8).ceil();
  bool get isWithinSafeThreshold => estimatedSegmentBytes <= safeBytes;
  int segmentCount(Duration total) {
    final count = (total.inSeconds / segmentDuration.inSeconds).ceil();
    return count < 1 ? 1 : count;
  }
}

abstract interface class AudioRecorderAdapter {
  Future<bool> hasPermission();
  Future<void> start(String path);
  Future<String?> stop();
  Future<bool> isRecording();
}

class RecordAudioRecorderAdapter implements AudioRecorderAdapter {
  RecordAudioRecorderAdapter(this.recorder);

  final AudioRecorder recorder;

  @override
  Future<bool> hasPermission() => recorder.hasPermission();

  @override
  Future<bool> isRecording() => recorder.isRecording();

  @override
  Future<void> start(String path) => recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: _audioBitRate,
          sampleRate: _audioSampleRate,
        ),
        path: path,
      );

  @override
  Future<String?> stop() => recorder.stop();
}

class AndroidRecordingForegroundService {
  static const _channel = MethodChannel('com.sansebas.nexus.mobile/audio_recording');
  Future<void> start() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('startForegroundRecording');
  }
  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stopForegroundRecording');
  }
}

const _audioCodec = 'aacLc';
const _audioMimeType = 'audio/mp4';
const _audioSampleRate = 44100;
const _audioBitRate = 128000;
const _minimumAudioBytes = 1024;
const _minimumAudioBytesPerSecond = 512;

/// Records a voice note into bounded local files. Rotation targets 19 MiB at
/// 128-kbit AAC instead of the server's hard 20 MiB limit, leaving headroom for
/// variable bitrate and M4A finalization metadata.
class SafeAudioRecorder {
  SafeAudioRecorder({
    required RecordingSessionStore store,
    required AudioRecorderAdapter recorder,
    this.segmentDuration = const Duration(seconds: 1245),
    Uuid uuid = const Uuid(),
    AndroidRecordingForegroundService? foregroundService,
  })  : _store = store,
        _recorder = recorder,
        _uuid = uuid,
        _foregroundService = foregroundService ?? AndroidRecordingForegroundService();

  final RecordingSessionStore _store;
  final AudioRecorderAdapter _recorder;
  final Duration segmentDuration;
  final Uuid _uuid;
  final AndroidRecordingForegroundService _foregroundService;

  RecordingSession? _session;
  DateTime? _segmentStartedAt;
  Timer? _rolloverTimer;
  bool _rollingOver = false;

  RecordingSession? get session => _session;

  Future<RecordingSession> start({String? noteId}) async {
    if (_session?.status == RecordingSessionStatus.recording || await _recorder.isRecording()) {
      throw const AudioRecordingException('recording_already_active');
    }
    debugPrint('AUDIO_RECORDING: start requested');
    final hasPermission = await _recorder.hasPermission();
    debugPrint('AUDIO_RECORDING: permission microphone=${hasPermission ? 'granted' : 'denied'}');
    if (!hasPermission) throw const AudioRecordingException('microphone_permission_denied');
    final session = RecordingSession(
      id: _uuid.v4(),
      startedAt: DateTime.now(),
      status: RecordingSessionStatus.recording,
      noteId: noteId,
    );
    _session = session;
    await _store.save(session);
    try {
      await _foregroundService.start();
      await _startSegment();
    } catch (_) {
      await _foregroundService.stop();
      rethrow;
    }
    debugPrint('AUDIO_SESSION: created id=${session.id}');
    return session;
  }

  Future<void> _startSegment() async {
    final current = _session;
    if (current == null) return;
    final directory = await _store.audioDirectory(current.id);
    final index = current.segments.length;
    final path = '${directory.path}/segment_${index.toString().padLeft(4, '0')}.m4a';
    await _recorder.start(path);
    debugPrint('AUDIO_RECORDING: recorder started');
    debugPrint('AUDIO_RECORDING: output_path=$path');
    debugPrint('AUDIO_RECORDING: mime_type=$_audioMimeType');
    debugPrint('AUDIO_RECORDING: codec=$_audioCodec');
    debugPrint('AUDIO_RECORDING: sample_rate=$_audioSampleRate');
    debugPrint('AUDIO_RECORDING: bit_rate=$_audioBitRate');
    _segmentStartedAt = DateTime.now();
    _rolloverTimer?.cancel();
    _rolloverTimer = Timer(segmentDuration, () => unawaited(_rollover()));
  }

  Future<void> _rollover() async {
    if (_rollingOver || _session == null) return;
    _rollingOver = true;
    try {
      await _finishSegment();
      await _startSegment();
    } finally {
      _rollingOver = false;
    }
  }

  Future<void> _finishSegment() async {
    final current = _session;
    final startedAt = _segmentStartedAt;
    if (current == null || startedAt == null || !await _recorder.isRecording()) return;
    final path = await _recorder.stop();
    if (path == null) throw const AudioRecordingException('audio_file_not_finalized');
    final elapsed = DateTime.now().difference(startedAt).inSeconds;
    final duration = elapsed < 1
        ? 1
        : (elapsed > segmentDuration.inSeconds ? segmentDuration.inSeconds : elapsed);
    final updated = current.copyWith(segments: [
      ...current.segments,
      RecordingSegment(index: current.segments.length, localAudioPath: path, durationSeconds: duration,
        sizeBytes: await File(path).length()),
    ]);
    _session = updated;
    await _store.save(updated);
    final file = File(path);
    final exists = await file.exists();
    final size = exists ? await file.length() : 0;
    debugPrint('AUDIO_RECORDING: stopped');
    debugPrint('AUDIO_RECORDING: duration_seconds=$duration');
    debugPrint('AUDIO_RECORDING: output_path=$path');
    debugPrint('AUDIO_RECORDING: file_exists=$exists');
    debugPrint('AUDIO_RECORDING: file_size_bytes=$size');
    debugPrint('AUDIO_RECORDING: extension=${_extension(path)}');
    final minimumExpectedSize = _minimumAudioBytes + duration * _minimumAudioBytesPerSecond;
    if (!isPlausibleAudioFileSize(durationSeconds: duration, sizeBytes: size)) {
      debugPrint(
        'AUDIO_RECORDING: validation failed reason=audio_file_too_small '
        'minimum_expected_bytes=$minimumExpectedSize',
      );
      throw const AudioRecordingException('audio_file_too_small');
    }
    debugPrint('AUDIO_RECORDING: validation passed');
  }

  Future<RecordingSession> stop() async {
    debugPrint('AUDIO_RECORDING: stop requested');
    _rolloverTimer?.cancel();
    while (_rollingOver) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    try {
      await _finishSegment();
    } finally {
      await _foregroundService.stop();
    }
    final current = _session;
    if (current == null) throw const AudioRecordingException('no_active_recording');
    final completed = current.copyWith(status: RecordingSessionStatus.pendingTranscription);
    _session = completed;
    await _store.save(completed);
    debugPrint('AUDIO_RECORDING: duration_seconds=${completed.durationSeconds}');
    final List<int> segmentFiles = await Future.wait<int>(
      completed.segments.map<Future<int>>((segment) async {
        final file = File(segment.localAudioPath);
        return await file.exists() ? await file.length() : 0;
      }),
    );
    final originalSize = segmentFiles.fold<int>(0, (total, size) => total + size);
    debugPrint('AUDIO_SEGMENTATION: target_bytes=$recordingSegmentTargetBytes');
    debugPrint('AUDIO_SEGMENTATION: server_max_bytes=$serverMaxAudioBytes');
    debugPrint('AUDIO_SEGMENTATION: original_size_bytes=$originalSize');
    debugPrint('AUDIO_SEGMENTATION: segment_count=${completed.segments.length}');
    for (var index = 0; index < completed.segments.length; index++) {
      debugPrint(
        'AUDIO_SEGMENTATION: segment index=${index + 1} '
        'path=${completed.segments[index].localAudioPath} size_bytes=${segmentFiles[index]}',
      );
    }
    return completed;
  }
}

Duration configuredAudioSegmentDuration() {
  const configured = int.fromEnvironment('AUDIO_SEGMENTATION_TARGET_BYTES', defaultValue: recordingSegmentTargetBytes);
  final threshold = kDebugMode
      ? configured.clamp(1, recordingSegmentTargetBytes)
      : recordingSegmentTargetBytes;
  final seconds = (threshold * 8 / _audioBitRate).floor();
  return Duration(seconds: seconds < 1 ? 1 : seconds);
}

bool isPlausibleAudioFileSize({
  required int durationSeconds,
  required int sizeBytes,
}) =>
    sizeBytes >= _minimumAudioBytes + durationSeconds * _minimumAudioBytesPerSecond;

String _extension(String path) {
  final filename = path.split(RegExp(r'[/\\]')).last;
  final dot = filename.lastIndexOf('.');
  return dot < 0 ? '' : filename.substring(dot).toLowerCase();
}

class AudioRecordingException implements Exception {
  const AudioRecordingException(this.code);
  final String code;
}
