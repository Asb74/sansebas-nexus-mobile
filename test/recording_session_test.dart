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
    expect(recovered.toJson()['transcription_applied'], isFalse);
    expect(recovered.toJson()['updated_at'], isNotNull);
  });

  test('groups four physical segments as one logical cloud recording', () {
    final session = RecordingSession(
      id: 'logical-1',
      startedAt: DateTime.utc(2026, 9, 16),
      status: RecordingSessionStatus.errorRecoverable,
      segments: List.generate(4, (index) => RecordingSegment(
        index: index,
        localAudioPath: '/private/segment_000$index.m4a',
        durationSeconds: 60,
        sizeBytes: 1024,
      )),
    );
    final metadata = session.toCloudMetadata();
    expect(metadata['recording_id'], 'logical-1');
    expect(metadata['segment_count'], 4);
    expect(metadata['total_size_bytes'], 4096);
    expect(metadata.toString(), isNot(contains('/private/')));
    expect(metadata['transcription_status'], 'failed');
  });

  test('uploaded segments survive restart and only pending audio is retained', () async {
    final audio = File('${temporary.path}/audio.m4a');
    await audio.writeAsBytes(List<int>.filled(128, 1));
    final session = RecordingSession(
      id: 'upload-recovery', startedAt: DateTime.utc(2026),
      status: RecordingSessionStatus.ready, transcriptionApplied: true,
      segments: [RecordingSegment(index: 0, localAudioPath: audio.path,
        durationSeconds: 1, sizeBytes: 128, uploadStatus: AudioUploadStatus.failed)],
    );
    await store.save(session);
    expect((await store.pendingSessions()).single.id, 'upload-recovery');
    await store.deleteSession(session);
    expect(await audio.exists(), isTrue);

    final uploaded = session.copyWith(segments: [session.segments.single.copyWith(
      uploadStatus: AudioUploadStatus.uploaded,
      storagePath: 'users/u/nexus_mobile_notes/n/audio/upload-recovery/segment_0000.m4a',
    )]);
    await store.save(uploaded);
    expect(await store.pendingSessions(), isEmpty);
  });

  test('appends transcription without losing manual or prior content', () {
    expect(appendTranscriptionToContent('', 'Audio uno.'), 'Audio uno.');
    expect(appendTranscriptionToContent('Texto manual.', 'Audio uno.'),
        'Texto manual.\n\nAudio uno.');
    final twice = appendTranscriptionToContent(
      appendTranscriptionToContent('Texto manual.', 'Audio uno.'), 'Audio dos.');
    expect(twice, 'Texto manual.\n\nAudio uno.\n\nAudio dos.');
    expect(appendTranscriptionToContent('Texto intacto', '  '), 'Texto intacto');
    expect(appendTranscriptionToContent('Texto\n\n', 'Audio'), 'Texto\n\nAudio');
  });

  test('applied persisted transcription remains marked idempotently', () {
    final session = RecordingSession(
      id: 'applied', startedAt: DateTime.utc(2026),
      status: RecordingSessionStatus.ready, transcriptionApplied: true,
      segments: const [RecordingSegment(index: 0, localAudioPath: 'audio', durationSeconds: 1,
        transcription: 'Una sola vez.', status: RecordingSegmentStatus.completed)],
    );
    expect(session.transcriptionApplied, isTrue);
    expect(session.transcription, 'Una sola vez.');
  });

  test('recovers orphaned transcribing session and discovers finalized M4A', () async {
    final directory = await store.audioDirectory('orphan');
    final audio = File('${directory.path}/segment_0000.m4a');
    await audio.writeAsBytes(List<int>.filled(2048, 1));
    final orphan = RecordingSession(id: 'orphan', startedAt: DateTime.utc(2026),
      status: RecordingSessionStatus.transcribing);
    await store.save(orphan);
    final recovered = await store.recover(orphan);
    expect(recovered.status, RecordingSessionStatus.errorRecoverable);
    expect(recovered.segments.single.localAudioPath, audio.path);
    expect(recovered.segments.single.sizeBytes, 2048);
  });

  test('lists a ready transcription until it has been applied', () async {
    final unapplied = RecordingSession(
      id: 'ready-unapplied', startedAt: DateTime.utc(2026),
      status: RecordingSessionStatus.ready,
      segments: const [RecordingSegment(index: 0, localAudioPath: 'audio',
        durationSeconds: 1, transcription: 'Recuperar.')],
    );
    await store.save(unapplied);
    expect((await store.pendingSessions()).single.id, 'ready-unapplied');
    await store.save(unapplied.copyWith(transcriptionApplied: true));
    expect(await store.pendingSessions(), isEmpty);
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
    expect(result.segments.last.status, RecordingSegmentStatus.failed);
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

  test('requires a non-empty Firebase ID token before uploading audio', () async {
    final audio = File('${temporary.path}/recording.m4a');
    await audio.writeAsBytes(List<int>.filled(256, 1));

    for (final token in <String?>[null, '']) {
      final transcriber = HttpAudioSegmentTranscriber(
        endpoint: 'https://backend.example/transcribe',
        idTokenProvider: () async => token,
      );

      await expectLater(
        transcriber.transcribe(audio.path),
        throwsA(
          isA<AudioTranscriptionException>()
              .having(
                (error) => error.message,
                'message',
                'firebase_user_not_authenticated',
              )
              .having((error) => error.statusCode, 'statusCode', 401),
        ),
      );
    }
  });
}
