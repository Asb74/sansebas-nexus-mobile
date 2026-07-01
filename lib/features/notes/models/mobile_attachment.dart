import 'sync_status.dart';

class MobileAttachment {
  const MobileAttachment({
    required this.mobileAttachmentId,
    required this.mobileNoteId,
    required this.filename,
    required this.mimeType,
    required this.localPath,
    this.storagePath,
    required this.size,
    required this.createdAt,
    required this.syncStatus,
    this.importedAt,
    this.errorMessage,
  });

  final String mobileAttachmentId;
  final String mobileNoteId;
  final String filename;
  final String mimeType;
  final String localPath;
  final String? storagePath;
  final int size;
  final DateTime createdAt;
  final SyncStatus syncStatus;
  final DateTime? importedAt;
  final String? errorMessage;

  bool get isImage => mimeType.startsWith('image/');
  bool get isUploaded => syncStatus == SyncStatus.uploaded || syncStatus == SyncStatus.imported;

  Map<String, dynamic> toMap() {
    return {
      'mobileAttachmentId': mobileAttachmentId,
      'mobileNoteId': mobileNoteId,
      'filename': filename,
      'mimeType': mimeType,
      'localPath': localPath,
      'storagePath': storagePath,
      'size': size,
      'createdAt': createdAt.toIso8601String(),
      'syncStatus': syncStatus.value,
      'importedAt': importedAt?.toIso8601String(),
      'errorMessage': errorMessage,
    };
  }

  factory MobileAttachment.fromMap(Map<String, dynamic> map) {
    return MobileAttachment(
      mobileAttachmentId: map['mobileAttachmentId'] as String? ?? '',
      mobileNoteId: map['mobileNoteId'] as String? ?? '',
      filename: map['filename'] as String? ?? '',
      mimeType: map['mimeType'] as String? ?? '',
      localPath: map['localPath'] as String? ?? '',
      storagePath: map['storagePath'] as String?,
      size: map['size'] as int? ?? 0,
      createdAt: _readDateTime(map['createdAt']) ?? DateTime.now(),
      syncStatus: SyncStatus.fromValue(map['syncStatus'] as String?),
      importedAt: _readDateTime(map['importedAt']),
      errorMessage: map['errorMessage'] as String?,
    );
  }

  MobileAttachment copyWith({
    String? mobileAttachmentId,
    String? mobileNoteId,
    String? filename,
    String? mimeType,
    String? localPath,
    String? storagePath,
    int? size,
    DateTime? createdAt,
    SyncStatus? syncStatus,
    DateTime? importedAt,
    String? errorMessage,
  }) {
    return MobileAttachment(
      mobileAttachmentId: mobileAttachmentId ?? this.mobileAttachmentId,
      mobileNoteId: mobileNoteId ?? this.mobileNoteId,
      filename: filename ?? this.filename,
      mimeType: mimeType ?? this.mimeType,
      localPath: localPath ?? this.localPath,
      storagePath: storagePath ?? this.storagePath,
      size: size ?? this.size,
      createdAt: createdAt ?? this.createdAt,
      syncStatus: syncStatus ?? this.syncStatus,
      importedAt: importedAt ?? this.importedAt,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  static DateTime? _readDateTime(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }
}
