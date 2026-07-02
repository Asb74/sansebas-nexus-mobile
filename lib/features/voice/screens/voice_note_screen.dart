import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
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

enum VoiceCaptureMode { note, action }

enum _VoiceNoteStatus { choosing, ready, listening, transcribing, review, noVoice }

String buildSuggestedTitle(String text, {String fallback = 'Nota de voz'}) {
  final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) return fallback;

  var title = normalized.split(' ').take(8).join(' ');
  if (title.length > 60) {
    title = title.substring(0, 60).trimRight();
  }
  if (title.length < normalized.length) {
    title = title.replaceFirst(RegExp(r'[\s,.;:!?]+$'), '');
    title = '$title...';
  }
  return title;
}

class VoiceNoteScreen extends StatefulWidget {
  const VoiceNoteScreen({super.key});

  @override
  State<VoiceNoteScreen> createState() => _VoiceNoteScreenState();
}

class _VoiceNoteScreenState extends State<VoiceNoteScreen> {
  final _titleController = TextEditingController(text: 'Nota de voz');
  final _contentController = TextEditingController();
  final _actionDueTextController = TextEditingController();
  final _masterService = MasterService();
  final _firebaseSyncService = FirebaseSyncService();
  final _attachmentService = AttachmentService();
  final _speech = SpeechToText();
  final _audioRecorder = AudioRecorder();
  final _uuid = const Uuid();

  late final Future<MasterData> _mastersFuture;
  late final String _draftMobileNoteId;
  AreaMaster? _selectedArea;
  TopicMaster? _selectedTopic;
  NoteTypeMaster? _selectedType;
  _VoiceNoteStatus _status = _VoiceNoteStatus.choosing;
  VoiceCaptureMode? _mode;
  bool _isSaving = false;
  bool _attachOriginalAudio = false;
  bool _titleWasEdited = false;
  bool _updatingSuggestedTitle = false;
  DateTime? _recordingStartedAt;
  Duration _recordingDuration = Duration.zero;
  Timer? _durationTimer;
  String? _audioPath;
  int? _audioDurationSeconds;

  @override
  void initState() {
    super.initState();
    _mastersFuture = _masterService.loadMasters();
    _draftMobileNoteId = _uuid.v4();
    _titleController.addListener(() {
      if (!_updatingSuggestedTitle) _titleWasEdited = true;
    });
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _speech.cancel();
    _audioRecorder.dispose();
    _titleController.dispose();
    _contentController.dispose();
    _actionDueTextController.dispose();
    super.dispose();
  }

  bool get _isRecording => _status == _VoiceNoteStatus.listening;
  bool get _isActionMode => _mode == VoiceCaptureMode.action;
  String get _defaultTitle => _isActionMode ? 'Acción de voz' : 'Nota de voz';
  String get _contentLabel => _isActionMode ? 'Texto de acción' : 'Transcripción';

  void _selectMode(VoiceCaptureMode mode) {
    if (_isSaving || _isRecording) return;
    setState(() {
      _mode = mode;
      _status = _VoiceNoteStatus.ready;
      _selectedType = null;
      _titleWasEdited = false;
      _titleController.text = mode == VoiceCaptureMode.action ? 'Acción de voz' : 'Nota de voz';
    });
    _suggestTitleIfNeeded();
  }
  bool get _hasRecordedAudio => _audioPath != null;

