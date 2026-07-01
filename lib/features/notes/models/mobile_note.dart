import 'sync_status.dart';

class MobileNote {
  const MobileNote({
    required this.mobileNoteId,
    required this.title,
    required this.area,
    required this.topic,
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
  final String area;
  final String topic;
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
      'mobileNoteId': mobileNoteId,
      'title': title,
      'area': area,
      'topic': topic,
      'type': type,
      'tags': tags,
      'content': content,
      'source': source,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'syncStatus': syncStatus.value,
      'userId': userId,
      'deviceId': deviceId,
      'attachmentsCount': attachmentsCount,
      'latitude': latitude,
      'longitude': longitude,
      'voiceTranscription': voiceTranscription,
      'importedAt': importedAt?.toIso8601String(),
      'importedByDesktopId': importedByDesktopId,
      'errorMessage': errorMessage,
    };
  }

  factory MobileNote.fromMap(Map<String, dynamic> map) {
    return MobileNote(
      mobileNoteId: map['mobileNoteId'] as String? ?? '',
      title: map['title'] as String? ?? '',
      area: map['area'] as String? ?? '',
      topic: map['topic'] as String? ?? '',
      type: map['type'] as String? ?? '',
      tags: List<String>.from(map['tags'] as List? ?? const []),
      content: map['content'] as String? ?? '',
      source: map['source'] as String? ?? 'mobile',
      createdAt: _readDateTime(map['createdAt']) ?? DateTime.now(),
      updatedAt: _readDateTime(map['updatedAt']) ?? DateTime.now(),
      syncStatus: SyncStatus.fromValue(map['syncStatus'] as String?),
      userId: map['userId'] as String? ?? '',
      deviceId: map['deviceId'] as String? ?? '',
      attachmentsCount: map['attachmentsCount'] as int? ?? 0,
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      voiceTranscription: map['voiceTranscription'] as String?,
      importedAt: _readDateTime(map['importedAt']),
      importedByDesktopId: map['importedByDesktopId'] as String?,
      errorMessage: map['errorMessage'] as String?,
    );
  }

  MobileNote copyWith({
    String? mobileNoteId,
    String? title,
    String? area,
    String? topic,
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
      area: area ?? this.area,
      topic: topic ?? this.topic,
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

  static DateTime? _readDateTime(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }
}
