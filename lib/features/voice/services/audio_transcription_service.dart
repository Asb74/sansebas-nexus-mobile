import 'package:flutter/foundation.dart';

import '../models/recording_session.dart';
import 'recording_session_store.dart';

abstract interface class AudioSegmentTranscriber {
  Future<String> transcribe(String localAudioPath);
}

class AudioTranscriptionService {
  AudioTranscriptionService({required RecordingSessionStore store, required AudioSegmentTranscriber transcriber})
      : _store = store,
        _transcriber = transcriber;

  final RecordingSessionStore _store;
  final AudioSegmentTranscriber _transcriber;

  Future<RecordingSession> transcribe(RecordingSession session) async {
    var current = session.copyWith(status: RecordingSessionStatus.transcribing, clearError: true);
    await _store.save(current);
    debugPrint('AUDIO_TRANSCRIPTION: segmentation_started segments=${current.segments.length}');
    try {
      final ordered = current.segments.toList()..sort((a, b) => a.index.compareTo(b.index));
      for (var position = 0; position < ordered.length; position++) {
        final segment = ordered[position];
        if (segment.isTranscribed) continue;
        final text = await _transcriber.transcribe(segment.localAudioPath);
        ordered[position] = segment.copyWith(transcription: text);
        current = current.copyWith(segments: List.unmodifiable(ordered));
        await _store.save(current);
        debugPrint('AUDIO_TRANSCRIPTION: segment_completed index=${segment.index}');
      }
      current = current.copyWith(status: RecordingSessionStatus.ready, clearError: true);
      await _store.save(current);
      debugPrint('AUDIO_TRANSCRIPTION: completed chars=${current.transcription.length}');
      return current;
    } catch (error) {
      current = current.copyWith(
        status: RecordingSessionStatus.errorRecoverable,
        errorMessage: error.runtimeType.toString(),
      );
      await _store.save(current);
      debugPrint('AUDIO_TRANSCRIPTION: recoverable_error type=${error.runtimeType}');
      return current;
    }
  }
}
