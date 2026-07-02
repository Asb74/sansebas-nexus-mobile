import 'dart:async';
import 'dart:io';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../models/shared_capture_payload.dart';

class ShareIntentService {
  ShareIntentService._();
  static final ShareIntentService instance = ShareIntentService._();

  final StreamController<SharedCapturePayload> _controller = StreamController<SharedCapturePayload>.broadcast();
  StreamSubscription<List<SharedMediaFile>>? _mediaSubscription;
  bool _started = false;

  Stream<SharedCapturePayload> get payloads => _controller.stream;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    _mediaSubscription = ReceiveSharingIntent.instance.getMediaStream().listen(_emitMediaFiles);
    final initial = await ReceiveSharingIntent.instance.getInitialMedia();
    _emitMediaFiles(initial);
    ReceiveSharingIntent.instance.reset();
  }

  void dispose() {
    _mediaSubscription?.cancel();
    _controller.close();
  }

  Future<void> _emitMediaFiles(List<SharedMediaFile> mediaFiles) async {
    if (mediaFiles.isEmpty) return;
    final payload = await _normalize(mediaFiles);
    if (payload.hasContent) _controller.add(payload);
  }

  Future<SharedCapturePayload> _normalize(List<SharedMediaFile> mediaFiles) async {
    final files = <SharedCaptureFile>[];
    final texts = <String>[];
    final mimeTypes = <String>{};

    for (final shared in mediaFiles) {
      final mimeType = shared.mimeType ?? lookupMimeType(shared.path) ?? 'application/octet-stream';
      mimeTypes.add(mimeType);

      if (mimeType.startsWith('text/') || shared.type == SharedMediaType.text) {
        texts.add(shared.path.trim());
        continue;
      }

      final file = File(shared.path);
      final size = await file.exists() ? await file.length() : 0;
      files.add(
        SharedCaptureFile(
          path: shared.path,
          filename: p.basename(shared.path),
          mimeType: mimeType,
          size: size,
        ),
      );
    }

    final text = texts.where((item) => item.isNotEmpty).join('\n');
    return SharedCapturePayload(
      text: text.isEmpty ? null : text,
      url: _extractUrl(text),
      files: files,
      mimeTypes: mimeTypes.toList(growable: false),
      receivedAt: DateTime.now(),
      sourceApp: null,
    );
  }

  String? _extractUrl(String text) {
    final match = RegExp(r'https?:\/\/[^\s<>"]+', caseSensitive: false).firstMatch(text);
    return match?.group(0);
  }
}
