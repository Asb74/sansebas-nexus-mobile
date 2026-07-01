class AppSettings {
  const AppSettings({
    required this.userName,
    required this.keepLocalCopy,
    required this.wifiOnly,
    required this.deleteStorageAfterImport,
    required this.deleteFirestoreAfterImport,
  });

  factory AppSettings.defaults() {
    return const AppSettings(
      userName: '',
      keepLocalCopy: true,
      wifiOnly: true,
      deleteStorageAfterImport: false,
      deleteFirestoreAfterImport: false,
    );
  }

  final String userName;
  final bool keepLocalCopy;
  final bool wifiOnly;
  final bool deleteStorageAfterImport;
  final bool deleteFirestoreAfterImport;

  Map<String, dynamic> toMap() {
    return {
      'userName': userName,
      'keepLocalCopy': keepLocalCopy,
      'wifiOnly': wifiOnly,
      'deleteStorageAfterImport': deleteStorageAfterImport,
      'deleteFirestoreAfterImport': deleteFirestoreAfterImport,
    };
  }

  factory AppSettings.fromMap(Map<String, dynamic> map) {
    return AppSettings(
      userName: map['userName'] as String? ?? '',
      keepLocalCopy: map['keepLocalCopy'] as bool? ?? true,
      wifiOnly: map['wifiOnly'] as bool? ?? true,
      deleteStorageAfterImport: map['deleteStorageAfterImport'] as bool? ?? false,
      deleteFirestoreAfterImport: map['deleteFirestoreAfterImport'] as bool? ?? false,
    );
  }

  AppSettings copyWith({
    String? userName,
    bool? keepLocalCopy,
    bool? wifiOnly,
    bool? deleteStorageAfterImport,
    bool? deleteFirestoreAfterImport,
  }) {
    return AppSettings(
      userName: userName ?? this.userName,
      keepLocalCopy: keepLocalCopy ?? this.keepLocalCopy,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      deleteStorageAfterImport:
          deleteStorageAfterImport ?? this.deleteStorageAfterImport,
      deleteFirestoreAfterImport:
          deleteFirestoreAfterImport ?? this.deleteFirestoreAfterImport,
    );
  }
}
