enum RecordingSessionStatus {
  recording,
  pendingTranscription,
  transcribing,
  ready,
  errorRecoverable;

  String get value => switch (this) {
        RecordingSessionStatus.recording => 'recording',
        RecordingSessionStatus.pendingTranscription => 'pending_transcription',
        RecordingSessionStatus.transcribing => 'transcribing',
        RecordingSessionStatus.ready => 'ready',
        RecordingSessionStatus.errorRecoverable => 'error_recoverable',
      };

  static RecordingSessionStatus fromValue(String? value) => values.firstWhere(
        (status) => status.value == value || status.name == value,
        orElse: () => RecordingSessionStatus.errorRecoverable,
      );
}

enum RecordingSegmentStatus {
  pending,
  requiresResegmentation,
  transcribing,
  completed,
  failed;

  String get value => switch (this) {
        RecordingSegmentStatus.requiresResegmentation => 'requires_resegmentation',
        _ => name,
      };
  static RecordingSegmentStatus fromValue(String? value) => values.firstWhere(
        (status) => status.name == value || status.value == value,
        orElse: () => RecordingSegmentStatus.pending,
      );
}

class RecordingRecoveryPart {
  const RecordingRecoveryPart({
    required this.index,
    required this.localAudioPath,
    required this.durationSeconds,
    required this.sizeBytes,
    this.status = RecordingSegmentStatus.pending,
    this.transcription,
  });

  final int index;
  final String localAudioPath;
  final int durationSeconds;
  final int sizeBytes;
  final RecordingSegmentStatus status;
  final String? transcription;

  bool get isTranscribed => transcription?.trim().isNotEmpty ?? false;

  RecordingRecoveryPart copyWith({RecordingSegmentStatus? status, String? transcription}) =>
      RecordingRecoveryPart(index: index, localAudioPath: localAudioPath,
        durationSeconds: durationSeconds, sizeBytes: sizeBytes,
        status: status ?? this.status, transcription: transcription ?? this.transcription);

  Map<String, dynamic> toJson() => {
    'index': index, 'local_audio_path': localAudioPath,
    'duration_seconds': durationSeconds, 'size_bytes': sizeBytes,
    'state': status.value, 'transcription': transcription,
  };

  factory RecordingRecoveryPart.fromJson(Map<String, dynamic> json) => RecordingRecoveryPart(
    index: (json['index'] as num?)?.toInt() ?? 0,
    localAudioPath: json['local_audio_path'] as String? ?? '',
    durationSeconds: (json['duration_seconds'] as num?)?.toInt() ?? 0,
    sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
    status: RecordingSegmentStatus.fromValue(json['state'] as String?),
    transcription: json['transcription'] as String?,
  );
}

enum AudioUploadStatus {
  localOnly('local_only'),
  uploading('uploading'),
  uploaded('uploaded'),
  failed('failed');

  const AudioUploadStatus(this.value);
  final String value;

  static AudioUploadStatus fromValue(String? value) => values.firstWhere(
        (status) => status.value == value || status.name == value,
        orElse: () => AudioUploadStatus.localOnly,
      );
}

class RecordingSegment {
  const RecordingSegment({
    required this.index,
    required this.localAudioPath,
    required this.durationSeconds,
    this.sizeBytes = 0,
    this.status = RecordingSegmentStatus.pending,
    this.transcription,
    this.uploadStatus = AudioUploadStatus.localOnly,
    this.storagePath,
    this.recoveryParts = const [],
  });

  final int index;
  final String localAudioPath;
  final int durationSeconds;
  final int sizeBytes;
  final RecordingSegmentStatus status;
  final String? transcription;
  final AudioUploadStatus uploadStatus;
  final String? storagePath;
  final List<RecordingRecoveryPart> recoveryParts;

  String get filename => localAudioPath.split(RegExp(r'[/\\]')).last;

  bool get isTranscribed => recoveryParts.isNotEmpty
      ? recoveryParts.every((part) => part.isTranscribed)
      : (transcription?.trim().isNotEmpty ?? false);

  String get completeTranscription => recoveryParts.isEmpty
      ? (transcription?.trim() ?? '')
      : (recoveryParts.toList()..sort((a, b) => a.index.compareTo(b.index)))
          .map((part) => part.transcription?.trim() ?? '').where((text) => text.isNotEmpty).join('\n\n');

  RecordingSegment copyWith({String? transcription, RecordingSegmentStatus? status,
        AudioUploadStatus? uploadStatus, String? storagePath,
        List<RecordingRecoveryPart>? recoveryParts, int? sizeBytes}) => RecordingSegment(
        index: index,
        localAudioPath: localAudioPath,
        durationSeconds: durationSeconds,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        status: status ?? this.status,
        transcription: transcription ?? this.transcription,
        uploadStatus: uploadStatus ?? this.uploadStatus,
        storagePath: storagePath ?? this.storagePath,
        recoveryParts: recoveryParts ?? this.recoveryParts,
      );

  Map<String, dynamic> toJson() => {
        'index': index,
        'local_audio_path': localAudioPath,
        'duration_seconds': durationSeconds,
        'size_bytes': sizeBytes,
        'state': status.value,
        'transcription': transcription,
        'filename': filename,
        'mime_type': 'audio/mp4',
        'upload_status': uploadStatus.value,
        'storage_path': storagePath,
        'recovery_parts': recoveryParts.map((part) => part.toJson()).toList(),
      };

