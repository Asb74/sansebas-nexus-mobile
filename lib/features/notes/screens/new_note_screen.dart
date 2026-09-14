import 'dart:async';
import 'dart:io';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:record/record.dart';
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
import '../services/document_scan_service.dart';
import '../services/firebase_sync_service.dart';
import '../widgets/attachment_action_button.dart';
import '../widgets/note_text_field.dart';
import '../../voice/models/recording_session.dart';
import '../../voice/services/audio_transcription_service.dart';
import '../../voice/services/recording_session_store.dart';
import '../../voice/services/safe_audio_recorder.dart';

enum _AudioCaptureStatus { idle, recording, transcribing, completed, failed }

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
  final _documentScanService = DocumentScanService();
  final _uuid = const Uuid();
  final _audioRecorder = AudioRecorder();
  final _recordingStore = RecordingSessionStore();
  late final SafeAudioRecorder _safeAudioRecorder;
  late final HttpAudioSegmentTranscriber _fileAudioTranscriber;
  late final AudioTranscriptionService _audioTranscriptionService;

  late final Future<MasterData> _mastersFuture;
  AreaMaster? _selectedArea;
  TopicMaster? _selectedTopic;
  NoteTypeMaster? _selectedType;
  bool _isSaving = false;
  _AudioCaptureStatus _audioStatus = _AudioCaptureStatus.idle;
  final Stopwatch _audioStopwatch = Stopwatch();
  Timer? _audioTimer;
  Duration _audioElapsed = Duration.zero;
  RecordingSession? _lastRecordingSession;
  late String _draftMobileNoteId;
  final List<MobileAttachment> _pendingAttachments = <MobileAttachment>[];

  bool get _isAudioBusy =>
      _audioStatus == _AudioCaptureStatus.recording ||
      _audioStatus == _AudioCaptureStatus.transcribing;

  @override
  void initState() {
    super.initState();
    _mastersFuture = _masterService.loadMasters();
    _draftMobileNoteId = _uuid.v4();
    _safeAudioRecorder = SafeAudioRecorder(
      store: _recordingStore,
      recorder: RecordAudioRecorderAdapter(_audioRecorder),
    );
    _fileAudioTranscriber = HttpAudioSegmentTranscriber();
    _audioTranscriptionService = AudioTranscriptionService(
      store: _recordingStore,
      transcriber: _fileAudioTranscriber,
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _tagsController.dispose();
    _audioTimer?.cancel();
    _audioStopwatch.stop();
    _audioRecorder.dispose();
    _contentController.dispose();
    super.dispose();
  }


  Future<void> _pickFile() async {
    if (_isSaving) return;
    try {
      final attachment = await _attachmentService.pickFile(mobileNoteId: _draftMobileNoteId);
      if (attachment == null || !mounted) return;
      setState(() => _pendingAttachments.add(attachment));
    } on AttachmentException catch (error) {
      if (!mounted) return;
      _showValidationMessage(error.message);
    } catch (error) {
      debugPrint('No se pudo seleccionar archivo. Error exacto: $error');
      if (!mounted) return;
      _showValidationMessage('No se pudo seleccionar el archivo.');
    }
  }

  Future<void> _toggleAudioRecording() async {
    if (_isSaving) return;
    if (_audioStatus == _AudioCaptureStatus.recording) {
      await _stopAudioRecording();
      return;
    }

    try {
      await _safeAudioRecorder.start();
      if (!mounted) return;
      _audioStopwatch
        ..reset()
        ..start();
      _audioTimer?.cancel();
      _audioTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _audioElapsed = _audioStopwatch.elapsed);
      });
      setState(() {
        _audioStatus = _AudioCaptureStatus.recording;
        _audioElapsed = Duration.zero;
      });
    } catch (error) {
      debugPrint('No se pudo iniciar la grabación. Error exacto: $error');
      if (!mounted) return;
      _showValidationMessage('No se pudo iniciar la grabación de audio.');
    }
  }

  Future<void> _stopAudioRecording() async {
    _audioTimer?.cancel();
    _audioStopwatch.stop();
    if (mounted) {
      setState(() {
        _audioElapsed = _audioStopwatch.elapsed;
        _audioStatus = _AudioCaptureStatus.transcribing;
      });
    }
    try {
      // The recorder is the only microphone consumer. This await finalizes and
      // validates every local M4A before any HTTP transcription can start.
      final session = await _safeAudioRecorder.stop();
      _lastRecordingSession = session;
      await _addAudioAttachments(session);
      final completed = await _audioTranscriptionService.transcribe(session);
      _lastRecordingSession = completed;
      if (completed.status != RecordingSessionStatus.ready) {
        throw const AudioTranscriptionException('recoverable_transcription_error');
      }
      if (!mounted) return;
      setState(() {
        _lastRecordingSession = completed;
        _audioStatus = _AudioCaptureStatus.completed;
        _applyTranscriptionToContent(completed.transcription);
      });
      _showValidationMessage('✓ Transcripción completada');
    } catch (error, stackTrace) {
      debugPrint('No se pudo completar la transcripción. Error exacto: $error');
      debugPrint('AUDIO_TRANSCRIPTION: exception type=${error.runtimeType}');
      debugPrint('AUDIO_TRANSCRIPTION: exception message=$error');
      debugPrint('AUDIO_TRANSCRIPTION: stacktrace=$stackTrace');
      if (!mounted) return;
      setState(() => _audioStatus = _AudioCaptureStatus.failed);
    }
  }

  Future<void> _addAudioAttachments(RecordingSession session) async {
    for (final segment in session.segments) {
      final attachment = await _attachmentService.buildMobileAttachmentFromPath(
        path: segment.localAudioPath,
        mobileNoteId: _draftMobileNoteId,
        captureMode: 'audio',
        filename: 'audio_${DateTime.now().millisecondsSinceEpoch}_${segment.index + 1}.m4a',
        mimeType: 'audio/mp4',
        durationSeconds: segment.durationSeconds,
      );
      if (mounted) setState(() => _pendingAttachments.add(attachment));
    }
  }

  void _applyTranscriptionToContent(String transcription) {
    debugPrint('NOTE_CONTENT: transcription applied chars=${transcription.trim().length}');
    _contentController.text = transcription.trim();
    _contentController.selection = TextSelection.collapsed(offset: _contentController.text.length);
    debugPrint('NOTE_CONTENT: field updated successfully');
  }

  Future<void> _retryTranscription() async {
    final session = _lastRecordingSession;
    if (session == null) return;
    debugPrint('AUDIO_TRANSCRIPTION: retry requested');
    for (final segment in session.segments) {
      final file = File(segment.localAudioPath);
      final exists = await file.exists();
      final size = exists ? await file.length() : 0;
      debugPrint('AUDIO_TRANSCRIPTION: retry path=${segment.localAudioPath}');
      debugPrint('AUDIO_TRANSCRIPTION: retry file_exists=$exists');
      debugPrint('AUDIO_TRANSCRIPTION: retry size_bytes=$size');
    }
    setState(() => _audioStatus = _AudioCaptureStatus.transcribing);
    try {
      final result = await _audioTranscriptionService.transcribe(session);
      if (!mounted) return;
      if (result.status != RecordingSessionStatus.ready || result.transcription.isEmpty) {
        setState(() => _audioStatus = _AudioCaptureStatus.failed);
        return;
      }
      setState(() {
        _lastRecordingSession = result;
        _audioStatus = _AudioCaptureStatus.completed;
        _applyTranscriptionToContent(result.transcription);
      });
    } catch (error, stackTrace) {
      debugPrint('AUDIO_TRANSCRIPTION: exception type=${error.runtimeType}');
      debugPrint('AUDIO_TRANSCRIPTION: exception message=$error');
      debugPrint('AUDIO_TRANSCRIPTION: stacktrace=$stackTrace');
      if (mounted) setState(() => _audioStatus = _AudioCaptureStatus.failed);
    }
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

  Future<void> _scanDocument() async {
    if (_isSaving) return;
    try {
      final attachment = await _documentScanService.scanDocument(
        mobileNoteId: _draftMobileNoteId,
      );
      if (attachment == null || !mounted) return;
      setState(() => _pendingAttachments.add(attachment));
      final attachmentLabel = attachment.scanMode == 'fallback_photo_pdf' ? 'PDF imagen' : 'PDF escaneado';
      _showValidationMessage(
        attachment.errorMessage != null && attachment.errorMessage!.isNotEmpty
            ? '${attachment.errorMessage} $attachmentLabel añadido.'
            : '$attachmentLabel añadido.',
      );
    } on DocumentScanException catch (error) {
      if (!mounted) return;
      _showValidationMessage(error.message);
    } catch (error) {
      debugPrint('No se pudo escanear el documento. Error exacto: $error');
      if (!mounted) return;
      _showValidationMessage('No se pudo escanear el documento.');
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

    // Audio remains local while this flow is being verified. Other attachment
    // types keep their existing upload behavior.
    final uploadableAttachments = _pendingAttachments
        .where((attachment) => attachment.captureMode != 'audio')
        .toList(growable: false);
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
      summary: '',
      source: 'mobile',
      createdAt: now,
      updatedAt: now,
      syncStatus: uploadableAttachments.isEmpty ? SyncStatus.uploaded : SyncStatus.pending,
      userId: uid,
      deviceId: await _firebaseSyncService.readDeviceId(),
      attachmentsCount: uploadableAttachments.length,
      durationSeconds: _lastRecordingSession?.durationSeconds,
      transcriptionStatus: _lastRecordingSession == null
          ? null
          : (_audioStatus == _AudioCaptureStatus.completed ? 'completed' : 'pending_transcription'),
      audioStorageStatus: _lastRecordingSession == null ? null : 'local',
    );

    try {
      if (uploadableAttachments.isEmpty) {
        await _firebaseSyncService.createTextNote(note);
      } else {
        await _firebaseSyncService.createNoteWithAttachments(
          note: note,
          attachments: uploadableAttachments,
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
                            icon: Icons.document_scanner_outlined,
                            label: 'Escanear PDF',
                            onPressed: _isSaving ? null : _scanDocument,
                          ),
                          AttachmentActionButton(
                            icon: Icons.mic_none_outlined,
                            label: 'Audio',
                            onPressed: _isSaving || _isAudioBusy ? null : _toggleAudioRecording,
                          ),
                          AttachmentActionButton(
                            icon: Icons.attach_file_outlined,
                            label: 'Archivo',
                            onPressed: _isSaving ? null : _pickFile,
                          ),
                        ],
                      ),
                      if (_audioStatus != _AudioCaptureStatus.idle) ...[
                        const SizedBox(height: 16),
                        _AudioRecordingPanel(
                          status: _audioStatus,
                          formattedElapsed: formatAudioDuration(_audioElapsed),
                          onStop: _audioStatus == _AudioCaptureStatus.recording ? _stopAudioRecording : null,
                          onRetry: _audioStatus == _AudioCaptureStatus.failed ? _retryTranscription : null,
                        ),
                      ],
                      const SizedBox(height: 16),
                      _AttachmentsPreview(
                        attachments: _pendingAttachments,
                        onRemove: _isSaving ? null : _removeAttachment,
                      ),
                      const SizedBox(height: 32),
                      FilledButton.icon(
                        onPressed: _isSaving || _isAudioBusy ? null : _saveNote,
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

class _AudioRecordingPanel extends StatelessWidget {
  const _AudioRecordingPanel({
    required this.status,
    required this.formattedElapsed,
    required this.onStop,
    required this.onRetry,
  });

  final _AudioCaptureStatus status;
  final String formattedElapsed;
  final VoidCallback? onStop;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final isRecording = status == _AudioCaptureStatus.recording;
    final isTranscribing = status == _AudioCaptureStatus.transcribing;
    return Semantics(
      liveRegion: true,
      label: isRecording ? 'Grabando, $formattedElapsed' : null,
      child: Card(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              if (isRecording) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.circle, color: Colors.red, size: 13),
                    const SizedBox(width: 8),
                    Text('Grabando', style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  formattedElapsed,
                  key: const Key('audio-recording-timer'),
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const Key('stop-audio-recording'),
                  onPressed: onStop,
                  icon: const Icon(Icons.stop),
                  label: const Text('Detener'),
                ),
              ] else if (isTranscribing) ...[
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                const Text('Transcribiendo audio...'),
              ] else if (status == _AudioCaptureStatus.completed) ...[
                const Icon(Icons.check_circle, color: Colors.green),
                const SizedBox(height: 8),
                const Text('Transcripción completada'),
              ] else ...[
                const Icon(Icons.error_outline, color: Colors.orange),
                const SizedBox(height: 8),
                const Text(
                  'No se pudo completar la transcripción.\n\n'
                  'La grabación está guardada y puedes volver a intentarlo.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar transcripción'),
                ),
              ],
            ],
          ),
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
                leading: _AttachmentLeading(attachment: attachment),
                title: Text(
                  attachment.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    _formatBytes(attachment.size),
                    _attachmentTypeLabel(attachment),
                    'Origen: ${_captureModeLabel(attachment.captureMode)}',
                    if (attachment.optimizedForOcr) 'Optimizado OCR: Sí',
                    if (attachment.pageCount != null) '${attachment.pageCount} pág.',
                    if (attachment.durationSeconds != null) '${attachment.durationSeconds}s',
                  ].join(' · '),
                ),
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

  String _attachmentTypeLabel(MobileAttachment attachment) {
    if (attachment.captureMode == 'document_scan' && attachment.documentFormat == 'pdf') {
      if (attachment.scanMode == 'fallback_photo_pdf') return 'PDF imagen';
      return 'PDF escaneado';
    }
    if (attachment.mimeType.startsWith('image/')) return 'Imagen';
    return attachment.mimeType;
  }

  String _captureModeLabel(String captureMode) {
    return switch (captureMode) {
      'gallery' => 'Galería',
      'document_scan' => 'Escáner',
      'audio' => 'Audio',
      'file_picker' => 'Archivo',
      'android_share' => 'Compartir',
      _ => 'Cámara',
    };
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

class _AttachmentLeading extends StatelessWidget {
  const _AttachmentLeading({required this.attachment});

  final MobileAttachment attachment;

  @override
  Widget build(BuildContext context) {
    if (attachment.mimeType.startsWith('audio/')) {
      return const Icon(Icons.audio_file_outlined, size: 40);
    }
    if (attachment.mimeType == 'application/pdf') {
      return Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: AppColors.primaryBlue.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.picture_as_pdf_outlined),
      );
    }

    if (!attachment.mimeType.startsWith('image/')) {
      return const Icon(Icons.insert_drive_file_outlined, size: 40);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        File(attachment.localPath),
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined),
      ),
    );
  }
}
