import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/mobile_attachment.dart';
import '../models/sync_status.dart';

class AttachmentService {
  AttachmentService({ImagePicker? imagePicker}) : _imagePicker = imagePicker ?? ImagePicker();

  final ImagePicker _imagePicker;
  final Uuid _uuid = const Uuid();

  Future<MobileAttachment?> pickImageFromCamera({required String mobileNoteId}) async {
    try {
      final file = await _imagePicker.pickImage(source: ImageSource.camera, imageQuality: 85);
      if (file == null) return null;
      return buildMobileAttachmentFromFile(file: file, mobileNoteId: mobileNoteId);
    } catch (error) {
      debugPrint('No se pudo abrir la cámara. Error exacto: $error');
      throw AttachmentException('No se pudo abrir la cámara.');
    }
  }

  Future<MobileAttachment?> pickImageFromGallery({required String mobileNoteId}) async {
    try {
      final file = await _imagePicker.pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (file == null) return null;
      return buildMobileAttachmentFromFile(file: file, mobileNoteId: mobileNoteId);
    } catch (error) {
      debugPrint('No se pudo seleccionar imagen. Error exacto: $error');
      throw AttachmentException('No se pudo seleccionar imagen.');
    }
  }

  Future<void> removePendingAttachment(MobileAttachment attachment) async {
    debugPrint('Adjunto pendiente eliminado: ${attachment.mobileAttachmentId}');
  }

  Future<MobileAttachment> buildMobileAttachmentFromFile({
    required XFile file,
    required String mobileNoteId,
  }) async {
    final filename = p.basename(file.path).trim().isEmpty ? file.name : p.basename(file.path);
    final mimeType = file.mimeType ?? _guessImageMimeType(filename);
    final size = await File(file.path).length();
    return MobileAttachment(
      mobileAttachmentId: _uuid.v4(),
      mobileNoteId: mobileNoteId,
      filename: filename,
      mimeType: mimeType,
      localPath: file.path,
      size: size,
      createdAt: DateTime.now(),
      syncStatus: SyncStatus.pending,
    );
  }

  String _guessImageMimeType(String filename) {
    final extension = p.extension(filename).toLowerCase();
    return switch (extension) {
      '.png' => 'image/png',
      '.webp' => 'image/webp',
      '.heic' => 'image/heic',
      '.heif' => 'image/heif',
      _ => 'image/jpeg',
    };
  }
}

class AttachmentException implements Exception {
  const AttachmentException(this.message);
  final String message;
  @override
  String toString() => message;
}