  factory RecordingSegment.fromJson(Map<String, dynamic> json) => RecordingSegment(
        index: (json['index'] as num?)?.toInt() ?? 0,
        localAudioPath: json['local_audio_path'] as String? ?? '',
        durationSeconds: (json['duration_seconds'] as num?)?.toInt() ?? 0,
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        status: json['transcription'] != null && json['state'] == null
            ? RecordingSegmentStatus.completed
            : RecordingSegmentStatus.fromValue(json['state'] as String?),
        transcription: json['transcription'] as String?,
        uploadStatus: AudioUploadStatus.fromValue(json['upload_status'] as String?),
        storagePath: json['storage_path'] as String?,
        recoveryParts: (json['recovery_parts'] as List? ?? const []).whereType<Map>()
            .map((part) => RecordingRecoveryPart.fromJson(Map<String, dynamic>.from(part))).toList(),
      );
}

class RecordingSession {
  const RecordingSession({
    required this.id,
    required this.startedAt,
    required this.status,
    DateTime? updatedAt,
    this.segments = const [],
    this.transcriptionApplied = false,
    this.noteId,
    this.errorMessage,
  }) : updatedAt = updatedAt ?? startedAt;

  final String id;
  final DateTime startedAt;
  final RecordingSessionStatus status;
  final DateTime updatedAt;
  final List<RecordingSegment> segments;
  final String? errorMessage;
  final bool transcriptionApplied;
  final String? noteId;

  int get durationSeconds => segments.fold(0, (total, item) => total + item.durationSeconds);
  int get totalSizeBytes => segments.fold(0, (total, item) => total + item.sizeBytes);
  AudioUploadStatus get uploadStatus {
    if (segments.isNotEmpty && segments.every((item) => item.uploadStatus == AudioUploadStatus.uploaded)) {
      return AudioUploadStatus.uploaded;
    }
    if (segments.any((item) => item.uploadStatus == AudioUploadStatus.failed)) return AudioUploadStatus.failed;
    if (segments.any((item) => item.uploadStatus == AudioUploadStatus.uploading)) return AudioUploadStatus.uploading;
    return AudioUploadStatus.localOnly;
  }
  String get transcriptionStatus => switch (status) {
        RecordingSessionStatus.ready => 'completed',
        RecordingSessionStatus.errorRecoverable => 'failed',
        RecordingSessionStatus.transcribing => 'transcribing',
        RecordingSessionStatus.recording ||
        RecordingSessionStatus.pendingTranscription => 'pending',
      };
  String get transcription => (segments.toList()..sort((a, b) => a.index.compareTo(b.index)))
      .map((segment) => segment.completeTranscription)
      .where((text) => text.isNotEmpty)
      .join('\n\n');

  RecordingSession copyWith({
    RecordingSessionStatus? status,
    List<RecordingSegment>? segments,
    String? errorMessage,
    bool clearError = false,
    bool? transcriptionApplied,
    String? noteId,
  }) => RecordingSession(
        id: id,
        startedAt: startedAt,
        status: status ?? this.status,
        updatedAt: DateTime.now().toUtc(),
        segments: segments ?? this.segments,
        errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
        transcriptionApplied: transcriptionApplied ?? this.transcriptionApplied,
        noteId: noteId ?? this.noteId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'started_at': startedAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'status': status.value,
        'segments': segments.map((item) => item.toJson()).toList(),
        'error_message': errorMessage,
        'duration_seconds': durationSeconds,
        'total_size_bytes': totalSizeBytes,
        'segment_count': segments.length,
        'upload_status': uploadStatus.value,
        'transcription': transcription,
        'transcription_applied': transcriptionApplied,
        'note_id': noteId,
      };

  Map<String, dynamic> toCloudMetadata() => {
        'recording_id': id,
        'created_at': startedAt.toUtc().toIso8601String(),
        'duration_seconds_total': durationSeconds,
        'total_size_bytes': totalSizeBytes,
        'segment_count': segments.length,
        'transcription_status': transcriptionStatus,
        'upload_status': uploadStatus.value,
        'segments': (segments.toList()..sort((a, b) => a.index.compareTo(b.index)))
            .map((segment) => {
                  'index': segment.index,
                  'filename': segment.filename,
                  'mime_type': 'audio/mp4',
                  'size_bytes': segment.sizeBytes,
                  'duration_seconds': segment.durationSeconds,
                  'storage_path': segment.storagePath,
                  'upload_status': segment.uploadStatus.value,
                })
            .toList(growable: false),
      };

  factory RecordingSession.fromJson(Map<String, dynamic> json) => RecordingSession(
        id: json['id'] as String? ?? '',
        startedAt: DateTime.tryParse(json['started_at'] as String? ?? '') ?? DateTime.now(),
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
        status: RecordingSessionStatus.fromValue(json['status'] as String?),
        segments: (json['segments'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => RecordingSegment.fromJson(Map<String, dynamic>.from(item)))
            .toList(growable: false),
        errorMessage: json['error_message'] as String?,
        transcriptionApplied: json['transcription_applied'] as bool? ?? false,
        noteId: json['note_id'] as String?,
      );
}
