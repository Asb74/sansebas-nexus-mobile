import 'package:cloud_firestore/cloud_firestore.dart';

import 'sync_status.dart';

class MobileNote {
  const MobileNote({
    required this.mobileNoteId,
    required this.title,
    required this.areaId,
    required this.area,
    required this.topicId,
    required this.topic,
    required this.typeId,
    required this.type,
    required this.tags,
    required this.content,
    this.source = 'mobile',
    required this.createdAt,
    required this.updatedAt,
    required this.syncStatus,
    required this.userId,
    required this.deviceId,
    required this.attachmentsCount,
    this.latitude,
    this.longitude,
    this.voiceTranscription,
    this.importedAt,
    this.importedByDesktopId,
    this.errorMessage,
  });

  final String mobileNoteId;
  final String title;
  final String areaId;
  final String area;
  final String topicId;
  final String topic;
  final String typeId;
  final String type;
  final List<String> tags;
  final String content;
  final String source;
  final DateTime createdAt;
  final DateTime updatedAt;
  final SyncStatus syncStatus;
  final String userId;
  final String deviceId;
  final int attachmentsCount;
  final double? latitude;
  final double? longitude;
  final String? voiceTranscription;
  final DateTime? importedAt;
  final String? importedByDesktopId;
  final String? errorMessage;

  bool get hasAttachments => attachmentsCount > 0;
  bool get hasLocation => latitude != null && longitude != null;
  bool get canUpload => syncStatus == SyncStatus.pending;

  Map<String, dynamic> toMap() {
    return {
      'mobile_note_id': mobileNoteId,
      'user_id': userId,
      'device_id': deviceId,
      'title': title,
      'area_id': areaId,
      'area': area,
      'topic_id': topicId,
      'topic': topic,
      'type_id': typeId,
      'type': type,
      'tags': tags,
      'content': content,
      'source': source,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'sync_status': syncStatus.value,
      'attachments_count': attachmentsCount,
      'latitude': latitude,
      'longitude': longitude,
      'voice_transcription': voiceTranscription,
      'imported_at': importedAt?.toIso8601String(),
      'imported_by_desktop_id': importedByDesktopId,
      'error_message': errorMessage,
    };
  }

  factory MobileNote.fromMap(Map<String, dynamic> map) {
    return MobileNote(
      mobileNoteId: _readString(map, 'mobile_note_id', 'mobileNoteId'),
      title: _readString(map, 'title'),
      areaId: _readString(map, 'area_id', 'areaId'),
      area: _readString(map, 'area'),
      topicId: _readString(map, 'topic_id', 'topicId'),
      topic: _readString(map, 'topic'),
      typeId: _readString(map, 'type_id', 'typeId'),
      type: _readString(map, 'type'),
      tags: List<String>.from(map['tags'] as List? ?? const []),
      content: _readString(map, 'content'),
      source: _readString(map, 'source').isEmpty
          ? 'mobile'
          : _readString(map, 'source'),
      createdAt: _readDateTime(map['created_at'] ?? map['createdAt']) ?? DateTime.now(),
      updatedAt: _readDateTime(map['updated_at'] ?? map['updatedAt']) ?? DateTime.now(),
      syncStatus: SyncStatus.fromValue(
        _readNullableString(map['sync_status']) ??
            _readNullableString(map['syncStatus']),
      ),
      userId: _readString(map, 'user_id', 'userId'),
      deviceId: _readString(map, 'device_id', 'deviceId'),
      attachmentsCount: _readInt(map['attachments_count'] ?? map['attachmentsCount']),
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      voiceTranscription: _readNullableString(map['voice_transcription']) ??
          _readNullableString(map['voiceTranscription']),
      importedAt: _readDateTime(map['imported_at'] ?? map['importedAt']),
      importedByDesktopId: _readNullableString(map['imported_by_desktop_id']) ??
          _readNullableString(map['importedByDesktopId']),
      errorMessage: _readNullableString(map['error_message']) ??
          _readNullableString(map['errorMessage']),
    );
  }


  MobileNote copyWith({
    String? mobileNoteId,
    String? title,
    String? areaId,
    String? area,
    String? topicId,
    String? topic,
    String? typeId,
    String? type,
    List<String>? tags,
    String? content,
    String? source,
    DateTime? createdAt,
    DateTime? updatedAt,
    SyncStatus? syncStatus,
    String? userId,
    String? deviceId,
    int? attachmentsCount,
    double? latitude,
    double? longitude,
    String? voiceTranscription,
    DateTime? importedAt,
    String? importedByDesktopId,
    String? errorMessage,
  }) {
    return MobileNote(
      mobileNoteId: mobileNoteId ?? this.mobileNoteId,
      title: title ?? this.title,
      areaId: areaId ?? this.areaId,
      area: area ?? this.area,
      topicId: topicId ?? this.topicId,
      topic: topic ?? this.topic,
      typeId: typeId ?? this.typeId,
      type: type ?? this.type,
      tags: tags ?? this.tags,
      content: content ?? this.content,
      source: source ?? this.source,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      syncStatus: syncStatus ?? this.syncStatus,
      userId: userId ?? this.userId,
      deviceId: deviceId ?? this.deviceId,
      attachmentsCount: attachmentsCount ?? this.attachmentsCount,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      voiceTranscription: voiceTranscription ?? this.voiceTranscription,
      importedAt: importedAt ?? this.importedAt,
      importedByDesktopId: importedByDesktopId ?? this.importedByDesktopId,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  static String _readString(
    Map<String, dynamic> map,
    String key, [
    String? fallbackKey,
  ]) {
    return _readNullableString(map[key]) ??
        (fallbackKey == null ? null : _readNullableString(map[fallbackKey])) ??
        '';
  }

  static String? _readNullableString(Object? value) {
    if (value is! String) return null;
    return value;
  }

  static int _readInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }

  static DateTime? _readDateTime(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }
}
