import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
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
  final _areaController = TextEditingController();
  final _topicController = TextEditingController();
  final _typeController = TextEditingController();
  final _tagsController = TextEditingController();
  final _contentController = TextEditingController();

  @override
  void dispose() {
    _titleController.dispose();
    _areaController.dispose();
    _topicController.dispose();
    _typeController.dispose();
    _tagsController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _showPendingAttachmentMessage() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Función pendiente de implementar en Fase 5'),
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

  void _saveNote() {
    final title = _titleController.text.trim();
    final area = _areaController.text.trim();
    final topic = _topicController.text.trim();
    final type = _typeController.text.trim();
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
      userId: 'local_user_pending_auth',
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Captura rápida para Sansebas Nexus',
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
                  NoteTextField(
                    controller: _areaController,
                    label: 'Área',
                    hintText: 'Ej. Operaciones',
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),
                  NoteTextField(
                    controller: _topicController,
                    label: 'Tema',
                    hintText: 'Ej. Seguimiento semanal',
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),
                  NoteTextField(
                    controller: _typeController,
                    label: 'Tipo',
                    hintText: 'Ej. Nota, idea, tarea',
                    textInputAction: TextInputAction.next,
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
        ),
      ),
    );
  }
}
