import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/recording_session.dart';
import 'audio_limits.dart';
import 'recording_session_store.dart';

abstract interface class M4aResegmenter {
  Future<List<String>> split({required RecordingSegment segment, required String outputDirectory});
}

/// Uses the operating system media APIs to remux complete AAC samples into new
/// standalone M4A containers. It never slices the source file's bytes.
class PlatformM4aResegmenter implements M4aResegmenter {
  static const _channel = MethodChannel('com.sansebas.nexus.mobile/audio_recovery');

  @override
  Future<List<String>> split({required RecordingSegment segment, required String outputDirectory}) async {
    final partCount = (segment.sizeBytes / recordingSegmentTargetBytes).ceil().clamp(2, 1000);
    final result = await _channel.invokeListMethod<String>('splitM4a', {
      'inputPath': segment.localAudioPath,
      'outputDirectory': outputDirectory,
      'baseName': 'segment_${segment.index.toString().padLeft(4, '0')}_part',
      'partCount': partCount,
    });
    return result ?? const [];
  }
}

class AudioRecoveryService {
  AudioRecoveryService({required RecordingSessionStore store, M4aResegmenter? resegmenter})
      : _store = store, _resegmenter = resegmenter ?? PlatformM4aResegmenter();

  final RecordingSessionStore _store;
  final M4aResegmenter _resegmenter;

  Future<RecordingSession> prepare(RecordingSession session) async {
    var current = session;
    final segments = current.segments.toList()..sort((a, b) => a.index.compareTo(b.index));
    for (var position = 0; position < segments.length; position++) {
      var segment = segments[position];
      final original = File(segment.localAudioPath);
      final size = await original.exists() ? await original.length() : segment.sizeBytes;
      if (!requiresAudioResegmentation(size) || segment.recoveryParts.isNotEmpty) continue;
      debugPrint('AUDIO_TRANSCRIPTION: segment too large');
      debugPrint('AUDIO_TRANSCRIPTION: size_bytes=$size');
      debugPrint('AUDIO_TRANSCRIPTION: max_bytes=$serverMaxAudioBytes');
      debugPrint('AUDIO_TRANSCRIPTION: resegmentation_required=true');
      debugPrint('AUDIO_RECOVERY: original_segment=${segment.index} size_bytes=$size action=resegment');
      segment = segment.copyWith(status: RecordingSegmentStatus.requiresResegmentation);
      segments[position] = segment;
      current = current.copyWith(segments: List.unmodifiable(segments));
      await _store.save(current);

      final directory = await _store.audioDirectory(current.id);
      final paths = await _resegmenter.split(segment: segment, outputDirectory: directory.path);
      final parts = <RecordingRecoveryPart>[];
      for (var index = 0; index < paths.length; index++) {
        final file = File(paths[index]);
        if (!await file.exists()) throw const AudioRecoveryException('recovery_part_missing');
        final partSize = await file.length();
        if (partSize <= 0 || partSize > serverMaxAudioBytes) {
          throw AudioRecoveryException('recovery_part_invalid_size:$partSize');
        }
        parts.add(RecordingRecoveryPart(index: index, localAudioPath: file.path,
          durationSeconds: paths.isEmpty ? 0 : (segment.durationSeconds / paths.length).ceil(), sizeBytes: partSize));
      }
      if (parts.length < 2 || !await original.exists() || await original.length() != size) {
        throw const AudioRecoveryException('original_audio_not_preserved');
      }
      segments[position] = segment.copyWith(status: RecordingSegmentStatus.pending, recoveryParts: List.unmodifiable(parts));
      current = current.copyWith(segments: List.unmodifiable(segments));
      await _store.save(current);
      debugPrint('AUDIO_RECOVERY: original_segment=${segment.index} parts=${parts.length}');
    }
    return current;
  }
}

class AudioRecoveryException implements Exception {
  const AudioRecoveryException(this.message);
  final String message;
  @override String toString() => 'AudioRecoveryException: $message';
}
