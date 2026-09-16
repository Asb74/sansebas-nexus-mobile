import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import '../models/mobile_attachment.dart';
import '../models/mobile_note.dart';
import '../models/sync_status.dart';

class FirebaseSyncService {
  FirebaseSyncService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    DeviceInfoPlugin? deviceInfo,
    FirebaseStorage? storage,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _deviceInfo = deviceInfo ?? DeviceInfoPlugin(),
        _storage = storage ?? FirebaseStorage.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final DeviceInfoPlugin _deviceInfo;
  final FirebaseStorage _storage;

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
    );
    final docRef = _firestore.collection(notesCollection).doc(noteToSave.mobileNoteId);

    debugPrint('UID actual: $uid');
    debugPrint('mobile_note_id: ${noteToSave.mobileNoteId}');
    debugPrint('Ruta Firestore usada: $notesCollection/${noteToSave.mobileNoteId}');

    try {
      debugPrint('FIRESTORE_AUDIO_DEBUG: write requested stage=final_note_create');
      await docRef.set(noteToSave.toMap());
      debugPrint('FIRESTORE_AUDIO_DEBUG: write completed stage=final_note_create');
      debugPrint('FIRESTORE_NOTE: final_sync completed note_id=${noteToSave.mobileNoteId}');
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

  Future<void> createNoteWithAttachments({
    required MobileNote note,
    required List<MobileAttachment> attachments,
    Future<void> Function(MobileAttachment uploaded)? onAttachmentUploaded,
  }) async {
    if (attachments.isEmpty) {
      await createTextNote(note);
      return;
    }

    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw FirebaseSyncException.permissionDenied('No hay usuario autenticado.');
    }

    final now = DateTime.now();
    final noteToSave = note.copyWith(
      userId: uid,
      syncStatus: SyncStatus.uploading,
      attachmentsCount: 0,
      updatedAt: now,
      errorMessage: null,
    );
    final docRef = _firestore.collection(notesCollection).doc(noteToSave.mobileNoteId);

    debugPrint('noteId: ${noteToSave.mobileNoteId}');
    debugPrint('Ruta Firestore usada: $notesCollection/${noteToSave.mobileNoteId}');

    try {
      debugPrint('FIRESTORE_AUDIO_DEBUG: write requested stage=initial_note_create');
      await docRef.set(noteToSave.toMap());
      debugPrint('FIRESTORE_AUDIO_DEBUG: write completed stage=initial_note_create');

      final uploadedAttachments = <MobileAttachment>[];
      uploadedAttachments.addAll(
        attachments.where((item) => item.isUploaded && item.storagePath != null),
      );
      for (final attachment in attachmentsPendingUpload(attachments)) {
        final storageFilename = attachment.captureMode == 'document_scan' && attachment.documentFormat == 'pdf'
            ? '${attachment.mobileAttachmentId}_scan.pdf'
            : '${attachment.mobileAttachmentId}_${attachment.filename}';
        final storagePath = attachment.recordingId == null
            ? 'users/$uid/$notesCollection/${noteToSave.mobileNoteId}/$storageFilename'
            : 'users/$uid/$notesCollection/${noteToSave.mobileNoteId}/audio/'
                '${attachment.recordingId}/segment_${(attachment.segmentIndex ?? 0).toString().padLeft(4, '0')}.m4a';
        debugPrint('attachmentId: ${attachment.mobileAttachmentId}');
        debugPrint('storagePath: $storagePath');

        final file = File(attachment.localPath);
        final metadata = SettableMetadata(contentType: attachment.mimeType);
        await _storage.ref(storagePath).putFile(file, metadata);

        final uploadedAttachment = attachment.copyWith(
          mobileNoteId: noteToSave.mobileNoteId,
          storagePath: storagePath,
          syncStatus: SyncStatus.uploaded,
          importedAt: null,
          clearErrorMessage: true,
        );
        uploadedAttachments.add(uploadedAttachment);
        await onAttachmentUploaded?.call(uploadedAttachment);
      }

      // Commit attachment references and the final note state together. Upload
      // byte progress is deliberately kept out of Firestore.
      final batch = _firestore.batch();
      for (final attachment in uploadedAttachments) {
        final metadata = attachment.toMap()..remove('local_path');
        batch.set(docRef.collection('attachments').doc(attachment.mobileAttachmentId), metadata);
      }
      batch.update(docRef, {
        'sync_status': SyncStatus.uploaded.value,
        'attachments_count': uploadedAttachments.length,
        'recordings': mergeUploadedRecordingMetadata(note.recordings, uploadedAttachments),
        'audio_storage_status': uploadedAttachments.any((item) => item.recordingId != null)
            ? 'uploaded'
            : note.audioStorageStatus,
        'updated_at': DateTime.now().toIso8601String(),
        'error_message': null,
      });
      debugPrint('FIRESTORE_AUDIO_DEBUG: write requested stage=final_metadata_batch');
      await batch.commit();
      debugPrint('FIRESTORE_AUDIO_DEBUG: write completed stage=final_note_update');
    } on FirebaseException catch (error) {
      debugPrint('Error exacto subiendo nota/adjunto: ${error.code} ${error.message}');
      await _markNoteUploadError(docRef, error.message ?? error.toString());
      if (error.code == 'permission-denied' || error.code == 'unauthorized') {
        throw FirebaseSyncException.permissionDenied(error.message);
      }
      if (error.code == 'unavailable' || error.code == 'deadline-exceeded' || error.code == 'retry-limit-exceeded') {
        throw FirebaseSyncException.connection(error.message);
      }
      throw FirebaseSyncException.attachmentUpload(error.message ?? error.toString());
    } catch (error) {
      debugPrint('Error exacto inesperado subiendo adjunto: $error');
      await _markNoteUploadError(docRef, error.toString());
      throw FirebaseSyncException.attachmentUpload(error.toString());
    }
  }

  Future<void> uploadAttachment(MobileAttachment attachment) async {
    throw UnimplementedError('Use createNoteWithAttachments para subir adjuntos de nota.');
  }

  Future<void> _markNoteUploadError(DocumentReference<Map<String, dynamic>> docRef, String errorMessage) async {
    try {
      debugPrint('FIRESTORE_AUDIO_DEBUG: write requested stage=upload_error');
      await docRef.set({
        'sync_status': SyncStatus.error.value,
        'updated_at': DateTime.now().toIso8601String(),
        'error_message': errorMessage,
      }, SetOptions(merge: true));
      debugPrint('FIRESTORE_AUDIO_DEBUG: write completed stage=upload_error');
    } catch (error) {
      debugPrint('No se pudo marcar nota como error: $error');
    }
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
    debugPrint('FIRESTORE_AUDIO_DEBUG: write requested stage=status_update');
    await _firestore.collection(notesCollection).doc(mobileNoteId).update({
      'sync_status': status.value,
      'updated_at': DateTime.now().toIso8601String(),
      'error_message': errorMessage,
    });
    debugPrint('FIRESTORE_AUDIO_DEBUG: write completed stage=status_update');
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

  factory FirebaseSyncException.attachmentUpload(String? details) =>
      FirebaseSyncException._(FirebaseSyncExceptionKind.attachmentUpload, details);

  final FirebaseSyncExceptionKind kind;
  final String? details;

  String get userMessage => switch (kind) {
        FirebaseSyncExceptionKind.permissionDenied => 'No tienes permiso para subir archivos.',
        FirebaseSyncExceptionKind.connection => 'Error de conexión.',
        FirebaseSyncExceptionKind.attachmentUpload => 'No se pudo subir el adjunto.',
        FirebaseSyncExceptionKind.unknown => 'No se pudo guardar la nota',
      };

  @override
  String toString() => 'FirebaseSyncException($kind, $details)';
}

