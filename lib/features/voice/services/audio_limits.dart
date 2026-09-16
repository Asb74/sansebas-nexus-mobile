/// Hard request limit enforced by the transcription Firebase Function.
const int serverMaxAudioBytes = 20 * 1024 * 1024;

/// Client-side rotation/recovery target. The 1 MiB gap leaves room for AAC/M4A
/// bitrate variation and container finalization overhead.
const int recordingSegmentTargetBytes = 19 * 1024 * 1024;

bool requiresAudioResegmentation(int sizeBytes) => sizeBytes > serverMaxAudioBytes;
