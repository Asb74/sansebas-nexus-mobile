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
  transcribing,
  completed,
  failed;

  String get value => name;
  static RecordingSegmentStatus fromValue(String? value) => values.firstWhere(
        (status) => status.name == value,
        orElse: () => RecordingSegmentStatus.pending,
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
  });

  final int index;
  final String localAudioPath;
  final int durationSeconds;
  final int sizeBytes;
  final RecordingSegmentStatus status;
  final String? transcription;

  bool get isTranscribed => transcription?.trim().isNotEmpty ?? false;

  RecordingSegment copyWith({String? transcription, RecordingSegmentStatus? status}) => RecordingSegment(
        index: index,
        localAudioPath: localAudioPath,
        durationSeconds: durationSeconds,
        sizeBytes: sizeBytes,
        status: status ?? this.status,
        transcription: transcription ?? this.transcription,
      );

  Map<String, dynamic> toJson() => {
        'index': index,
        'local_audio_path': localAudioPath,
        'duration_seconds': durationSeconds,
        'size_bytes': sizeBytes,
        'state': status.value,
        'transcription': transcription,
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
  String get transcription => (segments.toList()..sort((a, b) => a.index.compareTo(b.index)))
      .map((segment) => segment.transcription?.trim() ?? '')
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
        'transcription': transcription,
        'transcription_applied': transcriptionApplied,
        'note_id': noteId,
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
