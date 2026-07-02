import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/mobile_attachment.dart';
import '../models/sync_status.dart';

class AttachmentService {
  AttachmentService({ImagePicker? imagePicker}) : _imagePicker = imagePicker ?? ImagePicker();

  final ImagePicker _imagePicker;
  final Uuid _uuid = const Uuid();
  static const int maxAttachmentBytes = 25 * 1024 * 1024;

  Future<MobileAttachment?> pickImageFromCamera({required String mobileNoteId}) async {
    try {
      final file = await _imagePicker.pickImage(source: ImageSource.camera, imageQuality: 85);
      if (file == null) return null;
      return buildMobileAttachmentFromFile(file: file, mobileNoteId: mobileNoteId, captureMode: 'camera');
    } catch (error) {
      debugPrint('No se pudo abrir la cámara. Error exacto: $error');
      throw AttachmentException('No se pudo abrir la cámara.');
    }
  }

  Future<MobileAttachment?> pickImageFromGallery({required String mobileNoteId}) async {
    try {
      final file = await _imagePicker.pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (file == null) return null;
      return buildMobileAttachmentFromFile(file: file, mobileNoteId: mobileNoteId, captureMode: 'gallery');
    } catch (error) {
      debugPrint('No se pudo seleccionar imagen. Error exacto: $error');
      throw AttachmentException('No se pudo seleccionar imagen.');
    }
  }

  Future<MobileAttachment?> pickFile({required String mobileNoteId}) async {
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: false, withData: false);
      final picked = result?.files.single;
      if (picked == null || picked.path == null) return null;
      final detectedMimeType = lookupMimeType(
        picked.path ?? picked.name,
      ) ?? 'application/octet-stream';
      return buildMobileAttachmentFromPath(
        path: picked.path!,
        mobileNoteId: mobileNoteId,
        captureMode: 'file_picker',
        filename: picked.name,
        mimeType: detectedMimeType,
      );
    } on AttachmentException {
      rethrow;
    } catch (error) {
      debugPrint('No se pudo seleccionar archivo. Error exacto: $error');
      throw AttachmentException('No se pudo seleccionar el archivo.');
    }
  }

  Future<void> removePendingAttachment(MobileAttachment attachment) async {
    debugPrint('Adjunto pendiente eliminado: ${attachment.mobileAttachmentId}');
  }

  Future<MobileAttachment> buildMobileAttachmentFromFile({
    required XFile file,
    required String mobileNoteId,
    required String captureMode,
  }) async {
    final filename = p.basename(file.path).trim().isEmpty ? file.name : p.basename(file.path);
    final mimeType = file.mimeType ?? _guessImageMimeType(filename);
    final size = await File(file.path).length();
    _validateAttachment(filename: filename, mimeType: mimeType, size: size);
    return MobileAttachment(
      mobileAttachmentId: _uuid.v4(),
      mobileNoteId: mobileNoteId,
      filename: filename,
      mimeType: mimeType,
      localPath: file.path,
      size: size,
      createdAt: DateTime.now(),
      syncStatus: SyncStatus.pending,
      captureMode: captureMode,
      optimizedForOcr: false,
      originalFilename: filename,
      originalSize: size,
      processedSize: size,
      imageFormat: p.extension(filename).replaceFirst('.', '').toLowerCase(),
    );
  }

  Future<MobileAttachment> buildMobileAttachmentFromPath({
    required String path,
    required String mobileNoteId,
    required String captureMode,
    String? filename,
    String? mimeType,
    String source = 'mobile',
    bool isSharedFile = false,
    int? durationSeconds,
  }) async {
    final resolvedFilename = (filename == null || filename.trim().isEmpty) ? p.basename(path) : filename.trim();
    final resolvedMimeType = mimeType ?? lookupMimeType(path) ?? _guessMimeType(resolvedFilename);
    final size = await File(path).length();
    _validateAttachment(filename: resolvedFilename, mimeType: resolvedMimeType, size: size);
    final extension = p.extension(resolvedFilename).replaceFirst('.', '').toLowerCase();
    return MobileAttachment(
      mobileAttachmentId: _uuid.v4(),
      mobileNoteId: mobileNoteId,
      filename: resolvedFilename,
      mimeType: resolvedMimeType,
      localPath: path,
      size: size,
      createdAt: DateTime.now(),
      syncStatus: SyncStatus.pending,
      captureMode: captureMode,
      optimizedForOcr: false,
      originalFilename: resolvedFilename,
      originalSize: size,
      processedSize: size,
      imageFormat: resolvedMimeType.startsWith('image/') ? extension : null,
      documentFormat: resolvedMimeType == 'application/pdf' ? 'pdf' : null,
      durationSeconds: durationSeconds,
      source: source,
      isSharedFile: isSharedFile,
    );
  }

  void _validateAttachment({required String filename, required String mimeType, required int size}) {
    if (size > maxAttachmentBytes) {
      throw AttachmentException('El archivo supera el límite de 25 MB.');
    }
    if (!_isSupportedMimeType(mimeType, filename)) {
      throw AttachmentException('Archivo no soportado todavía.');
    }
  }

  bool _isSupportedMimeType(String mimeType, String filename) {
    if (mimeType.startsWith('image/') || mimeType.startsWith('audio/')) return true;
    if (mimeType == 'application/pdf' || mimeType == 'application/octet-stream') return true;
    const supported = {
      'text/plain',
      'text/html',
      'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'application/vnd.ms-excel',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'application/vnd.ms-powerpoint',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    };
    return supported.contains(mimeType) || p.extension(filename).isNotEmpty;
  }

  String _guessMimeType(String filename) {
    final extension = p.extension(filename).toLowerCase();
    return switch (extension) {
      '.pdf' => 'application/pdf',
      '.txt' => 'text/plain',
      '.html' || '.htm' => 'text/html',
      '.m4a' => 'audio/mp4',
      '.aac' => 'audio/aac',
      '.jpg' || '.jpeg' || '.png' || '.webp' || '.heic' || '.heif' => _guessImageMimeType(filename),
      _ => 'application/octet-stream',
    };
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
