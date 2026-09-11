import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import '../models/recording_session.dart';
import 'recording_session_store.dart';

abstract interface class AudioSegmentTranscriber {
  Future<String> transcribe(String localAudioPath);
}

class AudioTranscriptionException implements Exception {
  const AudioTranscriptionException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'AudioTranscriptionException: $message'
      '${statusCode == null ? '' : ' (HTTP $statusCode)'}';
}

/// Multipart client for the project's transcription endpoint. The URL is
/// supplied at build time so credentials are never embedded in the app:
/// `--dart-define=AUDIO_TRANSCRIPTION_ENDPOINT=https://…`.
class HttpAudioSegmentTranscriber implements AudioSegmentTranscriber {
  HttpAudioSegmentTranscriber({
    String? endpoint,
    HttpClient? client,
  })  : endpoint = endpoint ?? const String.fromEnvironment('AUDIO_TRANSCRIPTION_ENDPOINT'),
        _client = client ?? HttpClient();

  final String endpoint;
  final HttpClient _client;

  static const _model = 'not_specified_by_client';
  static const _multipartFieldName = 'file';

  bool get isConfigured => Uri.tryParse(endpoint)?.hasScheme ?? false;

  @override
  Future<String> transcribe(String localAudioPath) async {
    if (!isConfigured) {
      debugPrint(
        'AUDIO_TRANSCRIPTION: request not started '
        'reason=transcription_endpoint_not_configured',
      );
      throw const AudioTranscriptionException('transcription_endpoint_not_configured');
    }
    final file = File(localAudioPath);
    debugPrint('AUDIO_TRANSCRIPTION: validation started');
    debugPrint('AUDIO_TRANSCRIPTION: path=$localAudioPath');
    final exists = await file.exists();
    final size = exists ? await file.length() : 0;
    final extension = _extension(localAudioPath);
    final mimeType = lookupMimeType(localAudioPath) ?? 'application/octet-stream';
    debugPrint('AUDIO_TRANSCRIPTION: exists=$exists');
    debugPrint('AUDIO_TRANSCRIPTION: size_bytes=$size');
    debugPrint('AUDIO_TRANSCRIPTION: extension=$extension');
    debugPrint('AUDIO_TRANSCRIPTION: mime_type=$mimeType');
    if (!exists || size == 0) {
      debugPrint(
        'AUDIO_TRANSCRIPTION: request not started reason=local_audio_invalid',
      );
      throw const AudioTranscriptionException('local_audio_invalid');
    }

    try {
      final uri = Uri.parse(endpoint);
      final filename = file.uri.pathSegments.last;
      debugPrint('AUDIO_TRANSCRIPTION: request started');
      debugPrint('AUDIO_TRANSCRIPTION: model=$_model');
      debugPrint('AUDIO_TRANSCRIPTION: endpoint=${_safeEndpoint(uri)}');
      debugPrint('AUDIO_TRANSCRIPTION: multipart field_name=$_multipartFieldName');
      debugPrint('AUDIO_TRANSCRIPTION: filename=$filename');
      debugPrint('AUDIO_TRANSCRIPTION: content_type=$mimeType');
      debugPrint('AUDIO_TRANSCRIPTION: size_bytes=$size');

      final boundary = 'nexus-${DateTime.now().microsecondsSinceEpoch}';
      final request = await _client.postUrl(uri);
      request.headers.contentType = ContentType('multipart', 'form-data', parameters: {'boundary': boundary});
      request.write('--$boundary\r\n');
      request.write(
        'Content-Disposition: form-data; name="$_multipartFieldName"; filename="$filename"\r\n',
      );
      request.write('Content-Type: $mimeType\r\n\r\n');
      await request.addStream(file.openRead());
      request.write('\r\n--$boundary--\r\n');
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      debugPrint('AUDIO_TRANSCRIPTION: response status=${response.statusCode}');
      debugPrint('AUDIO_TRANSCRIPTION: response content_type=${response.headers.contentType?.mimeType ?? 'unknown'}');
      debugPrint('AUDIO_TRANSCRIPTION: response body preview=${_safeBodyPreview(body)}');
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AudioTranscriptionException(
          'El servicio de transcripción devolvió un error',
          statusCode: response.statusCode,
        );
      }
      final decoded = jsonDecode(body);
      final text = decoded is Map ? decoded['text']?.toString().trim() : null;
      if (text == null || text.isEmpty) {
        throw const AudioTranscriptionException('empty_transcription');
      }
      return text;
    } catch (error, stackTrace) {
      debugPrint('AUDIO_TRANSCRIPTION: exception type=${error.runtimeType}');
      debugPrint('AUDIO_TRANSCRIPTION: exception message=$error');
      debugPrint('AUDIO_TRANSCRIPTION: stacktrace=$stackTrace');
      rethrow;
    }
  }
}

