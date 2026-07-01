enum SyncStatus {
  pending,
  uploading,
  uploaded,
  imported,
  error;

  String get value => name;

  bool get isTerminal => this == imported || this == error;

  static SyncStatus fromValue(String? value) {
    return SyncStatus.values.firstWhere(
      (status) => status.value == value,
      orElse: () => SyncStatus.pending,
    );
  }
}
