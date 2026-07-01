class TopicMaster {
  const TopicMaster({
    required this.id,
    required this.name,
    this.areaId,
    this.order = 0,
  });

  final String id;
  final String name;
  final String? areaId;
  final int order;

  factory TopicMaster.fromFirestore(String id, Map<String, dynamic> data) {
    return TopicMaster(
      id: id,
      name: _readString(data['name']) ?? '',
      areaId: _readString(data['area_id']) ?? _readString(data['areaId']),
      order: _readOrder(data['order']),
    );
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int _readOrder(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }
}
