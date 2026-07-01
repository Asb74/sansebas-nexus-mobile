import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../masters/models/area_master.dart';
import '../../masters/models/note_type_master.dart';
import '../../masters/models/topic_master.dart';
import '../../masters/services/master_service.dart';
import '../models/mobile_note.dart';
import '../models/sync_status.dart';
import '../widgets/attachment_action_button.dart';
import '../widgets/note_text_field.dart';

class NewNoteScreen extends StatefulWidget {
  const NewNoteScreen({super.key});

  @override
  State<NewNoteScreen> createState() => _NewNoteScreenState();
}

class _NewNoteScreenState extends State<NewNoteScreen> {
  final _titleController = TextEditingController();
  final _tagsController = TextEditingController();
  final _contentController = TextEditingController();
  final _masterService = MasterService();

  late final Future<MasterData> _mastersFuture;
  AreaMaster? _selectedArea;
  TopicMaster? _selectedTopic;
  NoteTypeMaster? _selectedType;

  @override
  void initState() {
    super.initState();
    _mastersFuture = _masterService.loadMasters();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _tagsController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _showPendingAttachmentMessage() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Función pendiente de implementar en una fase posterior'),
      ),
    );
  }

  void _showValidationMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  List<String> _parseTags() {
    return _tagsController.text
        .split(',')
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toList(growable: false);
  }

  List<TopicMaster> _topicsForSelectedArea(MasterData masters) {
    final area = _selectedArea;
    if (area == null) return masters.topics;

    final filtered = masters.topics
        .where((topic) => topic.areaId == null || topic.areaId == area.id)
        .toList(growable: false);
    return filtered.isEmpty ? masters.topics : filtered;
  }

  void _saveNote() {
    final title = _titleController.text.trim();
    final area = _selectedArea?.name.trim() ?? '';
    final topic = _selectedTopic?.name.trim() ?? '';
    final type = _selectedType?.name.trim() ?? '';
    final content = _contentController.text.trim();

    if (title.isEmpty) {
      _showValidationMessage('El título es obligatorio.');
      return;
    }
    if (area.isEmpty) {
      _showValidationMessage('El área es obligatoria.');
      return;
    }
    if (topic.isEmpty) {
      _showValidationMessage('El tema es obligatorio.');
      return;
    }
    if (type.isEmpty) {
      _showValidationMessage('El tipo es obligatorio.');
      return;
    }
    if (content.isEmpty) {
      _showValidationMessage('Añade contenido o un adjunto cuando esté disponible.');
      return;
    }

    final now = DateTime.now();
    final note = MobileNote(
      mobileNoteId: now.millisecondsSinceEpoch.toString(),
      title: title,
      area: area,
      topic: topic,
      type: type,
      tags: _parseTags(),
      content: content,
      source: 'mobile',
      createdAt: now,
      updatedAt: now,
      syncStatus: SyncStatus.pending,
      userId: 'firebase_user_pending_note_persistence',
      deviceId: 'local_device_pending',
      attachmentsCount: 0,
    );

    // The note is intentionally kept only in memory until a later persistence phase.
    debugPrint('Nota preparada en memoria: ${note.mobileNoteId}');

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Nota preparada para sincronización')),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Nueva nota')),
      body: SafeArea(
        child: FutureBuilder<MasterData>(
          future: _mastersFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }

            final masters = snapshot.data ?? _masterService.fallbackMasterData;
            _selectedArea ??= masters.areas.firstOrNull;
            _selectedType ??= masters.types.firstOrNull;
            final topics = _topicsForSelectedArea(masters);
            if (_selectedTopic == null || !topics.contains(_selectedTopic)) {
              _selectedTopic = topics.firstOrNull;
            }

            return SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        masters.isFallback
                            ? 'Usando maestros locales mínimos'
                            : 'Captura rápida para Sansebas Nexus',
                        style: textTheme.titleMedium?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 24),
                      NoteTextField(
                        controller: _titleController,
                        label: 'Título',
                        hintText: 'Ej. Reunión con equipo técnico',
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 16),
                      _MasterDropdown<AreaMaster>(
                        label: 'Área',
                        value: _selectedArea,
                        items: masters.areas,
                        itemLabel: (area) => area.name,
                        onChanged: (area) => setState(() {
                          _selectedArea = area;
                          _selectedTopic = null;
                        }),
                      ),
                      const SizedBox(height: 16),
                      _MasterDropdown<TopicMaster>(
                        label: 'Tema',
                        value: _selectedTopic,
                        items: topics,
                        itemLabel: (topic) => topic.name,
                        onChanged: (topic) => setState(() => _selectedTopic = topic),
                      ),
                      const SizedBox(height: 16),
                      _MasterDropdown<NoteTypeMaster>(
                        label: 'Tipo',
                        value: _selectedType,
                        items: masters.types,
                        itemLabel: (type) => type.name,
                        onChanged: (type) => setState(() => _selectedType = type),
                      ),
                      const SizedBox(height: 16),
                      NoteTextField(
                        controller: _tagsController,
                        label: 'Etiquetas',
                        hintText: 'Separadas por comas: urgente, cliente, revisión',
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 16),
                      NoteTextField(
                        controller: _contentController,
                        label: 'Contenido',
                        hintText: 'Escribe aquí la nota...',
                        keyboardType: TextInputType.multiline,
                        minLines: 5,
                        maxLines: 10,
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Adjuntos',
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          AttachmentActionButton(
                            icon: Icons.photo_camera_outlined,
                            label: 'Cámara',
                            onPressed: _showPendingAttachmentMessage,
                          ),
                          AttachmentActionButton(
                            icon: Icons.photo_library_outlined,
                            label: 'Galería',
                            onPressed: _showPendingAttachmentMessage,
                          ),
                          AttachmentActionButton(
                            icon: Icons.mic_none_outlined,
                            label: 'Audio',
                            onPressed: _showPendingAttachmentMessage,
                          ),
                          AttachmentActionButton(
                            icon: Icons.attach_file_outlined,
                            label: 'Archivo',
                            onPressed: _showPendingAttachmentMessage,
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),
                      FilledButton.icon(
                        onPressed: _saveNote,
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text('Guardar nota'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_outlined),
                        label: const Text('Cancelar'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MasterDropdown<T> extends StatelessWidget {
  const _MasterDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.itemLabel,
    required this.onChanged,
  });

  final String label;
  final T? value;
  final List<T> items;
  final String Function(T item) itemLabel;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      value: value,
      items: items
          .map(
            (item) => DropdownMenuItem<T>(
              value: item,
              child: Text(itemLabel(item)),
            ),
          )
          .toList(growable: false),
      onChanged: items.isEmpty ? null : onChanged,
      decoration: InputDecoration(labelText: label),
      validator: (item) => item == null ? 'Selecciona $label.' : null,
    );
  }
}
