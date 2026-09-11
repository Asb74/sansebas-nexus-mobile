import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../models/recording_session.dart';
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
    this.segmentDuration = const Duration(minutes: 5),
    this.bitsPerSecond = 128000,
    this.safeBytes = 20 * 1024 * 1024,
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

const _audioCodec = 'aacLc';
const _audioMimeType = 'audio/mp4';
const _audioSampleRate = 44100;
const _audioBitRate = 128000;

/// Records a voice note into bounded local files. Five minutes of 128-kbit AAC
/// is well below the 20 MB safe threshold, so no large file is sent upstream.
class SafeAudioRecorder {
  SafeAudioRecorder({
    required RecordingSessionStore store,
    required AudioRecorderAdapter recorder,
    this.segmentDuration = const Duration(minutes: 5),
    Uuid uuid = const Uuid(),
  })  : _store = store,
        _recorder = recorder,
        _uuid = uuid;

  final RecordingSessionStore _store;
  final AudioRecorderAdapter _recorder;
  final Duration segmentDuration;
  final Uuid _uuid;

  RecordingSession? _session;
  DateTime? _segmentStartedAt;
  Timer? _rolloverTimer;
  bool _rollingOver = false;

  RecordingSession? get session => _session;

  Future<RecordingSession> start() async {
    debugPrint('AUDIO_RECORDING: start requested');
    final hasPermission = await _recorder.hasPermission();
    debugPrint('AUDIO_RECORDING: permission microphone=${hasPermission ? 'granted' : 'denied'}');
    if (!hasPermission) throw const AudioRecordingException('microphone_permission_denied');
    final session = RecordingSession(
      id: _uuid.v4(),
      startedAt: DateTime.now(),
      status: RecordingSessionStatus.recording,
    );
    _session = session;
    await _store.save(session);
    await _startSegment();
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
      RecordingSegment(index: current.segments.length, localAudioPath: path, durationSeconds: duration),
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
  }

  Future<RecordingSession> stop() async {
    debugPrint('AUDIO_RECORDING: stop requested');
    _rolloverTimer?.cancel();
    while (_rollingOver) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await _finishSegment();
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
    debugPrint('AUDIO_SEGMENTATION: threshold_bytes=${20 * 1024 * 1024}');
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

String _extension(String path) {
  final filename = path.split(RegExp(r'[/\\]')).last;
  final dot = filename.lastIndexOf('.');
  return dot < 0 ? '' : filename.substring(dot).toLowerCase();
}

class AudioRecordingException implements Exception {
  const AudioRecordingException(this.code);
  final String code;
}
