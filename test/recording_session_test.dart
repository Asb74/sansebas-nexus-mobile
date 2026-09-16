import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sansebas_nexus_mobile/features/voice/models/recording_session.dart';
import 'package:sansebas_nexus_mobile/features/voice/services/audio_transcription_service.dart';
import 'package:sansebas_nexus_mobile/features/voice/services/audio_limits.dart';
import 'package:sansebas_nexus_mobile/features/voice/services/audio_recovery_service.dart';
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

class _FakeResegmenter implements M4aResegmenter {
  _FakeResegmenter(this.directory);
  final Directory directory;
  int calls = 0;

  @override
  Future<List<String>> split({required RecordingSegment segment, required String outputDirectory}) async {
    calls++;
    final paths = <String>[];
    for (var index = 0; index < 2; index++) {
      final file = File('${directory.path}/segment_${segment.index}_part_$index.m4a');
      await file.open(mode: FileMode.write).then((handle) async {
        await handle.truncate(10 * 1024 * 1024);
        await handle.close();
      });
      paths.add(file.path);
    }
    return paths;
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

  test('19 MiB and exactly 20 MiB are accepted; larger audio requires recovery', () {
    expect(requiresAudioResegmentation(19 * 1024 * 1024), isFalse);
    expect(requiresAudioResegmentation(20 * 1024 * 1024), isFalse);
    expect(requiresAudioResegmentation(20 * 1024 * 1024 + 1), isTrue);
    expect(recordingSegmentTargetBytes, 19 * 1024 * 1024);
  });

  test('recovery preserves originals, explicit part order, and persisted manifest', () async {
    final directory = await store.audioDirectory('real-recovery');
    final original = File('${directory.path}/segment_0000.m4a');
    await original.open(mode: FileMode.write).then((handle) async {
      await handle.truncate(serverMaxAudioBytes + 1000);
      await handle.close();
    });
    final originalLength = await original.length();
    final fake = _FakeResegmenter(directory);
    final session = RecordingSession(id: 'real-recovery', startedAt: DateTime.utc(2026),
      status: RecordingSessionStatus.pendingTranscription,
      segments: [RecordingSegment(index: 0, localAudioPath: original.path,
        durationSeconds: 1260, sizeBytes: originalLength)]);

    final recovered = await AudioRecoveryService(store: store, resegmenter: fake).prepare(session);
    expect(await original.exists(), isTrue);
    expect(await original.length(), originalLength);
    expect(recovered.segments.single.recoveryParts.map((part) => part.index), [0, 1]);
    final persisted = await store.read('real-recovery');
    expect(persisted!.segments.single.recoveryParts.length, 2);
    expect(persisted.segments.single.localAudioPath, original.path);
  });

  test('completed recovery parts are skipped and pending parts retain global order', () async {
    final parts = const [
      RecordingRecoveryPart(index: 1, localAudioPath: '0.1', durationSeconds: 10,
        sizeBytes: 10, status: RecordingSegmentStatus.pending),
      RecordingRecoveryPart(index: 0, localAudioPath: '0.0', durationSeconds: 10,
        sizeBytes: 10, status: RecordingSegmentStatus.completed, transcription: 'Primero.'),
    ];
    final session = RecordingSession(id: 'parts', startedAt: DateTime.utc(2026),
      status: RecordingSessionStatus.errorRecoverable,
      segments: [
        RecordingSegment(index: 1, localAudioPath: '1', durationSeconds: 10),
        RecordingSegment(index: 0, localAudioPath: '0', durationSeconds: 20, recoveryParts: parts),
      ]);
    final transcriber = _FakeTranscriber({'0.1': 'Segundo.', '1': 'Tercero.'});
    final result = await AudioTranscriptionService(store: store, transcriber: transcriber).transcribe(session);

    expect(transcriber.calls, ['0.1', '1']);
    expect(result.transcription, 'Primero.\n\nSegundo.\n\nTercero.');
    expect(result.status, RecordingSessionStatus.ready);
  });

  test('session recovery does not promote recovery parts to original segments', () async {
    final directory = await store.audioDirectory('parts-restart');
    final original = File('${directory.path}/segment_0000.m4a');
    final part = File('${directory.path}/segment_0000_part_000.m4a');
    await original.writeAsBytes([1, 2, 3]);
    await part.writeAsBytes([1, 2]);
    final session = RecordingSession(id: 'parts-restart', startedAt: DateTime.utc(2026),
      status: RecordingSessionStatus.errorRecoverable,
      segments: [RecordingSegment(index: 0, localAudioPath: original.path, durationSeconds: 2,
        recoveryParts: [RecordingRecoveryPart(index: 0, localAudioPath: part.path,
          durationSeconds: 1, sizeBytes: 2, transcription: 'Guardado.', status: RecordingSegmentStatus.completed)])]);
    await store.save(session);

    final recovered = await store.recover(session);
    expect(recovered.segments, hasLength(1));
    expect(recovered.segments.single.recoveryParts.single.transcription, 'Guardado.');
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

  test('oversized HTTP input is rejected locally before authentication', () async {
    final audio = File('${temporary.path}/oversized.m4a');
    final handle = await audio.open(mode: FileMode.write);
    await handle.truncate(serverMaxAudioBytes + 1);
    await handle.close();
    var requestedToken = false;
    final transcriber = HttpAudioSegmentTranscriber(
      endpoint: 'https://backend.example/transcribe',
      idTokenProvider: () async {
        requestedToken = true;
        return 'unused';
      },
    );

    await expectLater(
      transcriber.transcribe(audio.path),
      throwsA(
        isA<AudioTranscriptionException>().having(
          (error) => error.message,
          'message',
          'requires_resegmentation',
        ),
      ),
    );
    expect(requestedToken, isFalse);
  });
}
