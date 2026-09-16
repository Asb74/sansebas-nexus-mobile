import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/recording_session.dart';

typedef RecordingDirectoryProvider = Future<Directory> Function();

class RecordingSessionStore {
  RecordingSessionStore({RecordingDirectoryProvider? directoryProvider})
      : _directoryProvider = directoryProvider ?? getApplicationDocumentsDirectory;

  final RecordingDirectoryProvider _directoryProvider;

  Future<Directory> audioDirectory(String sessionId) async {
    final root = await _directoryProvider();
    final directory = Directory('${root.path}/recordings/$sessionId');
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> save(RecordingSession session) async {
    final directory = await audioDirectory(session.id);
    final target = File('${directory.path}/session.json');
    final temporary = File('${target.path}.tmp');
    final backup = File('${target.path}.bak');
    final sink = temporary.openWrite();
    sink.write(jsonEncode(session.toJson()));
    await sink.flush();
    await sink.close();
    if (await backup.exists()) await backup.delete();
    if (await target.exists()) await target.rename(backup.path);
    try {
      await temporary.rename(target.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (await backup.exists() && !await target.exists()) await backup.rename(target.path);
      rethrow;
    }
  }

  Future<RecordingSession?> read(String sessionId) async {
    final root = await _directoryProvider();
    final file = File('${root.path}/recordings/$sessionId/session.json');
    final backup = File('${file.path}.bak');
    for (final candidate in [file, backup]) {
      if (!await candidate.exists()) continue;
      try {
        return RecordingSession.fromJson(jsonDecode(await candidate.readAsString()) as Map<String, dynamic>);
      } catch (_) {
        // Try the previous atomically saved manifest. Audio is never removed.
      }
    }
    return null;
  }

  Future<List<RecordingSession>> pendingSessions() async {
    final root = await _directoryProvider();
    final recordings = Directory('${root.path}/recordings');
    if (!await recordings.exists()) return const [];
    final result = <RecordingSession>[];
    await for (final entity in recordings.list()) {
      if (entity is! Directory) continue;
      final file = File('${entity.path}/session.json');
      if (!await file.exists()) continue;
      try {
        final session = RecordingSession.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
        if (session.status != RecordingSessionStatus.ready ||
            !session.transcriptionApplied ||
            session.uploadStatus != AudioUploadStatus.uploaded) {
          result.add(session);
        }
      } catch (_) {
        // Ignore a corrupt manifest, but never delete its accompanying audio.
      }
    }
    result.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return result;
  }

  Future<RecordingSession> recover(RecordingSession session) async {
    final directory = await audioDirectory(session.id);
    final known = {for (final segment in session.segments) segment.localAudioPath: segment};
    final files = await directory
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.m4a'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    final segments = <RecordingSegment>[];
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      final previous = known[file.path];
      segments.add(previous ?? RecordingSegment(
        index: index,
        localAudioPath: file.path,
        durationSeconds: 0,
        sizeBytes: await file.length(),
      ));
    }
    var status = session.status;
    if (status == RecordingSessionStatus.recording || status == RecordingSessionStatus.transcribing) {
      status = RecordingSessionStatus.errorRecoverable;
    }
    final recovered = session.copyWith(status: status, segments: segments);
    await save(recovered);
    return recovered;
  }

  Future<void> deleteSession(RecordingSession session) async {
    if (session.uploadStatus != AudioUploadStatus.uploaded) return;
    final root = await _directoryProvider();
    final directory = Directory('${root.path}/recordings/${session.id}');
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