String _extension(String path) {
  final filename = path.split(RegExp(r'[/\\]')).last;
  final dot = filename.lastIndexOf('.');
  return dot < 0 ? '' : filename.substring(dot).toLowerCase();
}

String _safeEndpoint(Uri uri) => uri.replace(userInfo: '', query: null, fragment: null).toString();

String _safeBodyPreview(String body) {
  Object? safeValue(Object? value, [String? key]) {
    final normalizedKey = key?.toLowerCase() ?? '';
    if (normalizedKey == 'text' || normalizedKey.contains('transcription')) {
      return '<redacted chars=${value?.toString().length ?? 0}>';
    }
    if (normalizedKey.contains('token') ||
        normalizedKey.contains('authorization') ||
        normalizedKey.contains('api_key') ||
        normalizedKey.contains('apikey')) {
      return '<redacted>';
    }
    if (value is Map) {
      return value.map((mapKey, mapValue) => MapEntry(mapKey.toString(), safeValue(mapValue, mapKey.toString())));
    }
    if (value is List) return value.map(safeValue).toList();
    return value;
  }

  String preview;
  try {
    preview = jsonEncode(safeValue(jsonDecode(body)));
  } on FormatException {
    preview = body;
  }
  return preview.length <= 500 ? preview : '${preview.substring(0, 500)}…';
}

class AudioTranscriptionService {
  AudioTranscriptionService({required RecordingSessionStore store, required AudioSegmentTranscriber transcriber})
      : _store = store,
        _transcriber = transcriber;

  final RecordingSessionStore _store;
  final AudioSegmentTranscriber _transcriber;

  Future<RecordingSession> transcribe(RecordingSession session) async {
    var current = session.copyWith(status: RecordingSessionStatus.transcribing, clearError: true);
    await _store.save(current);
    debugPrint('AUDIO_TRANSCRIPTION: segmentation_started segments=${current.segments.length}');
    try {
      final ordered = current.segments.toList()..sort((a, b) => a.index.compareTo(b.index));
      for (var position = 0; position < ordered.length; position++) {
        final segment = ordered[position];
        if (segment.isTranscribed) continue;
        debugPrint('AUDIO_TRANSCRIPTION: segment index=${segment.index + 1} started');
        final text = await _transcriber.transcribe(segment.localAudioPath);
        ordered[position] = segment.copyWith(transcription: text);
        current = current.copyWith(segments: List.unmodifiable(ordered));
        await _store.save(current);
        debugPrint('AUDIO_TRANSCRIPTION: segment index=${segment.index + 1} status=completed');
        debugPrint('AUDIO_TRANSCRIPTION: segment index=${segment.index + 1} chars=${text.length}');
      }
      current = current.copyWith(status: RecordingSessionStatus.ready, clearError: true);
      await _store.save(current);
      debugPrint('AUDIO_TRANSCRIPTION: completed chars=${current.transcription.length}');
      return current;
    } catch (error, stackTrace) {
      current = current.copyWith(
        status: RecordingSessionStatus.errorRecoverable,
        errorMessage: error.toString(),
      );
      await _store.save(current);
      debugPrint('AUDIO_TRANSCRIPTION: recoverable_error type=${error.runtimeType}');
      debugPrint('AUDIO_TRANSCRIPTION: exception type=${error.runtimeType}');
      debugPrint('AUDIO_TRANSCRIPTION: exception message=$error');
      debugPrint('AUDIO_TRANSCRIPTION: stacktrace=$stackTrace');
      return current;
    }
  }
}
