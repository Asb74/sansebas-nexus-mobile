import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../models/recording_session.dart';
import 'recording_session_store.dart';

abstract interface class AudioSegmentTranscriber {
  Future<String> transcribe(String localAudioPath);
}

/// Captures the words recognized by Android/iOS while the original audio is
/// being written locally. No partial result is persisted or sent to Firestore.
class LiveAudioTranscriber {
  LiveAudioTranscriber({SpeechToText? speech}) : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;
  String _recognizedText = '';
  String? _error;

  String get recognizedText => _recognizedText.trim();
  String? get error => _error;

  Future<bool> start() async {
    _recognizedText = '';
    _error = null;
    final available = await _speech.initialize(
      onError: _onError,
      debugLogging: kDebugMode,
    );
    if (!available) {
      _error = 'speech_recognition_unavailable';
      return false;
    }

    final localeId = await _preferredSpanishLocaleId();
    await _speech.listen(
      onResult: _onResult,
      listenMode: ListenMode.dictation,
      partialResults: true,
      listenFor: const Duration(hours: 1),
      pauseFor: const Duration(seconds: 30),
      localeId: localeId,
    );
    return true;
  }

  Future<String> stop() async {
    await _speech.stop();
    // Give the platform callback carrying the final result a chance to arrive.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (_error != null && recognizedText.isEmpty) {
      throw AudioTranscriptionException(_error!);
    }
    if (recognizedText.isEmpty) {
      throw const AudioTranscriptionException('empty_transcription');
    }
    return recognizedText;
  }

  Future<void> cancel() => _speech.cancel();

  void _onResult(SpeechRecognitionResult result) {
    final text = result.recognizedWords.trim();
    if (text.isNotEmpty) _recognizedText = text;
  }

  void _onError(SpeechRecognitionError error) {
    _error = error.errorMsg;
    debugPrint('AUDIO_TRANSCRIPTION: recognition_error ${error.errorMsg}');
  }

  Future<String?> _preferredSpanishLocaleId() async {
    final locales = await _speech.locales();
    for (final locale in locales) {
      if (locale.localeId == 'es_ES' || locale.localeId == 'es-ES') return locale.localeId;
    }
    for (final locale in locales) {
      if (locale.localeId.toLowerCase().startsWith('es')) return locale.localeId;
    }
    return null;
  }
}

class AudioTranscriptionException implements Exception {
  const AudioTranscriptionException(this.code);
  final String code;
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

  bool get isConfigured => Uri.tryParse(endpoint)?.hasScheme ?? false;

  @override
  Future<String> transcribe(String localAudioPath) async {
    if (!isConfigured) {
      throw const AudioTranscriptionException('transcription_endpoint_not_configured');
    }
    final file = File(localAudioPath);
    if (!await file.exists()) {
      throw const AudioTranscriptionException('local_audio_missing');
    }

    final boundary = 'nexus-${DateTime.now().microsecondsSinceEpoch}';
    final request = await _client.postUrl(Uri.parse(endpoint));
    request.headers.contentType = ContentType('multipart', 'form-data', parameters: {'boundary': boundary});
    request.write('--$boundary\r\n');
    request.write(
      'Content-Disposition: form-data; name="file"; filename="${file.uri.pathSegments.last}"\r\n',
    );
    request.write('Content-Type: audio/mp4\r\n\r\n');
    await request.addStream(file.openRead());
    request.write('\r\n--$boundary--\r\n');
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AudioTranscriptionException('http_${response.statusCode}');
    }
    final decoded = jsonDecode(body);
    final text = decoded is Map ? decoded['text']?.toString().trim() : null;
    if (text == null || text.isEmpty) {
      throw const AudioTranscriptionException('empty_transcription');
    }
    return text;
  }
}

class AudioTranscriptionService {
  AudioTranscriptionService({required RecordingSessionStore store, required AudioSegmentTranscriber transcriber})
      : _store = store,
        _transcriber = transcriber;

  final RecordingSessionStore _store;
  final AudioSegmentTranscriber _transcriber;

  /// Associates an in-memory recognition result with the safely finalized
  /// local recording. The manifest is local and remains retryable.
  Future<RecordingSession> completeWithRecognizedText(
    RecordingSession session,
    String transcription,
  ) async {
    final ordered = session.segments.toList()..sort((a, b) => a.index.compareTo(b.index));
    if (ordered.isEmpty || transcription.trim().isEmpty) {
      throw const AudioTranscriptionException('empty_transcription');
    }
    ordered[0] = ordered[0].copyWith(transcription: transcription.trim());
    for (var index = 1; index < ordered.length; index++) {
      ordered[index] = ordered[index].copyWith(transcription: '');
    }
    final completed = session.copyWith(
      status: RecordingSessionStatus.ready,
      segments: List.unmodifiable(ordered),
      clearError: true,
    );
    await _store.save(completed);
    debugPrint('AUDIO_TRANSCRIPTION: completed chars=${completed.transcription.length}');
    return completed;
  }

  Future<RecordingSession> transcribe(RecordingSession session) async {
    var current = session.copyWith(status: RecordingSessionStatus.transcribing, clearError: true);
    await _store.save(current);
    debugPrint('AUDIO_TRANSCRIPTION: segmentation_started segments=${current.segments.length}');
    try {
      final ordered = current.segments.toList()..sort((a, b) => a.index.compareTo(b.index));
      for (var position = 0; position < ordered.length; position++) {
        final segment = ordered[position];
        if (segment.isTranscribed) continue;
        final text = await _transcriber.transcribe(segment.localAudioPath);
        ordered[position] = segment.copyWith(transcription: text);
        current = current.copyWith(segments: List.unmodifiable(ordered));
        await _store.save(current);
        debugPrint('AUDIO_TRANSCRIPTION: segment_completed index=${segment.index}');
      }
      current = current.copyWith(status: RecordingSessionStatus.ready, clearError: true);
      await _store.save(current);
      debugPrint('AUDIO_TRANSCRIPTION: completed chars=${current.transcription.length}');
      return current;
    } catch (error) {
      current = current.copyWith(
        status: RecordingSessionStatus.errorRecoverable,
        errorMessage: error.runtimeType.toString(),
      );
      await _store.save(current);
      debugPrint('AUDIO_TRANSCRIPTION: recoverable_error type=${error.runtimeType}');
      return current;
    }
  }
}
