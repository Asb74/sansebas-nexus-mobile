import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:uuid/uuid.dart';

import '../models/mobile_attachment.dart';
import '../models/sync_status.dart';

class DocumentScanSettings {
  const DocumentScanSettings({
    this.imageQuality = 88,
    this.maxImageLongSide = 2500,
  });

  final int imageQuality;
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
    try {
      final attachment = await _scanWithMlKit(mobileNoteId: mobileNoteId);
      if (attachment != null) return attachment;
    } catch (error) {
      debugPrint('No se pudo abrir el escáner avanzado. Se usará fallback. Error exacto: $error');
    }

    return _scanWithImagePickerFallback(mobileNoteId: mobileNoteId);
  }

  Future<MobileAttachment?> _scanWithMlKit({required String mobileNoteId}) async {
    final options = DocumentScannerOptions(
      documentFormats: const {DocumentFormat.jpeg, DocumentFormat.pdf},
      mode: ScannerMode.full,
      pageLimit: 1,
      isGalleryImport: false,
    );
    final scanner = DocumentScanner(options: options);
    try {
      final result = await scanner.scanDocument();
      final scannerPdf = result.pdf;
      final pdfPath = scannerPdf?.uri;
      final imagePaths = result.images;

      if (pdfPath == null || pdfPath.isEmpty) {
        if (imagePaths == null || imagePaths.isEmpty) return null;
        // TODO: google_mlkit_document_scanner 0.4.1 does not expose explicit
        // crop/perspective metadata nor a programmatic manual-border editor.
        // ScannerMode.full opens ML Kit's native UI, where users can crop/edit,
        // but if only an image comes back we cannot prove perspective correction
        // from Dart. Consider a dedicated SDK such as Scanbot SDK or Dynamsoft
        // Document Normalizer if verifiable crop geometry is required.
        return _buildPdfAttachmentFromImage(
          imagePath: imagePaths.first,
          mobileNoteId: mobileNoteId,
          originalFilename: p.basename(imagePaths.first),
          scannerEngine: 'google_mlkit_document_scanner',
          hasPerspectiveCorrection: false,
          hasManualCrop: false,
          generatedPdfByScanner: false,
          optimizedForOcr: false,
          scanMode: 'fallback_photo_pdf',
          fallbackMessage: 'No se pudo realizar escaneo avanzado. Se guardó como PDF de imagen.',
        );
      }

      final attachmentId = _uuid.v4();
      final pdfFile = await _copyPdfToAttachmentFile(
        sourcePath: pdfPath,
        attachmentId: attachmentId,
      );
      final pdfSize = await pdfFile.length();
      final firstImagePath = imagePaths?.isNotEmpty == true ? imagePaths!.first : null;
      final dimensions = firstImagePath == null ? null : img.decodeImage(await File(firstImagePath).readAsBytes());
      final originalSize = firstImagePath == null ? null : await File(firstImagePath).length();

      return MobileAttachment(
        mobileAttachmentId: attachmentId,
        mobileNoteId: mobileNoteId,
        filename: '${attachmentId}_scan.pdf',
        mimeType: 'application/pdf',
        localPath: pdfFile.path,
        size: pdfSize,
        createdAt: DateTime.now(),
        syncStatus: SyncStatus.pending,
        captureMode: 'document_scan',
        optimizedForOcr: true,
        documentFormat: 'pdf',
        originalFilename: firstImagePath == null ? p.basename(pdfFile.path) : p.basename(firstImagePath),
        originalSize: originalSize,
        processedSize: pdfSize,
        imageFormat: firstImagePath == null ? null : _extensionWithoutDot(firstImagePath),
        pageCount: scannerPdf?.pageCount ?? 1,
        scanMode: 'mlkit_document_scanner',
        scannerEngine: 'google_mlkit_document_scanner',
        hasPerspectiveCorrection: true,
        hasManualCrop: true,
        generatedPdfByScanner: true,
        width: dimensions?.width,
        height: dimensions?.height,
      );
    } finally {
      scanner.close();
    }
  }

  Future<MobileAttachment?> _scanWithImagePickerFallback({required String mobileNoteId}) async {
    XFile? capture;
    try {
      capture = await _imagePicker.pickImage(source: ImageSource.camera, imageQuality: 100);
      if (capture == null) return null;
    } catch (error) {
      debugPrint('No se pudo abrir el escáner. Error exacto: $error');
      throw const DocumentScanException('No se pudo abrir el escáner.');
    }

    try {
      return _buildPdfAttachmentFromImage(
        imagePath: capture.path,
        mobileNoteId: mobileNoteId,
        originalFilename: _filenameFor(capture),
        scannerEngine: 'image_picker_camera',
        hasPerspectiveCorrection: false,
        hasManualCrop: false,
        generatedPdfByScanner: false,
        optimizedForOcr: false,
        scanMode: 'fallback_photo_pdf',
        fallbackMessage: 'No se pudo realizar escaneo avanzado. Se guardó como PDF de imagen.',
      );
    } catch (error) {
      debugPrint('No se pudo generar el PDF. Error exacto: $error');
      throw const DocumentScanException('No se pudo generar el PDF.');
    }
  }

  Future<MobileAttachment> _buildPdfAttachmentFromImage({
    required String imagePath,
    required String mobileNoteId,
    required String originalFilename,
    required String scannerEngine,
    required bool hasPerspectiveCorrection,
    required bool hasManualCrop,
    required bool generatedPdfByScanner,
    required bool optimizedForOcr,
    required String scanMode,
    String? fallbackMessage,
  }) async {
    final originalFile = File(imagePath);
    final originalBytes = await originalFile.readAsBytes();
    final decoded = img.decodeImage(originalBytes);
    if (decoded == null) throw const DocumentScanException('No se pudo generar el PDF.');

    var processed = img.bakeOrientation(decoded);
    processed = _resizeIfNeeded(processed);
    processed = img.adjustColor(processed, contrast: 1.12, brightness: 1.02, saturation: 0.92);
    final encoded = Uint8List.fromList(img.encodeJpg(processed, quality: _settings.imageQuality));

    final attachmentId = _uuid.v4();
    final pdfFile = await _writeSinglePagePdf(
      attachmentId: attachmentId,
      imageBytes: encoded,
    );
    final pdfSize = await pdfFile.length();

    return MobileAttachment(
      mobileAttachmentId: attachmentId,
      mobileNoteId: mobileNoteId,
      filename: '${attachmentId}_scan.pdf',
      mimeType: 'application/pdf',
      localPath: pdfFile.path,
      size: pdfSize,
      createdAt: DateTime.now(),
      syncStatus: SyncStatus.pending,
      errorMessage: fallbackMessage,
      captureMode: 'document_scan',
      optimizedForOcr: optimizedForOcr,
      documentFormat: 'pdf',
      originalFilename: originalFilename,
      originalSize: originalBytes.length,
      processedSize: pdfSize,
      imageFormat: _extensionWithoutDot(originalFilename),
      pageCount: 1,
      scanMode: scanMode,
      scannerEngine: scannerEngine,
      hasPerspectiveCorrection: hasPerspectiveCorrection,
      hasManualCrop: hasManualCrop,
      generatedPdfByScanner: generatedPdfByScanner,
      width: processed.width,
      height: processed.height,
    );
  }

  Future<File> _copyPdfToAttachmentFile({required String sourcePath, required String attachmentId}) async {
    final destination = await _attachmentPdfFile(attachmentId);
    final normalizedPath = _normalizeFilePath(sourcePath);
    return File(normalizedPath).copy(destination.path);
  }

  String _normalizeFilePath(String value) {
    final uri = Uri.tryParse(value);
    if (uri != null && uri.scheme == 'file') return uri.toFilePath();
    return value;
  }

  Future<File> _writeSinglePagePdf({required String attachmentId, required Uint8List imageBytes}) async {
    final pdf = pw.Document();
    final image = pw.MemoryImage(imageBytes);
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (_) => pw.Center(
          child: pw.Image(image, fit: pw.BoxFit.contain),
        ),
      ),
    );
    final file = await _attachmentPdfFile(attachmentId);
    return file.writeAsBytes(await pdf.save(), flush: true);
  }

  Future<File> _attachmentPdfFile(String attachmentId) async {
    final directory = await getTemporaryDirectory();
    return File(p.join(directory.path, '${attachmentId}_scan.pdf'));
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
}

class DocumentScanException implements Exception {
  const DocumentScanException(this.message);
  final String message;
  @override
  String toString() => message;
}
