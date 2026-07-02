class AppSettings {
  const AppSettings({
    required this.userName,
    required this.keepLocalCopy,
    required this.wifiOnly,
    required this.deleteStorageAfterImport,
    required this.deleteFirestoreAfterImport,
    required this.defaultCaptureMode,
    required this.uploadOriginalCopy,
    required this.imageQuality,
    required this.preferPngForDocuments,
    required this.maxImageLongSide,
  });

  factory AppSettings.defaults() {
    return const AppSettings(
      userName: '',
      keepLocalCopy: true,
      wifiOnly: true,
      deleteStorageAfterImport: false,
      deleteFirestoreAfterImport: false,
      defaultCaptureMode: 'camera',
      uploadOriginalCopy: false,
      imageQuality: 90,
      preferPngForDocuments: false,
      maxImageLongSide: 2500,
    );
  }

  final String userName;
  final bool keepLocalCopy;
  final bool wifiOnly;
  final bool deleteStorageAfterImport;
  final bool deleteFirestoreAfterImport;
  final String defaultCaptureMode;
  final bool uploadOriginalCopy;
  final int imageQuality;
  final bool preferPngForDocuments;
  final int maxImageLongSide;

  Map<String, dynamic> toMap() {
    return {
      'userName': userName,
      'keepLocalCopy': keepLocalCopy,
      'wifiOnly': wifiOnly,
      'deleteStorageAfterImport': deleteStorageAfterImport,
      'deleteFirestoreAfterImport': deleteFirestoreAfterImport,
      'defaultCaptureMode': defaultCaptureMode,
      'uploadOriginalCopy': uploadOriginalCopy,
      'imageQuality': imageQuality,
      'preferPngForDocuments': preferPngForDocuments,
      'maxImageLongSide': maxImageLongSide,
    };
  }

  factory AppSettings.fromMap(Map<String, dynamic> map) {
    return AppSettings(
      userName: map['userName'] as String? ?? '',
      keepLocalCopy: map['keepLocalCopy'] as bool? ?? true,
      wifiOnly: map['wifiOnly'] as bool? ?? true,
      deleteStorageAfterImport: map['deleteStorageAfterImport'] as bool? ?? false,
      deleteFirestoreAfterImport: map['deleteFirestoreAfterImport'] as bool? ?? false,
      defaultCaptureMode: map['defaultCaptureMode'] as String? ?? 'camera',
      uploadOriginalCopy: map['uploadOriginalCopy'] as bool? ?? false,
      imageQuality: map['imageQuality'] as int? ?? 90,
      preferPngForDocuments: map['preferPngForDocuments'] as bool? ?? false,
      maxImageLongSide: map['maxImageLongSide'] as int? ?? 2500,
    );
  }

  AppSettings copyWith({
    String? userName,
    bool? keepLocalCopy,
    bool? wifiOnly,
    bool? deleteStorageAfterImport,
    bool? deleteFirestoreAfterImport,
    String? defaultCaptureMode,
    bool? uploadOriginalCopy,
    int? imageQuality,
    bool? preferPngForDocuments,
    int? maxImageLongSide,
  }) {
    return AppSettings(
      userName: userName ?? this.userName,
      keepLocalCopy: keepLocalCopy ?? this.keepLocalCopy,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      deleteStorageAfterImport:
          deleteStorageAfterImport ?? this.deleteStorageAfterImport,
      deleteFirestoreAfterImport:
          deleteFirestoreAfterImport ?? this.deleteFirestoreAfterImport,
      defaultCaptureMode: defaultCaptureMode ?? this.defaultCaptureMode,
      uploadOriginalCopy: uploadOriginalCopy ?? this.uploadOriginalCopy,
      imageQuality: imageQuality ?? this.imageQuality,
      preferPngForDocuments: preferPngForDocuments ?? this.preferPngForDocuments,
      maxImageLongSide: maxImageLongSide ?? this.maxImageLongSide,
    );
  }
}
