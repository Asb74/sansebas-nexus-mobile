import 'package:flutter_test/flutter_test.dart';
import 'package:sansebas_nexus_mobile/features/notes/models/mobile_note.dart';
import 'package:sansebas_nexus_mobile/features/notes/models/sync_status.dart';

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
}
