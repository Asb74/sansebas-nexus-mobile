import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/mobile_attachment.dart';
import '../models/sync_status.dart';

class DocumentScanSettings {
  const DocumentScanSettings({
    this.defaultCaptureMode = 'camera',
    this.uploadOriginalCopy = false,
    this.imageQuality = 90,
    this.preferPngForDocuments = false,
    this.maxImageLongSide = 2500,
  });

  final String defaultCaptureMode;
  final bool uploadOriginalCopy;
  final int imageQuality;
  final bool preferPngForDocuments;
  final int maxImageLongSide;
}

class DocumentScanService {
  DocumentScanService({
    ImagePicker? imagePicker,
    DocumentScanSettings settings = const DocumentScanSettings(),
  })  : _imagePicker = imagePicker ?? ImagePicker(),
        _settings = settings;

  final ImagePicker _imagePicker;
  final DocumentScanSettings _settings;
  final Uuid _uuid = const Uuid();

  Future<MobileAttachment?> scanDocument({required String mobileNoteId}) async {
    XFile? capture;
    try {
      capture = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 100,
      );
      if (capture == null) return null;
    } catch (error) {
      debugPrint('No se pudo escanear el documento. Error exacto: $error');
      throw const DocumentScanException('No se pudo escanear el documento.');
    }

    try {
      return await _buildProcessedAttachment(
        capture: capture,
        mobileNoteId: mobileNoteId,
      );
    } catch (error) {
      debugPrint('No se pudo procesar la imagen. Se usará la imagen original. Error exacto: $error');
      return _buildOriginalAttachment(
        capture: capture,
        mobileNoteId: mobileNoteId,
        errorMessage: 'No se pudo procesar la imagen. Se usará la imagen original.',
      );
    }
  }

  Future<MobileAttachment> _buildProcessedAttachment({
    required XFile capture,
    required String mobileNoteId,
  }) async {
    final originalFile = File(capture.path);
    final originalBytes = await originalFile.readAsBytes();
    final decoded = img.decodeImage(originalBytes);
    if (decoded == null) {
      throw const DocumentScanException('No se pudo procesar la imagen.');
    }

    var processed = img.bakeOrientation(decoded);
    processed = _resizeIfNeeded(processed);
    processed = img.grayscale(processed);
    processed = img.adjustColor(processed, contrast: 1.18, brightness: 1.03);

    final usePng = _settings.preferPngForDocuments && processed.width * processed.height <= 2500 * 1800;
    final extension = usePng ? '.png' : '.jpg';
    final imageFormat = usePng ? 'png' : 'jpg';
    final mimeType = usePng ? 'image/png' : 'image/jpeg';
    final encoded = Uint8List.fromList(
      usePng
          ? img.encodePng(processed)
          : img.encodeJpg(processed, quality: _settings.imageQuality),
    );

    final attachmentId = _uuid.v4();
    final processedPath = p.join(
      p.dirname(capture.path),
      '${attachmentId}_document_scan$extension',
    );
    final processedFile = await File(processedPath).writeAsBytes(encoded, flush: true);
    final processedSize = await processedFile.length();

    return MobileAttachment(
      mobileAttachmentId: attachmentId,
      mobileNoteId: mobileNoteId,
      filename: 'document_scan$extension',
      mimeType: mimeType,
      localPath: processedPath,
      size: processedSize,
      createdAt: DateTime.now(),
      syncStatus: SyncStatus.pending,
      captureMode: 'document_scan',
      optimizedForOcr: true,
      originalFilename: _filenameFor(capture),
      originalSize: originalBytes.length,
      processedSize: processedSize,
      imageFormat: imageFormat,
      width: processed.width,
      height: processed.height,
    );
  }

  Future<MobileAttachment> _buildOriginalAttachment({
    required XFile capture,
    required String mobileNoteId,
    required String errorMessage,
  }) async {
    final file = File(capture.path);
    final filename = _filenameFor(capture);
    final size = await file.length();
    final decoded = img.decodeImage(await file.readAsBytes());
    return MobileAttachment(
      mobileAttachmentId: _uuid.v4(),
      mobileNoteId: mobileNoteId,
      filename: filename,
      mimeType: capture.mimeType ?? _guessImageMimeType(filename),
      localPath: capture.path,
      size: size,
      createdAt: DateTime.now(),
      syncStatus: SyncStatus.pending,
      errorMessage: errorMessage,
      captureMode: 'document_scan',
      optimizedForOcr: false,
      originalFilename: filename,
      originalSize: size,
      processedSize: size,
      imageFormat: _extensionWithoutDot(filename),
      width: decoded?.width,
      height: decoded?.height,
    );
  }

  img.Image _resizeIfNeeded(img.Image image) {
    final maxSide = image.width > image.height ? image.width : image.height;
    if (maxSide <= _settings.maxImageLongSide) return image;
    final scale = _settings.maxImageLongSide / maxSide;
    return img.copyResize(
      image,
      width: (image.width * scale).round(),
      height: (image.height * scale).round(),
      interpolation: img.Interpolation.average,
    );
  }

  String _filenameFor(XFile file) => p.basename(file.path).trim().isEmpty ? file.name : p.basename(file.path);

  String _extensionWithoutDot(String filename) => p.extension(filename).replaceFirst('.', '').toLowerCase();

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

class DocumentScanException implements Exception {
  const DocumentScanException(this.message);
  final String message;
  @override
  String toString() => message;
}
