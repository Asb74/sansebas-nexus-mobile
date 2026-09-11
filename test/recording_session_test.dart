import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sansebas_nexus_mobile/features/voice/models/recording_session.dart';
import 'package:sansebas_nexus_mobile/features/voice/services/audio_transcription_service.dart';
import 'package:sansebas_nexus_mobile/features/voice/services/recording_session_store.dart';
import 'package:sansebas_nexus_mobile/features/voice/services/safe_audio_recorder.dart';

class _FakeTranscriber implements AudioSegmentTranscriber {
  _FakeTranscriber(this.results, {this.failPath});
  final Map<String, String> results;
  final String? failPath;
  final List<String> calls = [];

  @override
  Future<String> transcribe(String localAudioPath) async {
    calls.add(localAudioPath);
    if (localAudioPath == failPath) throw StateError('temporary');
    return results[localAudioPath]!;
  }
}

void main() {
  late Directory temporary;
  late RecordingSessionStore store;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('nexus_recording_test_');
    store = RecordingSessionStore(directoryProvider: () async => temporary);
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('persists a pending local session atomically', () async {
    final session = RecordingSession(
      id: 'session-1',
      startedAt: DateTime.utc(2026, 9, 9),
      status: RecordingSessionStatus.pendingTranscription,
      segments: const [RecordingSegment(index: 0, localAudioPath: '/local/audio.m4a', durationSeconds: 757)],
    );
    await store.save(session);

    final recovered = (await store.pendingSessions()).single;
    expect(recovered.id, 'session-1');
    expect(recovered.durationSeconds, 757);
    expect(recovered.segments.single.localAudioPath, '/local/audio.m4a');
  });

  test('transcribes segments in order and concatenates without Firestore', () async {
    final session = RecordingSession(
      id: 'large-audio',
      startedAt: DateTime.utc(2026, 9, 9),
      status: RecordingSessionStatus.pendingTranscription,
      segments: const [
        RecordingSegment(index: 1, localAudioPath: 'part-2', durationSeconds: 300),
        RecordingSegment(index: 0, localAudioPath: 'part-1', durationSeconds: 300),
      ],
    );
    final transcriber = _FakeTranscriber({'part-1': 'Primera parte.', 'part-2': 'Segunda parte.'});
    final result = await AudioTranscriptionService(store: store, transcriber: transcriber).transcribe(session);

    expect(transcriber.calls, ['part-1', 'part-2']);
    expect(result.status, RecordingSessionStatus.ready);
    expect(result.transcription, 'Primera parte.\n\nSegunda parte.');
  });

  test('keeps completed segments and marks a failure recoverable', () async {
    final session = RecordingSession(
      id: 'retryable',
      startedAt: DateTime.utc(2026, 9, 9),
      status: RecordingSessionStatus.pendingTranscription,
      segments: const [
        RecordingSegment(index: 0, localAudioPath: 'done', durationSeconds: 300, transcription: 'Ya guardado.'),
        RecordingSegment(index: 1, localAudioPath: 'fails', durationSeconds: 300),
      ],
    );
    final result = await AudioTranscriptionService(
      store: store,
      transcriber: _FakeTranscriber({'done': 'duplicado', 'fails': 'final'}, failPath: 'fails'),
    ).transcribe(session);

    expect(result.status, RecordingSessionStatus.errorRecoverable);
    expect(result.segments.first.transcription, 'Ya guardado.');
    expect((await store.read('retryable'))!.status, RecordingSessionStatus.errorRecoverable);
  });

  test('a recording over 20 MB is split while smaller audio stays whole', () {
    const policy = AudioSegmentationPolicy();
    const duration = Duration(minutes: 30); // About 28.8 MB at 128 kbit/s.

    expect(policy.segmentCount(const Duration(minutes: 20)), 1);
    expect(policy.segmentCount(duration), 2);
    expect(policy.estimatedSegmentBytes, lessThan(20 * 1024 * 1024));
    expect(policy.isWithinSafeThreshold, isTrue);
  });

  test('formats the local recording timer below and above one hour', () {
    expect(formatAudioDuration(const Duration(seconds: 27)), '00:27');
    expect(formatAudioDuration(const Duration(hours: 1, minutes: 12, seconds: 34)), '01:12:34');
  });

  test('rejects a tiny file that cannot plausibly contain its duration', () {
    expect(
      isPlausibleAudioFileSize(durationSeconds: 28, sizeBytes: 3109),
      isFalse,
    );
    expect(
      isPlausibleAudioFileSize(durationSeconds: 28, sizeBytes: 448000),
      isTrue,
    );
  });

  test('transcription exceptions include their real message and HTTP status', () {
    const error = AudioTranscriptionException('Servicio no disponible', statusCode: 503);

    expect(
      error.toString(),
      'AudioTranscriptionException: Servicio no disponible (HTTP 503)',
    );
  });

  test('accepts only a complete HTTP transcription endpoint', () {
    expect(
      HttpAudioSegmentTranscriber(
        endpoint: '  https://backend.example/transcribe  ',
      ).endpoint,
      'https://backend.example/transcribe',
    );
    expect(
      HttpAudioSegmentTranscriber(
        endpoint: 'https://backend.example/transcribe',
      ).isConfigured,
      isTrue,
    );
    expect(HttpAudioSegmentTranscriber(endpoint: '').isConfigured, isFalse);
    expect(HttpAudioSegmentTranscriber(endpoint: '/transcribe').isConfigured, isFalse);
    expect(
      HttpAudioSegmentTranscriber(
        endpoint: 'ftp://backend.example/transcribe',
      ).isConfigured,
      isFalse,
    );
  });
}
