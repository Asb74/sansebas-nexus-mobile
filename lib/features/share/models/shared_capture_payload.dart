import 'dart:io';

class SharedCapturePayload {
  const SharedCapturePayload({
    this.text,
    this.subject,
    this.url,
    this.files = const <SharedCaptureFile>[],
    this.mimeTypes = const <String>[],
    required this.receivedAt,
    this.sourceApp,
  });

  final String? text;
  final String? subject;
  final String? url;
  final List<SharedCaptureFile> files;
  final List<String> mimeTypes;
  final DateTime receivedAt;
  final String? sourceApp;

  bool get hasContent =>
      (text?.trim().isNotEmpty ?? false) || files.isNotEmpty || (url?.trim().isNotEmpty ?? false);

  String get suggestedTitle {
    final cleanSubject = subject?.trim();
    if (cleanSubject != null && cleanSubject.isNotEmpty) return cleanSubject;
    if (url != null && url!.isNotEmpty) return 'Enlace compartido';
    if (files.isNotEmpty) return files.length == 1 ? files.first.filename : '${files.length} archivos compartidos';
    return 'Contenido compartido';
  }
}

class SharedCaptureFile {
  const SharedCaptureFile({
    required this.path,
    required this.filename,
    required this.mimeType,
    required this.size,
  });

  final String path;
  final String filename;
  final String mimeType;
  final int size;

  File get file => File(path);
}
