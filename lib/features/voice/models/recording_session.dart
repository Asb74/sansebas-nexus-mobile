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

class RecordingSegment {
  const RecordingSegment({
    required this.index,
    required this.localAudioPath,
    required this.durationSeconds,
    this.transcription,
  });

  final int index;
  final String localAudioPath;
  final int durationSeconds;
  final String? transcription;

  bool get isTranscribed => transcription != null;

  RecordingSegment copyWith({String? transcription}) => RecordingSegment(
        index: index,
        localAudioPath: localAudioPath,
        durationSeconds: durationSeconds,
        transcription: transcription ?? this.transcription,
      );

  Map<String, dynamic> toJson() => {
        'index': index,
        'local_audio_path': localAudioPath,
        'duration_seconds': durationSeconds,
        'transcription': transcription,
      };

  factory RecordingSegment.fromJson(Map<String, dynamic> json) => RecordingSegment(
        index: (json['index'] as num?)?.toInt() ?? 0,
        localAudioPath: json['local_audio_path'] as String? ?? '',
        durationSeconds: (json['duration_seconds'] as num?)?.toInt() ?? 0,
        transcription: json['transcription'] as String?,
      );
}

class RecordingSession {
  const RecordingSession({
    required this.id,
    required this.startedAt,
    required this.status,
    this.segments = const [],
    this.errorMessage,
  });

  final String id;
  final DateTime startedAt;
  final RecordingSessionStatus status;
  final List<RecordingSegment> segments;
  final String? errorMessage;

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
  }) => RecordingSession(
        id: id,
        startedAt: startedAt,
        status: status ?? this.status,
        segments: segments ?? this.segments,
        errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'started_at': startedAt.toIso8601String(),
        'status': status.value,
        'segments': segments.map((item) => item.toJson()).toList(),
        'error_message': errorMessage,
      };

  factory RecordingSession.fromJson(Map<String, dynamic> json) => RecordingSession(
        id: json['id'] as String? ?? '',
        startedAt: DateTime.tryParse(json['started_at'] as String? ?? '') ?? DateTime.now(),
        status: RecordingSessionStatus.fromValue(json['status'] as String?),
        segments: (json['segments'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => RecordingSegment.fromJson(Map<String, dynamic>.from(item)))
            .toList(growable: false),
        errorMessage: json['error_message'] as String?,
      );
}
