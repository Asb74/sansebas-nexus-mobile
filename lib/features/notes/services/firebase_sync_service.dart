import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/mobile_attachment.dart';
import '../models/mobile_note.dart';
import '../models/sync_status.dart';

class FirebaseSyncService {
  FirebaseSyncService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    DeviceInfoPlugin? deviceInfo,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _deviceInfo = deviceInfo ?? DeviceInfoPlugin();

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final DeviceInfoPlugin _deviceInfo;

  static const String notesCollection = 'nexus_mobile_notes';

  String? get currentUserId => _auth.currentUser?.uid;

  Future<String> readDeviceId() async {
    try {
      if (kIsWeb) {
        final info = await _deviceInfo.webBrowserInfo;
        return info.userAgent ?? 'unknown_device';
      }
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final info = await _deviceInfo.androidInfo;
          return info.id;
        case TargetPlatform.iOS:
          final info = await _deviceInfo.iosInfo;
          return info.identifierForVendor ?? 'unknown_device';
        default:
          return 'unknown_device';
      }
    } catch (error) {
      debugPrint('No se pudo leer device_id: $error');
    }
    return 'unknown_device';
  }

  Future<void> createTextNote(MobileNote note) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw FirebaseSyncException.permissionDenied('No hay usuario autenticado.');
    }

    final noteToSave = note.copyWith(
      userId: uid,
      syncStatus: SyncStatus.uploaded,
      attachmentsCount: 0,
      source: 'mobile',
    );
    final docRef = _firestore.collection(notesCollection).doc(noteToSave.mobileNoteId);

    debugPrint('UID actual: $uid');
    debugPrint('mobile_note_id: ${noteToSave.mobileNoteId}');
    debugPrint('Ruta Firestore usada: $notesCollection/${noteToSave.mobileNoteId}');

    try {
      await docRef.set(noteToSave.toMap());
    } on FirebaseException catch (error) {
      debugPrint('Error exacto Firestore al guardar nota: ${error.code} ${error.message}');
      if (error.code == 'permission-denied') {
        throw FirebaseSyncException.permissionDenied(error.message);
      }
      if (error.code == 'unavailable' || error.code == 'deadline-exceeded') {
        throw FirebaseSyncException.connection(error.message);
      }
      throw FirebaseSyncException.unknown(error.message ?? error.toString());
    } catch (error) {
      debugPrint('Error exacto inesperado al guardar nota: $error');
      throw FirebaseSyncException.unknown(error.toString());
    }
  }

  Future<void> uploadNote(MobileNote note) => createTextNote(note);

  Future<void> uploadAttachment(MobileAttachment attachment) async {
    throw UnimplementedError('Firebase attachment upload is not implemented yet.');
  }

  Stream<List<MobileNote>> watchUserNotes(String userId) {
    return _firestore
        .collection(notesCollection)
        .where('user_id', isEqualTo: userId)
        .orderBy('created_at', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => MobileNote.fromMap(doc.data()))
            .toList(growable: false));
  }

  Future<void> updateNoteStatus({
    required String mobileNoteId,
    required SyncStatus status,
    String? errorMessage,
  }) async {
    await _firestore.collection(notesCollection).doc(mobileNoteId).update({
      'sync_status': status.value,
      'updated_at': DateTime.now().toIso8601String(),
      'error_message': errorMessage,
    });
  }
}

class FirebaseSyncException implements Exception {
  const FirebaseSyncException._(this.kind, this.details);

  factory FirebaseSyncException.permissionDenied(String? details) =>
      FirebaseSyncException._(FirebaseSyncExceptionKind.permissionDenied, details);

  factory FirebaseSyncException.connection(String? details) =>
      FirebaseSyncException._(FirebaseSyncExceptionKind.connection, details);

  factory FirebaseSyncException.unknown(String? details) =>
      FirebaseSyncException._(FirebaseSyncExceptionKind.unknown, details);

  final FirebaseSyncExceptionKind kind;
  final String? details;

  String get userMessage => switch (kind) {
        FirebaseSyncExceptionKind.permissionDenied => 'No tienes permiso para guardar notas',
        FirebaseSyncExceptionKind.connection => 'Error de conexión con Firebase',
        FirebaseSyncExceptionKind.unknown => 'No se pudo guardar la nota',
      };

  @override
  String toString() => 'FirebaseSyncException($kind, $details)';
}

enum FirebaseSyncExceptionKind { permissionDenied, connection, unknown }
