import '../models/mobile_attachment.dart';
import '../models/mobile_note.dart';
import '../models/sync_status.dart';

class FirebaseSyncService {
  Future<void> uploadNote(MobileNote note) async {
    // Placeholder: connect to Firestore in a later phase.
    throw UnimplementedError('Firebase note upload is not implemented yet.');
  }

  Future<void> uploadAttachment(MobileAttachment attachment) async {
    // Placeholder: connect to Firebase Storage in a later phase.
    throw UnimplementedError('Firebase attachment upload is not implemented yet.');
  }

  Stream<List<MobileNote>> watchUserNotes(String userId) {
    // Placeholder: replace with a Firestore query stream in a later phase.
    return const Stream<List<MobileNote>>.empty();
  }

  Future<void> updateNoteStatus({
    required String mobileNoteId,
    required SyncStatus status,
    String? errorMessage,
  }) async {
    // Placeholder: update sync metadata in Firestore in a later phase.
    throw UnimplementedError('Firebase status update is not implemented yet.');
  }
}
