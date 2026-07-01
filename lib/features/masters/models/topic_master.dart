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
}
