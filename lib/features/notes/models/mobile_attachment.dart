import 'package:cloud_firestore/cloud_firestore.dart';

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
    this.captureMode = 'camera',
    this.optimizedForOcr = false,
    this.originalFilename,
    this.originalSize,
    this.processedSize,
    this.imageFormat,
    this.width,
    this.height,
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
  final String captureMode;
  final bool optimizedForOcr;
  final String? originalFilename;
  final int? originalSize;
  final int? processedSize;
  final String? imageFormat;
  final int? width;
  final int? height;

  bool get isImage => mimeType.startsWith('image/');
  bool get isUploaded => syncStatus == SyncStatus.uploaded || syncStatus == SyncStatus.imported;

  Map<String, dynamic> toMap() {
    return {
      'mobile_attachment_id': mobileAttachmentId,
      'mobile_note_id': mobileNoteId,
      'filename': filename,
      'mime_type': mimeType,
      'local_path': localPath,
      'storage_path': storagePath,
      'size': size,
      'created_at': createdAt.toIso8601String(),
      'sync_status': syncStatus.value,
      'imported_at': importedAt?.toIso8601String(),
      'error_message': errorMessage,
      'capture_mode': captureMode,
      'optimized_for_ocr': optimizedForOcr,
      'original_filename': originalFilename,
      'original_size': originalSize,
      'processed_size': processedSize,
      'image_format': imageFormat,
      'width': width,
      'height': height,
    };
  }

  factory MobileAttachment.fromMap(Map<String, dynamic> map) {
    return MobileAttachment(
      mobileAttachmentId: _readString(map, 'mobile_attachment_id', 'mobileAttachmentId'),
      mobileNoteId: _readString(map, 'mobile_note_id', 'mobileNoteId'),
      filename: _readString(map, 'filename'),
      mimeType: _readString(map, 'mime_type', 'mimeType'),
      localPath: _readString(map, 'local_path', 'localPath'),
      storagePath: _readNullableString(map['storage_path']) ?? _readNullableString(map['storagePath']),
      size: _readInt(map['size']),
      createdAt: _readDateTime(map['created_at'] ?? map['createdAt']) ?? DateTime.now(),
      syncStatus: SyncStatus.fromValue(_readNullableString(map['sync_status']) ?? _readNullableString(map['syncStatus'])),
      importedAt: _readDateTime(map['imported_at'] ?? map['importedAt']),
      errorMessage: _readNullableString(map['error_message']) ?? _readNullableString(map['errorMessage']),
      captureMode: _readNullableString(map['capture_mode']) ?? _readNullableString(map['captureMode']) ?? 'camera',
      optimizedForOcr: _readBool(map['optimized_for_ocr'] ?? map['optimizedForOcr']),
      originalFilename: _readNullableString(map['original_filename']) ?? _readNullableString(map['originalFilename']),
      originalSize: _readNullableInt(map['original_size'] ?? map['originalSize']),
      processedSize: _readNullableInt(map['processed_size'] ?? map['processedSize']),
      imageFormat: _readNullableString(map['image_format']) ?? _readNullableString(map['imageFormat']),
      width: _readNullableInt(map['width']),
      height: _readNullableInt(map['height']),
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
    String? captureMode,
    bool? optimizedForOcr,
    String? originalFilename,
    int? originalSize,
    int? processedSize,
    String? imageFormat,
    int? width,
    int? height,
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
      captureMode: captureMode ?? this.captureMode,
      optimizedForOcr: optimizedForOcr ?? this.optimizedForOcr,
      originalFilename: originalFilename ?? this.originalFilename,
      originalSize: originalSize ?? this.originalSize,
      processedSize: processedSize ?? this.processedSize,
      imageFormat: imageFormat ?? this.imageFormat,
      width: width ?? this.width,
      height: height ?? this.height,
    );
  }

  static String _readString(Map<String, dynamic> map, String key, [String? fallbackKey]) =>
      _readNullableString(map[key]) ?? (fallbackKey == null ? null : _readNullableString(map[fallbackKey])) ?? '';
  static String? _readNullableString(Object? value) => value is String ? value : null;
  static int _readInt(dynamic value) => value is int ? value : (value is num ? value.toInt() : 0);
  static int? _readNullableInt(dynamic value) => value is int ? value : (value is num ? value.toInt() : null);
  static bool _readBool(dynamic value) => value is bool ? value : false;
  static DateTime? _readDateTime(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }
}
