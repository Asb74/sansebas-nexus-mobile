import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/area_master.dart';
import '../models/note_type_master.dart';
import '../models/tag_master.dart';
import '../models/topic_master.dart';

class MasterService {
  MasterService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  static MasterData? _cachedMasterData;

  MasterData get fallbackMasterData => const MasterData(
        areas: [AreaMaster(id: 'general', name: 'General')],
        topics: [TopicMaster(id: 'general', name: 'General')],
        types: [NoteTypeMaster(id: 'nota', name: 'Nota')],
        tags: [],
        isFallback: true,
      );

  MasterData? get cachedMasterData => _cachedMasterData;

  Future<MasterData> loadMasters({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedMasterData != null) {
      return _cachedMasterData!;
    }

    try {
      final areas = await _loadCollection<AreaMaster>(
        'areas',
        (id, data) => AreaMaster(
          id: id,
          name: _readName(data),
          order: _readOrder(data),
        ),
      );
      final topics = await _loadCollection<TopicMaster>(
        'topics',
        (id, data) => TopicMaster(
          id: id,
          name: _readName(data),
          areaId: _readNullableString(data['areaId']),
          order: _readOrder(data),
        ),
      );
      final types = await _loadCollection<NoteTypeMaster>(
        'types',
        (id, data) => NoteTypeMaster(
          id: id,
          name: _readName(data),
          order: _readOrder(data),
        ),
      );
      final tags = await _loadCollection<TagMaster>(
        'tags',
        (id, data) => TagMaster(
          id: id,
          name: _readName(data),
          order: _readOrder(data),
        ),
      );

      if (areas.isEmpty || topics.isEmpty || types.isEmpty) {
        _cachedMasterData = fallbackMasterData;
        return _cachedMasterData!;
      }

      _cachedMasterData = MasterData(
        areas: areas,
        topics: topics,
        types: types,
        tags: tags,
      );
      return _cachedMasterData!;
    } catch (_) {
      _cachedMasterData = fallbackMasterData;
      return _cachedMasterData!;
    }
  }

  Future<List<T>> _loadCollection<T extends Object>(
    String masterId,
    T Function(String id, Map<String, dynamic> data) mapper,
  ) async {
    final snapshot = await _firestore
        .collection('nexus_masters')
        .doc(masterId)
        .collection('items')
        .where('active', isEqualTo: true)
        .get();

    final items = snapshot.docs
        .map((doc) => mapper(doc.id, doc.data()))
        .where((item) => _hasName(item))
        .toList(growable: false);
    items.sort(_compareMasterItems);
    return items;
  }

  static int _compareMasterItems<T extends Object>(T a, T b) {
    final orderComparison = _itemOrder(a).compareTo(_itemOrder(b));
    if (orderComparison != 0) return orderComparison;
    return _itemName(a).compareTo(_itemName(b));
  }

  static int _itemOrder(Object item) {
    return switch (item) {
      AreaMaster(:final order) => order,
      TopicMaster(:final order) => order,
      NoteTypeMaster(:final order) => order,
      TagMaster(:final order) => order,
      _ => 0,
    };
  }

  static String _itemName(Object item) {
    return switch (item) {
      AreaMaster(:final name) => name,
      TopicMaster(:final name) => name,
      NoteTypeMaster(:final name) => name,
      TagMaster(:final name) => name,
      _ => '',
    };
  }

  static bool _hasName<T extends Object>(T item) {
    return switch (item) {
      AreaMaster(:final name) => name.isNotEmpty,
      TopicMaster(:final name) => name.isNotEmpty,
      NoteTypeMaster(:final name) => name.isNotEmpty,
      TagMaster(:final name) => name.isNotEmpty,
      _ => true,
    };
  }

  static String _readName(Map<String, dynamic> data) {
    return _readNullableString(data['name']) ?? '';
  }

  static int _readOrder(Map<String, dynamic> data) {
    final value = data['order'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }

  static String? _readNullableString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class MasterData {
  const MasterData({
    required this.areas,
    required this.topics,
    required this.types,
    required this.tags,
    this.isFallback = false,
  });

  final List<AreaMaster> areas;
  final List<TopicMaster> topics;
  final List<NoteTypeMaster> types;
  final List<TagMaster> tags;
  final bool isFallback;
}
