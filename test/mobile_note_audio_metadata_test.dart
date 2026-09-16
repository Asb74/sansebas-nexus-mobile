import 'package:flutter_test/flutter_test.dart';
import 'package:sansebas_nexus_mobile/features/notes/models/mobile_note.dart';
import 'package:sansebas_nexus_mobile/features/notes/models/sync_status.dart';
import 'package:sansebas_nexus_mobile/features/notes/models/mobile_attachment.dart';
import 'package:sansebas_nexus_mobile/features/notes/services/firebase_sync_service.dart';

void main() {
  test('audio note serializes final transcription and empty summary', () {
    final note = MobileNote(
      mobileNoteId: 'note-1', title: 'Audio', areaId: '', area: '', topicId: '', topic: '',
      typeId: 'note', type: 'note', tags: const [], content: 'Texto completo', summary: '',
      source: 'voice_dictation', sourceType: 'audio', createdAt: DateTime.utc(2026, 9, 9),
      updatedAt: DateTime.utc(2026, 9, 9), syncStatus: SyncStatus.uploaded, userId: 'user',
      deviceId: 'device', attachmentsCount: 0, durationSeconds: 1938,
      transcriptionStatus: 'completed', audioStorageStatus: 'local',
    );

    final map = note.toMap();
    expect(map['content'], 'Texto completo');
    expect(map['summary'], '');
    expect(map['source_type'], 'audio');
    expect(map['duration_seconds'], 1938);
    expect(map['transcription_status'], 'completed');
    expect(map['audio_storage_status'], 'local');
    expect(map['audio_storage_path'], isNull);
    expect(map['attachments_count'], 0);
  });

  test('cloud metadata groups and orders uploaded segments without local paths', () {
    MobileAttachment segment(int index) => MobileAttachment(
      mobileAttachmentId: 'recording-1_segment_000$index',
      mobileNoteId: 'note-1',
      filename: 'segment_000$index.m4a',
      mimeType: 'audio/mp4',
      localPath: '/private/segment_000$index.m4a',
      storagePath: 'users/u/nexus_mobile_notes/note-1/audio/recording-1/segment_000$index.m4a',
      size: 20,
      createdAt: DateTime.utc(2026),
      syncStatus: SyncStatus.uploaded,
      recordingId: 'recording-1',
      segmentIndex: index,
    );
    final metadata = mergeUploadedRecordingMetadata([
      {'recording_id': 'recording-1', 'transcription_status': 'failed'},
    ], [segment(1), segment(0)]).single;
    final segments = metadata['segments'] as List<dynamic>;

    expect(metadata['upload_status'], 'uploaded');
    expect(metadata['segment_count'], 2);
    expect((segments.first as Map<String, dynamic>)['index'], 0);
    expect(metadata.toString(), isNot(contains('/private/')));
  });

  test('retry selects only the failed or pending segments', () {
    MobileAttachment segment(int index, SyncStatus status) => MobileAttachment(
      mobileAttachmentId: 'r_segment_$index', mobileNoteId: 'n',
      filename: 'segment_$index.m4a', mimeType: 'audio/mp4',
      localPath: '/segment_$index.m4a',
      storagePath: status == SyncStatus.uploaded ? 'remote/$index' : null,
      size: 1, createdAt: DateTime.utc(2026), syncStatus: status,
      recordingId: 'r', segmentIndex: index,
    );
    final pending = attachmentsPendingUpload([
      segment(0, SyncStatus.uploaded),
      segment(1, SyncStatus.uploaded),
      segment(2, SyncStatus.error),
      segment(3, SyncStatus.pending),
    ]);

    expect(pending.map((item) => item.segmentIndex), [2, 3]);
  });
}
