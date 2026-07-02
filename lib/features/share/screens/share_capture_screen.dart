import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../core/theme/app_colors.dart';
import '../../masters/models/area_master.dart';
import '../../masters/models/note_type_master.dart';
import '../../masters/models/topic_master.dart';
import '../../masters/services/master_service.dart';
import '../../notes/models/mobile_attachment.dart';
import '../../notes/models/mobile_note.dart';
import '../../notes/models/sync_status.dart';
import '../../notes/services/attachment_service.dart';
import '../../notes/services/firebase_sync_service.dart';
import '../../notes/widgets/note_text_field.dart';
import '../models/shared_capture_payload.dart';

class ShareCaptureScreen extends StatefulWidget {
  const ShareCaptureScreen({super.key, required this.payload});

  final SharedCapturePayload payload;

  @override
  State<ShareCaptureScreen> createState() => _ShareCaptureScreenState();
}

class _ShareCaptureScreenState extends State<ShareCaptureScreen> {
  final _titleController = TextEditingController();
  final _tagsController = TextEditingController(text: 'share');
  final _contentController = TextEditingController();
  final _masterService = MasterService();
  final _firebaseSyncService = FirebaseSyncService();
  final _attachmentService = AttachmentService();
  final _uuid = const Uuid();

  late final Future<MasterData> _mastersFuture;
  late final String _draftMobileNoteId;
  final List<MobileAttachment> _pendingAttachments = <MobileAttachment>[];
  AreaMaster? _selectedArea;
  TopicMaster? _selectedTopic;
  NoteTypeMaster? _selectedType;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _mastersFuture = _masterService.loadMasters();
    _draftMobileNoteId = _uuid.v4();
    _titleController.text = widget.payload.suggestedTitle;
    _contentController.text = [
      if (widget.payload.text?.trim().isNotEmpty ?? false) widget.payload.text!.trim(),
      if (widget.payload.url?.trim().isNotEmpty ?? false && widget.payload.text?.contains(widget.payload.url!) != true)
        widget.payload.url!.trim(),
    ].join('\n');
    _buildSharedAttachments();
  }

  Future<void> _buildSharedAttachments() async {
    for (final file in widget.payload.files) {
      try {
        final attachment = await _attachmentService.buildMobileAttachmentFromPath(
          path: file.path,
          mobileNoteId: _draftMobileNoteId,
          captureMode: 'android_share',
          filename: file.filename,
          mimeType: file.mimeType,
          source: 'share',
          isSharedFile: true,
        );
        if (mounted) setState(() => _pendingAttachments.add(attachment));
      } on AttachmentException catch (error) {
        if (mounted) _showMessage('${file.filename}: ${error.message}');
      }
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _tagsController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  List<String> _parseTags() => _tagsController.text.split(',').map((tag) => tag.trim()).where((tag) => tag.isNotEmpty).toList();

  List<TopicMaster> _topicsForSelectedArea(MasterData masters) {
    final area = _selectedArea;
    if (area == null) return masters.topics;
    final filtered = masters.topics.where((topic) => topic.areaId == area.id).toList(growable: false);
    if (filtered.isNotEmpty) return filtered;
    return masters.topics.where((topic) => topic.name.trim().toLowerCase() == 'general').toList(growable: false);
  }

  Future<void> _save() async {
    if (_isSaving) return;
    final title = _titleController.text.trim();
    final area = _selectedArea;
    final topic = _selectedTopic;
    final type = _selectedType;
    final content = _contentController.text.trim();
    if (title.isEmpty || area == null || topic == null || type == null) {
      _showMessage('Completa título, área, tema y tipo.');
      return;
    }
    if (content.isEmpty && _pendingAttachments.isEmpty) {
      _showMessage('No hay contenido para guardar.');
      return;
    }
    final uid = _firebaseSyncService.currentUserId;
    if (uid == null || uid.isEmpty) {
      _showMessage('No tienes permiso para guardar notas');
      return;
    }
    setState(() => _isSaving = true);
    final now = DateTime.now();
    final note = MobileNote(
      mobileNoteId: _draftMobileNoteId,
      title: title,
      areaId: area.id,
      area: area.name,
      topicId: topic.id,
      topic: topic.name,
      typeId: type.id,
      type: type.name,
      tags: _parseTags(),
      content: content,
      source: 'android_share',
      createdAt: now,
      updatedAt: now,
      syncStatus: _pendingAttachments.isEmpty ? SyncStatus.uploaded : SyncStatus.pending,
      userId: uid,
      deviceId: await _firebaseSyncService.readDeviceId(),
      attachmentsCount: _pendingAttachments.length,
    );
    try {
      await _firebaseSyncService.createNoteWithAttachments(note: note, attachments: _pendingAttachments);
      if (!mounted) return;
      _showMessage('Contenido compartido guardado en Nexus');
      Navigator.pop(context);
    } on FirebaseSyncException catch (error) {
      if (mounted) _showMessage(error.userMessage);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showMessage(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Captura compartida')),
      body: SafeArea(
        child: FutureBuilder<MasterData>(
          future: _mastersFuture,
          builder: (context, snapshot) {
            final masters = snapshot.data ?? _masterService.fallbackMasterData;
            _selectedArea ??= masters.areas.firstOrNull;
            _selectedType ??= masters.types.firstOrNull;
            final topics = _topicsForSelectedArea(masters);
            if (_selectedTopic == null || !topics.contains(_selectedTopic)) _selectedTopic = topics.firstOrNull;
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text('Origen: share', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: AppColors.textSecondary)),
                const SizedBox(height: 16),
                NoteTextField(controller: _titleController, label: 'Título sugerido'),
                const SizedBox(height: 16),
                _MasterDropdown(label: 'Área', value: _selectedArea, items: masters.areas, itemLabel: (a) => a.name, onChanged: (v) => setState(() => _selectedArea = v)),
                const SizedBox(height: 16),
                _MasterDropdown(label: 'Tema', value: _selectedTopic, items: topics, itemLabel: (t) => t.name, onChanged: (v) => setState(() => _selectedTopic = v)),
                const SizedBox(height: 16),
                _MasterDropdown(label: 'Tipo', value: _selectedType, items: masters.types, itemLabel: (t) => t.name, onChanged: (v) => setState(() => _selectedType = v)),
                const SizedBox(height: 16),
                NoteTextField(controller: _tagsController, label: 'Etiquetas'),
                const SizedBox(height: 16),
                NoteTextField(controller: _contentController, label: 'Contenido', keyboardType: TextInputType.multiline, minLines: 5, maxLines: 10),
                const SizedBox(height: 20),
                Text('Adjuntos recibidos', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (_pendingAttachments.isEmpty) const Text('Sin adjuntos.') else ..._pendingAttachments.map((a) => Card(child: ListTile(leading: const Icon(Icons.attach_file), title: Text(a.filename), subtitle: Text('${a.mimeType} · ${_formatBytes(a.size)}')))),
                const SizedBox(height: 24),
                FilledButton.icon(onPressed: _isSaving ? null : _save, icon: const Icon(Icons.cloud_upload_outlined), label: Text(_isSaving ? 'Guardando...' : 'Guardar en Nexus')),
                const SizedBox(height: 12),
                OutlinedButton.icon(onPressed: _isSaving ? null : () => Navigator.pop(context), icon: const Icon(Icons.close), label: const Text('Cancelar')),
              ],
            );
          },
        ),
      ),
    );
  }

  String _formatBytes(int bytes) => bytes < 1024 ? '$bytes B' : bytes < 1048576 ? '${(bytes / 1024).toStringAsFixed(1)} KB' : '${(bytes / 1048576).toStringAsFixed(1)} MB';
}

class _MasterDropdown<T> extends StatelessWidget {
  const _MasterDropdown({required this.label, required this.value, required this.items, required this.itemLabel, required this.onChanged});
  final String label;
  final T? value;
  final List<T> items;
  final String Function(T item) itemLabel;
  final ValueChanged<T?>? onChanged;
  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(value: value, items: items.map((item) => DropdownMenuItem<T>(value: item, child: Text(itemLabel(item)))).toList(), onChanged: onChanged, decoration: InputDecoration(labelText: label));
}
