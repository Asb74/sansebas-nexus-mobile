import '../models/mobile_attachment.dart';
import '../models/sync_status.dart';

class AttachmentService {
  MobileAttachment prepareLocalAttachment({
    required String mobileAttachmentId,
    required String mobileNoteId,
    required String filename,
    required String mimeType,
    required String localPath,
    required int size,
  }) {
    // Placeholder: later phases will copy/resize files in local app storage.
    return MobileAttachment(
      mobileAttachmentId: mobileAttachmentId,
      mobileNoteId: mobileNoteId,
      filename: filename,
      mimeType: mimeType,
      localPath: localPath,
      size: size,
      createdAt: DateTime.now(),
      syncStatus: SyncStatus.pending,
    );
  }

  bool validateAttachment(MobileAttachment attachment) {
    // Placeholder: add size, MIME type and path rules before real upload.
    return attachment.filename.trim().isNotEmpty &&
        attachment.localPath.trim().isNotEmpty &&
        attachment.size >= 0;
  }

  Future<void> removeLocalAttachment(MobileAttachment attachment) async {
    // Placeholder: delete the local file once persistence is implemented.
    throw UnimplementedError('Local attachment removal is not implemented yet.');
  }
}
