import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../core/theme/app_colors.dart';
import '../../masters/models/area_master.dart';
import '../../masters/models/note_type_master.dart';
import '../../masters/models/topic_master.dart';
import '../../masters/services/master_service.dart';
import '../models/mobile_attachment.dart';
import '../models/mobile_note.dart';
import '../models/sync_status.dart';
import '../services/attachment_service.dart';
import '../services/firebase_sync_service.dart';
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
  final _firebaseSyncService = FirebaseSyncService();
  final _attachmentService = AttachmentService();
  final _uuid = const Uuid();

  late final Future<MasterData> _mastersFuture;
  AreaMaster? _selectedArea;
  TopicMaster? _selectedTopic;
  NoteTypeMaster? _selectedType;
  bool _isSaving = false;
  late String _draftMobileNoteId;
  final List<MobileAttachment> _pendingAttachments = <MobileAttachment>[];

  @override
  void initState() {
    super.initState();
    _mastersFuture = _masterService.loadMasters();
    _draftMobileNoteId = _uuid.v4();
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


  Future<void> _pickImageFromCamera() async {
    if (_isSaving) return;
    try {
      final attachment = await _attachmentService.pickImageFromCamera(
        mobileNoteId: _draftMobileNoteId,
      );
      if (attachment == null || !mounted) return;
      setState(() => _pendingAttachments.add(attachment));
    } on AttachmentException catch (error) {
      if (!mounted) return;
      _showValidationMessage(error.message);
    } catch (error) {
      debugPrint('No se pudo abrir la cámara. Error exacto: $error');
      if (!mounted) return;
      _showValidationMessage('No se pudo abrir la cámara.');
    }
  }

  Future<void> _pickImageFromGallery() async {
    if (_isSaving) return;
    try {
      final attachment = await _attachmentService.pickImageFromGallery(
        mobileNoteId: _draftMobileNoteId,
      );
      if (attachment == null || !mounted) return;
      setState(() => _pendingAttachments.add(attachment));
    } on AttachmentException catch (error) {
      if (!mounted) return;
      _showValidationMessage(error.message);
    } catch (error) {
      debugPrint('No se pudo seleccionar imagen. Error exacto: $error');
      if (!mounted) return;
      _showValidationMessage('No se pudo seleccionar imagen.');
    }
  }

  Future<void> _removeAttachment(MobileAttachment attachment) async {
    await _attachmentService.removePendingAttachment(attachment);
    if (!mounted) return;
    setState(() => _pendingAttachments.remove(attachment));
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
        .where((topic) => topic.areaId == area.id)
        .toList(growable: false);
    if (filtered.isNotEmpty) return filtered;

    final generalTopics = masters.topics
        .where((topic) => topic.name.trim().toLowerCase() == 'general')
        .toList(growable: false);
    return generalTopics;
  }

  Future<void> _saveNote() async {
    if (_isSaving) return;

    final title = _titleController.text.trim();
    final area = _selectedArea;
    final topic = _selectedTopic;
    final type = _selectedType;
    final content = _contentController.text.trim();

    if (title.isEmpty) {
      _showValidationMessage('El título es obligatorio.');
      return;
    }
    if (area == null) {
      _showValidationMessage('El área es obligatoria.');
      return;
    }
    if (topic == null) {
      _showValidationMessage('El tema es obligatorio.');
      return;
    }
    if (type == null) {
      _showValidationMessage('El tipo es obligatorio.');
      return;
    }
    if (content.isEmpty && _pendingAttachments.isEmpty) {
      _showValidationMessage('Escribe contenido o añade al menos un adjunto.');
      return;
    }

    final uid = _firebaseSyncService.currentUserId;
    if (uid == null || uid.isEmpty) {
      _showValidationMessage('No tienes permiso para guardar notas');
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
      source: 'mobile',
      createdAt: now,
      updatedAt: now,
      syncStatus: _pendingAttachments.isEmpty ? SyncStatus.uploaded : SyncStatus.pending,
      userId: uid,
      deviceId: await _firebaseSyncService.readDeviceId(),
      attachmentsCount: _pendingAttachments.length,
    );

    try {
      if (_pendingAttachments.isEmpty) {
        await _firebaseSyncService.createTextNote(note);
      } else {
        await _firebaseSyncService.createNoteWithAttachments(
          note: note,
          attachments: List<MobileAttachment>.unmodifiable(_pendingAttachments),
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nota guardada para sincronización')),
      );
      Navigator.pop(context);
    } on FirebaseSyncException catch (error) {
      debugPrint('Error controlado guardando nota: $error');
      if (!mounted) return;
      _showValidationMessage(error.userMessage);
    } catch (error) {
      debugPrint('Error no controlado guardando nota: $error');
      if (!mounted) return;
      _showValidationMessage('No se pudo guardar la nota');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
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
                        onChanged: _isSaving ? null : (area) => setState(() {
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
                        onChanged: _isSaving
                            ? null
                            : (topic) => setState(() => _selectedTopic = topic),
                      ),
                      const SizedBox(height: 16),
                      _MasterDropdown<NoteTypeMaster>(
                        label: 'Tipo',
                        value: _selectedType,
                        items: masters.types,
                        itemLabel: (type) => type.name,
                        onChanged: _isSaving
                            ? null
                            : (type) => setState(() => _selectedType = type),
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
                            onPressed: _isSaving ? null : _pickImageFromCamera,
                          ),
                          AttachmentActionButton(
                            icon: Icons.photo_library_outlined,
                            label: 'Galería',
                            onPressed: _isSaving ? null : _pickImageFromGallery,
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
                      const SizedBox(height: 16),
                      _AttachmentsPreview(
                        attachments: _pendingAttachments,
                        onRemove: _isSaving ? null : _removeAttachment,
                      ),
                      const SizedBox(height: 32),
                      FilledButton.icon(
                        onPressed: _isSaving ? null : _saveNote,
                        icon: _isSaving
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.check_circle_outline),
                        label: Text(_isSaving ? 'Guardando...' : 'Guardar nota'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _isSaving ? null : () => Navigator.pop(context),
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


class _AttachmentsPreview extends StatelessWidget {
  const _AttachmentsPreview({
    required this.attachments,
    required this.onRemove,
  });

  final List<MobileAttachment> attachments;
  final ValueChanged<MobileAttachment>? onRemove;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) {
      return Text(
        'Sin adjuntos seleccionados.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppColors.textSecondary,
            ),
      );
    }

    return Column(
      children: attachments
          .map(
            (attachment) => Card(
              child: ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(attachment.localPath),
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined),
                  ),
                ),
                title: Text(
                  attachment.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(_formatBytes(attachment.size)),
                trailing: IconButton(
                  tooltip: 'Eliminar adjunto',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: onRemove == null ? null : () => onRemove!(attachment),
                ),
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
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
  final ValueChanged<T?>? onChanged;

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
