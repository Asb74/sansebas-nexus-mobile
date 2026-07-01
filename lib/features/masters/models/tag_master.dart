class TagMaster {
  const TagMaster({
    required this.id,
    required this.name,
    this.order = 0,
  });

  final String id;
  final String name;
  final int order;
}
