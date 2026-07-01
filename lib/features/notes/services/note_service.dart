import '../models/mobile_note.dart';
import '../models/sync_status.dart';

class NoteService {
  MobileNote createDraftNote({
    required String mobileNoteId,
    required String userId,
    required String deviceId,
    String title = '',
    String areaId = '',
    String area = '',
    String topicId = '',
    String topic = '',
    String typeId = 'text',
    String type = 'text',
    List<String> tags = const [],
    String content = '',
  }) {
    final now = DateTime.now();

    return MobileNote(
      mobileNoteId: mobileNoteId,
      title: title,
      areaId: areaId,
      area: area,
      topicId: topicId,
      topic: topic,
      typeId: typeId,
      type: type,
      tags: tags,
      content: content,
      createdAt: now,
      updatedAt: now,
      syncStatus: SyncStatus.pending,
      userId: userId,
      deviceId: deviceId,
      attachmentsCount: 0,
    );
  }

  bool validateNote(MobileNote note) {
    // Placeholder: expand validation rules before enabling real upload.
    return note.title.trim().isNotEmpty || note.content.trim().isNotEmpty;
  }

  MobileNote prepareNoteForUpload(MobileNote note) {
    // Placeholder: normalize payload before Firebase integration in a later phase.
    return note.copyWith(
      updatedAt: DateTime.now(),
      syncStatus: SyncStatus.pending,
    );
  }
}
