import 'dart:async';

import '../models/shared_capture_payload.dart';

/// Placeholder for Android Share Intent support.
///
/// TODO(share-intent): Restore this service in a later phase using a stable
/// implementation that does not depend on `receive_sharing_intent` or
/// otherwise block Android/Kotlin builds.
class ShareIntentService {
  ShareIntentService._();
  static final ShareIntentService instance = ShareIntentService._();

  final StreamController<SharedCapturePayload> _controller =
      StreamController<SharedCapturePayload>.broadcast();

  Stream<SharedCapturePayload> get payloads => _controller.stream;

  Future<void> start() async {
    // Intentionally disabled until Share Intent is reintroduced.
  }

  void dispose() {
    _controller.close();
  }
}
