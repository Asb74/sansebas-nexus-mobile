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
    await temporary.writeAsString(jsonEncode(session.toJson()), flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  Future<RecordingSession?> read(String sessionId) async {
    final root = await _directoryProvider();
    final file = File('${root.path}/recordings/$sessionId/session.json');
    if (!await file.exists()) return null;
    return RecordingSession.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
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
        if (session.status != RecordingSessionStatus.ready) result.add(session);
      } on FormatException {
        // Ignore a corrupt manifest, but never delete its accompanying audio.
      }
    }
    result.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return result;
  }

  Future<void> deleteSession(RecordingSession session) async {
    final root = await _directoryProvider();
    final directory = Directory('${root.path}/recordings/${session.id}');
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