  Future<void> _toggleRecording() async {
    if (_isSaving) return;
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    try {
      final permissionGranted = await _audioRecorder.hasPermission();
      debugPrint('Dictado voz - permission granted: $permissionGranted');
      if (!permissionGranted) {
        _showMessage('Permiso de micrófono denegado');
        return;
      }

      final available = await _speech.initialize(
        onStatus: _onSpeechStatus,
        onError: _onSpeechError,
        debugLogging: true,
      );
      debugPrint('Dictado voz - speech available: $available');
      if (!available) {
        _showMessage('Reconocimiento de voz no disponible en este dispositivo');
        return;
      }

      final localeId = await _preferredSpanishLocaleId();
      debugPrint(
        'Dictado voz - locale seleccionado: ${localeId ?? 'predeterminado del dispositivo'}',
      );

      String? path;
      if (_attachOriginalAudio) {
        final directory = await getTemporaryDirectory();
        path = '${directory.path}/${_uuid.v4()}.m4a';
        await _audioRecorder.start(
          const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000, sampleRate: 44100),
          path: path,
        );
      }

      if (!mounted) return;
      setState(() {
        _status = _VoiceNoteStatus.listening;
        _recordingStartedAt = DateTime.now();
        _recordingDuration = Duration.zero;
        _audioPath = path;
        _audioDurationSeconds = null;
      });

      await _speech.listen(
        onResult: _onSpeechResult,
        listenMode: ListenMode.dictation,
        partialResults: true,
        localeId: localeId,
      );
      debugPrint('Dictado voz - listening: ${_speech.isListening}');

      _durationTimer?.cancel();
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final startedAt = _recordingStartedAt;
        if (mounted && startedAt != null) {
          setState(() => _recordingDuration = DateTime.now().difference(startedAt));
        }
      });
    } catch (error) {
      debugPrint('No se pudo iniciar dictado. Error exacto: $error');
      await _stopAudioRecorderIfNeeded();
      if (!mounted) return;
      setState(() => _status = _VoiceNoteStatus.ready);
      _showMessage('Reconocimiento de voz no disponible en este dispositivo');
    }
  }

  Future<String?> _preferredSpanishLocaleId() async {
    final locales = await _speech.locales();
    for (final preferred in const ['es_ES', 'es-ES']) {
      for (final locale in locales) {
        if (locale.localeId == preferred) return locale.localeId;
      }
    }
    for (final locale in locales) {
      if (locale.localeId.toLowerCase().startsWith('es')) return locale.localeId;
    }
    return null;
  }

  Future<void> _stopAudioRecorderIfNeeded() async {
    if (await _audioRecorder.isRecording()) {
      await _audioRecorder.stop();
    }
  }

  Future<void> _stopRecording() async {
    setState(() => _status = _VoiceNoteStatus.transcribing);
    _durationTimer?.cancel();
    final startedAt = _recordingStartedAt;
    try {
      await _speech.stop();
      final stoppedPath = await _audioRecorder.isRecording()
          ? await _audioRecorder.stop()
          : _audioPath;
      if (!mounted) return;
      setState(() {
        _status = _contentController.text.trim().isEmpty
            ? _VoiceNoteStatus.noVoice
            : _VoiceNoteStatus.review;
        _audioPath = stoppedPath ?? _audioPath;
        _audioDurationSeconds = startedAt == null ? null : DateTime.now().difference(startedAt).inSeconds;
        _recordingStartedAt = null;
      });
      _suggestTitleIfNeeded();
      if (_contentController.text.trim().isEmpty) {
        _showMessage('No se detectó voz');
      } else {
        _showMessage('Transcripción lista para revisar');
      }
    } catch (error) {
      debugPrint('No se pudo detener dictado. Error exacto: $error');
      if (!mounted) return;
      setState(() => _status = _VoiceNoteStatus.review);
      _showMessage('Transcripción lista para revisar');
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    if (!mounted) return;
    debugPrint(
      'Dictado voz - palabras ${result.finalResult ? 'resultado final' : 'parciales'}: ${result.recognizedWords}',
    );
    _contentController.text = result.recognizedWords;
    _contentController.selection = TextSelection.collapsed(offset: _contentController.text.length);
    _suggestTitleIfNeeded();
  }

  void _onSpeechStatus(String status) {
    if (!mounted) return;
    if (status == 'notListening' || status == 'done') {
      debugPrint('Dictado voz - listening false, estado speech_to_text: $status');
      if (_isRecording) {
        Future.microtask(_stopRecording);
      }
    } else if (status == 'listening') {
      debugPrint('Dictado voz - listening true');
    }
  }

  void _onSpeechError(SpeechRecognitionError error) {
    debugPrint(
      'Dictado voz - errores del speech_to_text: ${error.errorMsg}, permanent: ${error.permanent}',
    );
    if (!mounted) return;
    if (error.errorMsg == 'error_no_match' || error.errorMsg == 'error_speech_timeout') {
      _showMessage('No se detectó voz');
    } else if (error.permanent) {
      _showMessage('Reconocimiento de voz no disponible en este dispositivo');
    }
  }

  void _suggestTitleIfNeeded() {
    if (_titleWasEdited && _titleController.text.trim() != _defaultTitle) return;
    final suggested = buildSuggestedTitle(_contentController.text, fallback: _defaultTitle);
    _updatingSuggestedTitle = true;
    _titleWasEdited = false;
    _titleController.text = suggested;
    _titleController.selection = TextSelection.collapsed(offset: _titleController.text.length);
    _updatingSuggestedTitle = false;
  }

  List<TopicMaster> _topicsForSelectedArea(MasterData masters) {
    final area = _selectedArea;
    if (area == null) return masters.topics;
    final filtered = masters.topics.where((topic) => topic.areaId == area.id).toList(growable: false);
    if (filtered.isNotEmpty) return filtered;
    return masters.topics.where((topic) => topic.name.trim().toLowerCase() == 'general').toList(growable: false);
  }

  T? _findDefault<T>(List<T> items, String name, String Function(T item) label) {
    for (final item in items) {
      if (label(item).trim().toLowerCase() == name) return item;
    }
    return items.firstOrNull;
  }

  Future<void> _saveNote() async {
    if (_isSaving) return;
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    final actionDueText = _actionDueTextController.text.trim();
    final area = _selectedArea;
    final topic = _selectedTopic;
    final type = _selectedType;

    if (title.isEmpty) return _showMessage('El título es obligatorio.');
    if (area == null) return _showMessage('El área es obligatoria.');
    if (topic == null) return _showMessage('El tema es obligatorio.');
    if (type == null) return _showMessage('El tipo es obligatorio.');
    if (content.isEmpty && (!_attachOriginalAudio || _audioPath == null)) return _showMessage('No hay contenido para guardar');

    final uid = _firebaseSyncService.currentUserId;
    if (uid == null || uid.isEmpty) return _showMessage('No tienes permiso para guardar notas');

    setState(() => _isSaving = true);
    try {
      final attachments = <MobileAttachment>[];
      if (_attachOriginalAudio && _audioPath != null) {
        attachments.add(await _attachmentService.buildMobileAttachmentFromPath(
          path: _audioPath!,
          mobileNoteId: _draftMobileNoteId,
          captureMode: 'audio_dictation',
          filename: 'dictado_${DateTime.now().millisecondsSinceEpoch}.m4a',
          mimeType: 'audio/mp4',
          source: _isActionMode ? 'voice_action' : 'voice_dictation',
          durationSeconds: _audioDurationSeconds,
        ));
      }
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
        tags: const [],
        content: content,
        source: _isActionMode ? 'voice_action' : 'voice_dictation',
        createdAt: now,
        updatedAt: now,
        syncStatus: attachments.isEmpty ? SyncStatus.uploaded : SyncStatus.pending,
        userId: uid,
        deviceId: await _firebaseSyncService.readDeviceId(),
        attachmentsCount: attachments.length,
        voiceTranscription: content,
        captureMode: _isActionMode ? 'voice_action' : 'voice_note',
        isActionCandidate: _isActionMode,
        actionStatus: _isActionMode ? 'pending_review' : null,
        actionText: _isActionMode ? content : null,
        actionDueText: _isActionMode && actionDueText.isNotEmpty ? actionDueText : null,
        calendarEventCandidate: _isActionMode,
        calendarCreated: false,
        calendarEventId: null,
      );
      if (attachments.isEmpty) {
        await _firebaseSyncService.createTextNote(note);
      } else {
        await _firebaseSyncService.createNoteWithAttachments(note: note, attachments: attachments);
      }
      if (!mounted) return;
      _showMessage(_isActionMode ? 'Acción de voz guardada para revisión.' : 'Nota de voz guardada para sincronización.');
      Navigator.pop(context);
    } on AttachmentException catch (error) {
      if (mounted) _showMessage(error.message);
    } on FirebaseSyncException catch (error) {
      if (mounted) _showMessage(error.userMessage);
    } catch (error) {
      debugPrint('No se pudo guardar dictado. Error exacto: $error');
      if (mounted) _showMessage('No se pudo guardar la nota');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showMessage(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  String _statusLabel() => switch (_status) {
        _VoiceNoteStatus.choosing => 'Elige qué quieres crear',
        _VoiceNoteStatus.ready => 'Preparado',
        _VoiceNoteStatus.listening => 'Escuchando...',
        _VoiceNoteStatus.transcribing => 'Transcribiendo...',
        _VoiceNoteStatus.review => 'Listo para revisar',
        _VoiceNoteStatus.noVoice => 'No se detectó voz',
      };

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return PopScope(
      canPop: !_isRecording && !_isSaving,
      child: Scaffold(
        appBar: AppBar(title: const Text('Captura por voz')),
        body: SafeArea(
          child: FutureBuilder<MasterData>(
            future: _mastersFuture,
            builder: (context, snapshot) {
              final masters = snapshot.data ?? _masterService.fallbackMasterData;
              _selectedArea ??= _findDefault(masters.areas, 'general', (area) => area.name);
              _selectedType ??= _findDefault(masters.types, _isActionMode ? 'tarea' : 'nota', (type) => type.name) ??
                  _findDefault(masters.types, 'nota', (type) => type.name);
              final topics = _topicsForSelectedArea(masters);
              if (_selectedTopic == null || !topics.contains(_selectedTopic)) {
                _selectedTopic = _findDefault(topics, 'general', (topic) => topic.name);
              }

              return SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        Image.asset('assets/icon/icono_app.png', width: 40, height: 40),
                        const SizedBox(width: 12),
                        Expanded(child: Text('Sansebas Nexus Mobile', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
                      ]),
                      const SizedBox(height: 20),
                      Text('Captura por voz', style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text('Paso 1: Elegir tipo · Paso 2: Dictar · Paso 3: Revisar · Paso 4: Guardar', style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                      const SizedBox(height: 16),
                      SegmentedButton<VoiceCaptureMode>(
                        segments: const [
                          ButtonSegment(value: VoiceCaptureMode.note, icon: Icon(Icons.note_alt_outlined), label: Text('Nota')),
                          ButtonSegment(value: VoiceCaptureMode.action, icon: Icon(Icons.task_alt_outlined), label: Text('Acción / recordatorio')),
                        ],
                        selected: _mode == null ? const <VoiceCaptureMode>{} : {_mode!},
                        emptySelectionAllowed: true,
                        onSelectionChanged: _isSaving || _isRecording ? null : (selection) {
                          if (selection.isNotEmpty) _selectMode(selection.first);
                        },
                      ),
                      const SizedBox(height: 16),
                      if (_mode != null) Text(_isActionMode ? 'Crear acción' : 'Dictar contenido', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      if (_mode != null) const SizedBox(height: 8),
                      if (_mode != null) Text(_isActionMode ? 'Dicta la acción o recordatorio. Revise antes de guardar.' : 'Dicta la nota. Revise antes de guardar.', style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _isSaving || _mode == null ? null : _toggleRecording,
                        icon: Icon(_isRecording ? Icons.stop_circle_outlined : Icons.mic_none_outlined),
                        label: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Text(_isRecording ? 'Detener dictado' : 'Iniciar dictado'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Card(child: ListTile(
                        leading: Icon(_isRecording ? Icons.graphic_eq : Icons.info_outline, color: AppColors.primaryBlue),
                        title: Text(_statusLabel()),
                        subtitle: Text('Duración: ${_formatDuration(_recordingDuration)}${_hasRecordedAudio ? ' · Audio original listo' : ''}'),
                      )),
                      const SizedBox(height: 16),
                      NoteTextField(controller: _titleController, label: 'Título', hintText: _defaultTitle, textInputAction: TextInputAction.next),
                      const SizedBox(height: 16),
                      _MasterDropdown<AreaMaster>(
                        label: 'Área', value: _selectedArea, items: masters.areas, itemLabel: (area) => area.name,
                        onChanged: _isSaving ? null : (area) => setState(() { _selectedArea = area; _selectedTopic = null; }),
                      ),
                      const SizedBox(height: 16),
                      _MasterDropdown<TopicMaster>(
                        label: 'Tema', value: _selectedTopic, items: topics, itemLabel: (topic) => topic.name,
                        onChanged: _isSaving ? null : (topic) => setState(() => _selectedTopic = topic),
                      ),
                      const SizedBox(height: 16),
                      _MasterDropdown<NoteTypeMaster>(
                        label: 'Tipo', value: _selectedType, items: masters.types, itemLabel: (type) => type.name,
                        onChanged: _isSaving ? null : (type) => setState(() => _selectedType = type),
                      ),
                      const SizedBox(height: 16),
                      NoteTextField(
                        controller: _contentController,
                        label: _contentLabel,
                        hintText: _isActionMode ? 'La acción o recordatorio aparecerá aquí. Revísela antes de guardar.' : 'La transcripción aparecerá aquí. Revísela antes de guardar.',
                        keyboardType: TextInputType.multiline,
                        minLines: 6,
                        maxLines: 12,
                      ),
                      if (_isActionMode) ...[
                        const SizedBox(height: 16),
                        NoteTextField(
                          controller: _actionDueTextController,
                          label: 'Fecha/hora opcional (texto libre)',
                          hintText: 'Ej.: mañana por la tarde, viernes 10:00...',
                          textInputAction: TextInputAction.next,
                        ),
                      ],
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        value: _attachOriginalAudio,
                        onChanged: _isSaving || _isRecording ? null : (value) => setState(() => _attachOriginalAudio = value ?? false),
                        title: const Text('Adjuntar audio original'),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _isSaving || _isRecording || _mode == null ? null : _saveNote,
                        icon: _isSaving ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.check_circle_outline),
                        label: Text(_isSaving ? 'Guardando...' : (_isActionMode ? 'Guardar acción' : 'Guardar nota')),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _isSaving || _isRecording ? null : () => Navigator.pop(context),
                        icon: const Icon(Icons.close_outlined),
                        label: const Text('Cancelar'),
                      ),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _MasterDropdown<T> extends StatelessWidget {
  const _MasterDropdown({required this.label, required this.value, required this.items, required this.itemLabel, required this.onChanged});

  final String label;
  final T? value;
  final List<T> items;
  final String Function(T item) itemLabel;
  final ValueChanged<T?>? onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      value: value,
      items: items.map((item) => DropdownMenuItem<T>(value: item, child: Text(itemLabel(item)))).toList(growable: false),
      onChanged: items.isEmpty ? null : onChanged,
      decoration: InputDecoration(
        labelText: label,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      ),
    );
  }
}