enum FirebaseSyncExceptionKind { permissionDenied, connection, attachmentUpload, unknown }

List<MobileAttachment> attachmentsPendingUpload(List<MobileAttachment> attachments) =>
    attachments
        .where((item) => !item.isUploaded || item.storagePath == null)
        .toList(growable: false);

/// Replaces local-only segment state with authenticated Storage references.
/// Kept pure so retries and desktop-contract serialization can be tested.
List<Map<String, dynamic>> mergeUploadedRecordingMetadata(
  List<Map<String, dynamic>> recordings,
  List<MobileAttachment> attachments,
) {
  return recordings.map((recording) {
    final recordingId = recording['recording_id'] as String?;
    final audio = attachments
        .where((item) => item.recordingId == recordingId)
        .toList()
      ..sort((a, b) => (a.segmentIndex ?? 0).compareTo(b.segmentIndex ?? 0));
    if (audio.isEmpty) return Map<String, dynamic>.from(recording);
    return <String, dynamic>{
      ...recording,
      'upload_status': audio.every((item) => item.isUploaded) ? 'uploaded' : 'failed',
      'segment_count': audio.length,
      'total_size_bytes': audio.fold<int>(0, (sum, item) => sum + item.size),
      'segments': audio.map((item) => <String, dynamic>{
        'index': item.segmentIndex,
        'filename': item.filename,
        'mime_type': item.mimeType,
        'size_bytes': item.size,
        'duration_seconds': item.durationSeconds,
        'storage_path': item.storagePath,
        'upload_status': item.isUploaded ? 'uploaded' : 'failed',
      }).toList(growable: false),
    };
  }).toList(growable: false);
}
