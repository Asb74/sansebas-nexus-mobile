import 'dart:async';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
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

enum VoiceAssistantMode { normal, handsFree }

enum VoiceCommandIntent { save, cancel, repeat, repeatTitle, repeatContent, repeatDescription, repeatDate, calendar, note, action, unknown }

enum VoiceAssistantStep {
  askMode,
  noteTitle,
  noteContent,
  noteConfirm,
  actionTitle,
  actionDescription,
  actionDate,
  actionConfirm,
  finished,
}

enum _VoiceNoteStatus { choosing, ready, listening, transcribing, speaking, preparing, waiting, review, noVoice }

String normalizeVoiceCommand(String text) {
  const accents = {'á':'a','à':'a','ä':'a','â':'a','é':'e','è':'e','ë':'e','ê':'e','í':'i','ì':'i','ï':'i','î':'i','ó':'o','ò':'o','ö':'o','ô':'o','ú':'u','ù':'u','ü':'u','û':'u'};
  final buffer = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    buffer.write(accents[char] ?? char);
  }
  return buffer.toString().replaceAll(RegExp(r'[^a-zñ0-9 ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

VoiceCommandIntent detectVoiceCommand(String text) {
  final command = normalizeVoiceCommand(text);
  if (command.isEmpty) return VoiceCommandIntent.unknown;
  bool hasAny(Iterable<String> variants) => variants.any((variant) => command == variant || command.contains(variant));
  if (hasAny(const ['guardar en calendario', 'crear en calendario', 'crear evento', 'calendario', 'evento'])) return VoiceCommandIntent.calendar;
  if (hasAny(const ['guardar nota', 'guardar accion', 'guardalo', 'guardar', 'guarda', 'si', 'sí'])) return VoiceCommandIntent.save;
  if (hasAny(const ['repetir titulo', 'repite titulo', 'cambiar titulo'])) return VoiceCommandIntent.repeatTitle;
  if (hasAny(const ['repetir contenido', 'repetir nota', 'repite contenido', 'cambiar contenido'])) return VoiceCommandIntent.repeatContent;
  if (hasAny(const ['repetir descripcion', 'repite descripcion', 'cambiar descripcion'])) return VoiceCommandIntent.repeatDescription;
  if (hasAny(const ['repetir fecha', 'repetir hora', 'repetir recordatorio', 'cambiar fecha', 'cambiar hora'])) return VoiceCommandIntent.repeatDate;
  if (hasAny(const ['empezar de nuevo', 'repetir todo', 'repetir', 'repite'])) return VoiceCommandIntent.repeat;
  if (hasAny(const ['cancelar', 'cancela', 'salir', 'descartar', 'no'])) return VoiceCommandIntent.cancel;
  if (hasAny(const ['crear nota', 'nota'])) return VoiceCommandIntent.note;
  if (hasAny(const ['accion', 'tarea', 'recordatorio'])) return VoiceCommandIntent.action;
  return VoiceCommandIntent.unknown;
}

class ParsedSpanishDue {
  const ParsedSpanishDue({this.dueAt, this.confidence = 0});
  final DateTime? dueAt;
  final double confidence;
}

ParsedSpanishDue parseSpanishDueText(String input, {DateTime? now}) {
  final base = now ?? DateTime.now();
  final text = normalizeVoiceCommand(input);
  if (text.isEmpty) return const ParsedSpanishDue();

  var date = DateTime(base.year, base.month, base.day);
  var dateFound = false;
  if (text.contains('pasado mañana') || text.contains('pasado manana')) {
    date = date.add(const Duration(days: 2));
    dateFound = true;
  } else if (text.contains('manana') || text.contains('mañana')) {
    date = date.add(const Duration(days: 1));
    dateFound = true;
  } else if (text.contains('hoy') || text.contains('esta tarde')) {
    dateFound = true;
  }

  final weekdays = {'lunes':1,'martes':2,'miercoles':3,'jueves':4,'viernes':5,'sabado':6,'domingo':7};
  for (final entry in weekdays.entries) {
    if (RegExp('(?:el )?${entry.key}(?: que viene)?').hasMatch(text)) {
      var delta = entry.value - base.weekday;
      if (delta <= 0 || text.contains('que viene')) delta += 7;
      date = DateTime(base.year, base.month, base.day).add(Duration(days: delta));
      dateFound = true;
      break;
    }
  }

  final months = {'enero':1,'febrero':2,'marzo':3,'abril':4,'mayo':5,'junio':6,'julio':7,'agosto':8,'septiembre':9,'setiembre':9,'octubre':10,'noviembre':11,'diciembre':12};
  final dateMatch = RegExp(r'(?:dia )?(\d{1,2}) de ([a-z]+)').firstMatch(text);
  if (dateMatch != null && months.containsKey(dateMatch.group(2))) {
    final day = int.parse(dateMatch.group(1)!);
    final month = months[dateMatch.group(2)]!;
    var year = base.year;
    if (DateTime(year, month, day).isBefore(DateTime(base.year, base.month, base.day))) year++;
    date = DateTime(year, month, day);
    dateFound = true;
  }

  final numberWords = {'una':1,'uno':1,'dos':2,'tres':3,'cuatro':4,'cinco':5,'seis':6,'siete':7,'ocho':8,'nueve':9,'diez':10,'once':11,'doce':12};
  int? parseHourToken(String token) => int.tryParse(token) ?? numberWords[token];

  int? hour;
  var minute = 0;
  final numeric = RegExp(r'(?:a las|las) (\d{1,2})(?::(\d{2}))?').firstMatch(text) ?? RegExp(r'\b(\d{1,2}):(\d{2})\b').firstMatch(text);
  if (numeric != null) {
    hour = int.parse(numeric.group(1)!);
    minute = int.tryParse(numeric.group(2) ?? '0') ?? 0;
  } else {
    final wordMatch = RegExp(r'(?:a las |las )([a-z]+)(?: y media)?').firstMatch(text);
    if (wordMatch != null) hour = parseHourToken(wordMatch.group(1)!);
    if (hour == null) {
      for (final entry in numberWords.entries) {
        if (text.contains(entry.key)) { hour = entry.value; break; }
      }
    }
    if (hour != null && text.contains('media')) minute = 30;
  }
  if (text.contains('mediodia')) { hour = 12; minute = 0; }
  if (hour == null && text.contains('esta tarde')) hour = 18;
  if (hour == null && (text.contains('por la manana') || text.contains('por la mañana'))) hour = 9;
  if (hour != null && hour < 12 && (text.contains('tarde') || text.contains('noche'))) hour += 12;
  if (hour != null && hour == 12 && text.contains('manana') && text.contains('de la manana')) hour = 0;
  if (!dateFound && hour == null) return const ParsedSpanishDue();
  return ParsedSpanishDue(dueAt: DateTime(date.year, date.month, date.day, hour ?? 9, minute), confidence: dateFound && hour != null ? .9 : .65);
}

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
  final _actionTitleController = TextEditingController();
  final _actionDescriptionController = TextEditingController();
  final _actionDueTextController = TextEditingController();
  final _confirmationCommandController = TextEditingController();
  final _masterService = MasterService();
  final _firebaseSyncService = FirebaseSyncService();
  final _attachmentService = AttachmentService();
  final _speech = SpeechToText();
  final _tts = FlutterTts();
  final _audioRecorder = AudioRecorder();
  final _uuid = const Uuid();

  late final Future<MasterData> _mastersFuture;
  late final String _draftMobileNoteId;
  AreaMaster? _selectedArea;
  TopicMaster? _selectedTopic;
  NoteTypeMaster? _selectedType;
  _VoiceNoteStatus _status = _VoiceNoteStatus.choosing;
  VoiceCaptureMode? _mode;
  VoiceAssistantMode _assistantMode = VoiceAssistantMode.normal;
  int _assistantStep = 0;
  VoiceAssistantStep _assistantStepState = VoiceAssistantStep.askMode;
  String _currentPrompt = '';
  String _statusMessage = '';
  String _lastDetectedAnswer = '';
  bool _ttsAvailable = true;
  bool _isSaving = false;
  bool _attachOriginalAudio = false;
  DateTime? _recordingStartedAt;
  DateTime? _listeningStartedAt;
  Duration _recordingDuration = Duration.zero;
  Timer? _durationTimer;
  String? _audioPath;
  int? _audioDurationSeconds;
  String _lastPartialSpeech = '';
  bool _speechReady = false;
  Completer<String?>? _listenCompleter;
  String _stepRecognizedText = '';
  String _dictationStateLabel = 'Finalizado';
  DateTime? _parsedDueAt;
  double? _parsedDueConfidence;

  @override
  void initState() {
    super.initState();
    _mastersFuture = _masterService.loadMasters();
    _draftMobileNoteId = _uuid.v4();
    unawaited(_ensureSpeechInitialized().then((_) => _configureTts()).then((_) => _startModeChoice()));
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _speech.cancel();
    _audioRecorder.dispose();
    _tts.stop();
    _titleController.dispose();
    _contentController.dispose();
    _actionTitleController.dispose();
    _actionDescriptionController.dispose();
    _actionDueTextController.dispose();
    _confirmationCommandController.dispose();
    super.dispose();
  }

  bool get _isRecording => _status == _VoiceNoteStatus.listening;
  bool get _isActionMode => _mode == VoiceCaptureMode.action;
  String get _defaultTitle => _isActionMode ? 'Acción de voz' : 'Nota de voz';
  String get _contentLabel => _isActionMode ? 'Descripción' : 'Contenido / transcripción';
  int get _lastAssistantStep => _isActionMode ? 3 : 2;

  Future<void> _configureTts() async {
    try {
      await _tts.setLanguage('es-ES');
      await _tts.setSpeechRate(0.48);
      await _tts.setVolume(1);
      await _tts.awaitSpeakCompletion(true);
    } catch (error) {
      debugPrint('TTS no disponible: $error');
      if (mounted) setState(() => _ttsAvailable = false);
    }
  }

  Future<void> _speak(String text, {bool replacePrompt = true}) async {
    if (!mounted) return;
    setState(() {
      if (replacePrompt) _currentPrompt = text;
      _status = _VoiceNoteStatus.speaking;
    });
    try {
      debugPrint('TTS START step=$_assistantStepState prompt="$text"');
      await _tts.awaitSpeakCompletion(true);
      await _tts.stop();
      await _tts.speak(text);
      debugPrint('TTS END step=$_assistantStepState');
    } catch (error) {
      debugPrint('TTS ERROR step=$_assistantStepState error=$error');
      if (mounted) setState(() => _ttsAvailable = false);
      await Future<void>.delayed(const Duration(milliseconds: 700));
    } finally {
      if (mounted && _status == _VoiceNoteStatus.speaking) setState(() => _status = _VoiceNoteStatus.preparing);
    }
  }

  String _formatDue(DateTime dueAt) => '${dueAt.day.toString().padLeft(2, '0')}/${dueAt.month.toString().padLeft(2, '0')}/${dueAt.year} ${dueAt.hour.toString().padLeft(2, '0')}:${dueAt.minute.toString().padLeft(2, '0')}';

  int _stepNumberFor(VoiceAssistantStep step) => switch (step) {
        VoiceAssistantStep.askMode => 0,
        VoiceAssistantStep.noteTitle => 0,
        VoiceAssistantStep.noteContent => 1,
        VoiceAssistantStep.noteConfirm => 2,
        VoiceAssistantStep.actionTitle => 0,
        VoiceAssistantStep.actionDescription => 1,
        VoiceAssistantStep.actionDate => 2,
        VoiceAssistantStep.actionConfirm => 3,
        VoiceAssistantStep.finished => _assistantStep,
      };

  String _promptForAssistantStep(VoiceAssistantStep step) => switch (step) {
        VoiceAssistantStep.askMode => '¿Quieres crear una nota o una acción?',
        VoiceAssistantStep.noteTitle => 'Título de la nota',
        VoiceAssistantStep.noteContent => '¿Qué quieres anotar?',
        VoiceAssistantStep.noteConfirm => 'He entendido. Título: ${_titleController.text.trim()}. Nota: ${_contentController.text.trim()}. Di guardar, repetir, repetir título, repetir contenido o cancelar.',
        VoiceAssistantStep.actionTitle => 'Título de la acción',
        VoiceAssistantStep.actionDescription => 'Describe la acción',
        VoiceAssistantStep.actionDate => '¿Cuándo quieres recordarlo?',
        VoiceAssistantStep.actionConfirm => 'He entendido. Acción: ${_actionTitleController.text.trim()}. Detalle: ${_actionDescriptionController.text.trim()}. Fecha: ${_parsedDueAt == null ? _actionDueTextController.text.trim() : _formatDue(_parsedDueAt!)}. Di calendario, guardar, repetir, repetir título, repetir descripción, repetir fecha o cancelar.',
        VoiceAssistantStep.finished => 'Finalizado',
      };

  String _promptForStep() => _promptForAssistantStep(_assistantStepState);

  Future<void> _startModeChoice() async {
    if (!mounted || _isSaving) return;
    _assistantMode = VoiceAssistantMode.handsFree;
    await _runStep(VoiceAssistantStep.askMode);
  }

  void _selectMode(VoiceCaptureMode mode, {bool autoStart = false}) {
    if (_isSaving || _isRecording) return;
    setState(() {
      _mode = mode;
      _selectedArea = null;
      _selectedTopic = null;
      _selectedType = null;
      _assistantStepState = mode == VoiceCaptureMode.note ? VoiceAssistantStep.noteTitle : VoiceAssistantStep.actionTitle;
      _assistantStep = 0;
      _status = _VoiceNoteStatus.ready;
      _currentPrompt = '';
      _statusMessage = '';
      _lastDetectedAnswer = '';
      _titleController.clear();
      _contentController.clear();
      _actionTitleController.clear();
      _actionDescriptionController.clear();
      _actionDueTextController.clear();
      _confirmationCommandController.clear();
      _parsedDueAt = null;
      _parsedDueConfidence = null;
    });
    if (autoStart) unawaited(_startAssistant());
  }

  bool get _hasRecordedAudio => _audioPath != null;

  Future<void> _startAssistant() async {
    if (_isSaving) return;
    await _runStep(_mode == null ? VoiceAssistantStep.askMode : _assistantStepState);
  }

  Future<void> _repeatStep() async {
    if (_isSaving) return;
    await _speech.stop();
    await _runStep(_assistantStepState);
  }

  Future<void> _continueDictating() async => _startAssistant();

  Future<void> _finishStep({String reason = 'manual'}) async {
    debugPrint('STEP RESULT manual finish reason=$reason step=$_assistantStepState text="${_stepRecognizedText.trim()}"');
    if (_speech.isListening) await _speech.stop();
    _completeListen(_stepRecognizedText.trim().isEmpty ? null : _stepRecognizedText.trim());
  }

  Future<void> _runStep(VoiceAssistantStep step) async {
    if (!mounted || _isSaving || step == VoiceAssistantStep.finished) return;
    final prompt = _promptForAssistantStep(step);
    debugPrint('STEP START $step');
    setState(() {
      _assistantStepState = step;
      _assistantStep = _stepNumberFor(step);
      _currentPrompt = prompt;
      _statusMessage = '';
      _lastPartialSpeech = '';
      _stepRecognizedText = '';
      _confirmationCommandController.clear();
      _status = _VoiceNoteStatus.preparing;
    });
    await _speak(prompt);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final text = await _listenForStep(step);
    await _handleStepResult(step, text);
  }

  Future<String?> _listenForStep(VoiceAssistantStep step) async {
    final available = await _ensureSpeechInitialized();
    if (!available) {
      _showMessage('Reconocimiento de voz no disponible en este dispositivo');
      return null;
    }

    await _speech.stop();
    final localeId = await _preferredSpanishLocaleId();
    debugPrint('LISTEN START step=$step locale=${localeId ?? 'default'}');

    String? path;
    if (_attachOriginalAudio) {
      final permissionGranted = await _audioRecorder.hasPermission();
      if (permissionGranted) {
        final directory = await getTemporaryDirectory();
        path = '${directory.path}/${_uuid.v4()}.m4a';
        await _audioRecorder.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000, sampleRate: 44100), path: path);
      }
    }

    final completer = Completer<String?>();
    _listenCompleter = completer;
    final now = DateTime.now();
    if (mounted) {
      setState(() {
        _status = _VoiceNoteStatus.listening;
        _recordingStartedAt = now;
        _listeningStartedAt = now;
        _recordingDuration = Duration.zero;
        _audioPath = path ?? _audioPath;
        _dictationStateLabel = 'Escuchando...';
      });
    }
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final startedAt = _recordingStartedAt;
      if (mounted && startedAt != null) setState(() => _recordingDuration = DateTime.now().difference(startedAt));
    });

    final timeout = (step == VoiceAssistantStep.noteContent || step == VoiceAssistantStep.actionDescription) ? const Duration(seconds: 60) : const Duration(seconds: 20);
    await _speech.listen(
      onResult: _onSpeechResult,
      listenMode: ListenMode.dictation,
      partialResults: true,
      listenFor: timeout,
      pauseFor: const Duration(seconds: 3),
      localeId: localeId,
    );

    final result = await completer.future.timeout(timeout + const Duration(seconds: 2), onTimeout: () async {
      debugPrint('ON STATUS timeout step=$step');
      await _speech.stop();
      return null;
    });
    await _stopAudioRecorderIfNeeded();
    _durationTimer?.cancel();
    if (mounted) {
      setState(() {
        _status = _VoiceNoteStatus.transcribing;
        _audioDurationSeconds = _recordingStartedAt == null ? null : DateTime.now().difference(_recordingStartedAt!).inSeconds;
        _recordingStartedAt = null;
        _listeningStartedAt = null;
        _dictationStateLabel = 'Finalizado';
      });
    }
    _listenCompleter = null;
    return result?.trim().isEmpty ?? true ? null : result!.trim();
  }

  void _completeListen(String? text) {
    final completer = _listenCompleter;
    if (completer != null && !completer.isCompleted) completer.complete(text?.trim().isEmpty ?? true ? null : text!.trim());
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    if (!mounted) return;
    final recognized = result.recognizedWords.trim();
    debugPrint('ON RESULT ${result.finalResult ? 'final' : 'partial'} step=$_assistantStepState text="$recognized"');
    if (recognized.isEmpty) return;
    _stepRecognizedText = recognized;
    _lastPartialSpeech = result.finalResult ? '' : recognized;
    setState(() {
      _lastDetectedAnswer = recognized;
      _activeDictationController.text = recognized;
      _activeDictationController.selection = TextSelection.collapsed(offset: recognized.length);
      _commitActiveController();
    });
    if (result.finalResult) {
      unawaited(_speech.stop());
      _completeListen(recognized);
    }
  }

  void _onSpeechStatus(String status) {
    debugPrint('ON STATUS $status step=$_assistantStepState text="${_stepRecognizedText.trim()}"');
    if (!mounted) return;
    if (status == 'listening') setState(() => _status = _VoiceNoteStatus.listening);
    if (status == 'notListening' || status == 'done') _completeListen(_stepRecognizedText.trim().isEmpty ? null : _stepRecognizedText.trim());
  }

  void _onSpeechError(SpeechRecognitionError error) {
    debugPrint('ON ERROR ${error.errorMsg} permanent=${error.permanent} step=$_assistantStepState');
    _completeListen(null);
  }

  Future<bool> _ensureSpeechInitialized() async {
    if (_speechReady) {
      debugPrint('STT INIT cached true');
      return true;
    }
    try {
      final available = await _speech.initialize(onStatus: _onSpeechStatus, onError: _onSpeechError, debugLogging: true);
      _speechReady = available;
      debugPrint('STT INIT available=$_speechReady');
      if (available) {
        final locales = await _speech.locales();
        debugPrint('STT INIT locales=${locales.map((locale) => '${locale.localeId}:${locale.name}').join(', ')}');
      }
      return available;
    } catch (error) {
      debugPrint('STT INIT error=$error');
      _speechReady = false;
      return false;
    }
  }

  Future<String?> _preferredSpanishLocaleId() async {
    await _ensureSpeechInitialized();
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
    if (await _audioRecorder.isRecording()) await _audioRecorder.stop();
  }

  TextEditingController get _activeDictationController => switch (_assistantStepState) {
        VoiceAssistantStep.askMode => _confirmationCommandController,
        VoiceAssistantStep.noteTitle => _titleController,
        VoiceAssistantStep.noteContent => _contentController,
        VoiceAssistantStep.noteConfirm => _confirmationCommandController,
        VoiceAssistantStep.actionTitle => _actionTitleController,
        VoiceAssistantStep.actionDescription => _actionDescriptionController,
        VoiceAssistantStep.actionDate => _actionDueTextController,
        VoiceAssistantStep.actionConfirm => _confirmationCommandController,
        VoiceAssistantStep.finished => _confirmationCommandController,
      };

  void _commitActiveController() {
    if (_isActionMode) {
      _syncActionContent();
      if (_assistantStepState == VoiceAssistantStep.actionDate) _parseDueText();
    }
  }

  String _normalizeCommand(String text) => normalizeVoiceCommand(text);
  String _normalizedCommand(String text) => _normalizeCommand(text);

  Future<void> _handleStepResult(VoiceAssistantStep step, String? text) async {
    final spoken = text?.trim() ?? '';
    debugPrint('STEP RESULT step=$step text="$spoken"');
    if (mounted) setState(() => _lastDetectedAnswer = spoken);
    if (spoken.isEmpty) {
      if (mounted) setState(() => _statusMessage = 'No te he oído. Repito.');
      await _speak('No te he oído. Repito.', replacePrompt: false);
      await _runStep(step);
      return;
    }
    final command = detectVoiceCommand(spoken);
    debugPrint('COMMAND DETECTED step=$step command=$command normalized="${_normalizeCommand(spoken)}"');
    switch (step) {
      case VoiceAssistantStep.askMode:
        if (command == VoiceCommandIntent.note) {
          setState(() => _mode = VoiceCaptureMode.note);
          await _runStep(VoiceAssistantStep.noteTitle);
          return;
        } else if (command == VoiceCommandIntent.action) {
          setState(() => _mode = VoiceCaptureMode.action);
          await _runStep(VoiceAssistantStep.actionTitle);
          return;
        } else {
          setState(() => _statusMessage = 'No he entendido la respuesta.');
          await _runStep(VoiceAssistantStep.askMode);
          return;
        }
      case VoiceAssistantStep.noteTitle:
        setState(() => _titleController.text = spoken);
        debugPrint('NEXT STEP noteContent');
        await _runStep(VoiceAssistantStep.noteContent);
        return;
      case VoiceAssistantStep.noteContent:
        setState(() => _contentController.text = spoken);
        debugPrint('NEXT STEP noteConfirm');
        await _runStep(VoiceAssistantStep.noteConfirm);
        return;
      case VoiceAssistantStep.noteConfirm:
        await _handleNoteConfirm(command);
        return;
      case VoiceAssistantStep.actionTitle:
        setState(() { _actionTitleController.text = spoken; _titleController.text = spoken; });
        debugPrint('NEXT STEP actionDescription');
        await _runStep(VoiceAssistantStep.actionDescription);
        return;
      case VoiceAssistantStep.actionDescription:
        setState(() { _actionDescriptionController.text = spoken; _contentController.text = spoken; });
        debugPrint('NEXT STEP actionDate');
        await _runStep(VoiceAssistantStep.actionDate);
        return;
      case VoiceAssistantStep.actionDate:
        setState(() => _actionDueTextController.text = spoken);
        _parseDueText();
        debugPrint('NEXT STEP actionConfirm');
        await _runStep(VoiceAssistantStep.actionConfirm);
        return;
      case VoiceAssistantStep.actionConfirm:
        await _handleActionConfirm(command);
        return;
      case VoiceAssistantStep.finished:
        return;
    }
  }

  Future<void> _handleNoteConfirm(VoiceCommandIntent command) async {
    if (command == VoiceCommandIntent.save) { await _speak('Nota guardada'); await _saveNote(); return; }
    if (command == VoiceCommandIntent.cancel) { await _speak('Cancelado'); if (mounted) Navigator.pop(context); return; }
    if (command == VoiceCommandIntent.repeat) {
      setState(() { _titleController.clear(); _contentController.clear(); });
      await _runStep(VoiceAssistantStep.noteTitle); return;
    }
    if (command == VoiceCommandIntent.repeatTitle) { setState(() => _titleController.clear()); await _runStep(VoiceAssistantStep.noteTitle); return; }
    if (command == VoiceCommandIntent.repeatContent) { setState(() => _contentController.clear()); await _runStep(VoiceAssistantStep.noteContent); return; }
    setState(() => _statusMessage = 'Comando no entendido.');
    await _runStep(VoiceAssistantStep.noteConfirm);
  }

  Future<void> _handleActionConfirm(VoiceCommandIntent command) async {
    if (command == VoiceCommandIntent.save) { await _speak('Acción guardada'); await _saveNote(); return; }
    if (command == VoiceCommandIntent.cancel) { await _speak('Cancelado'); if (mounted) Navigator.pop(context); return; }
    if (command == VoiceCommandIntent.calendar) {
      if (_parsedDueAt == null) { await _speak('No he entendido la fecha. Vamos a repetirla.'); await _runStep(VoiceAssistantStep.actionDate); return; }
      await _createCalendarEvent(saveSummary: true); return;
    }
    if (command == VoiceCommandIntent.repeat) {
      setState(() { _actionTitleController.clear(); _actionDescriptionController.clear(); _actionDueTextController.clear(); _syncActionContent(); _parsedDueAt = null; _parsedDueConfidence = null; });
      await _runStep(VoiceAssistantStep.actionTitle); return;
    }
    if (command == VoiceCommandIntent.repeatTitle) { setState(() { _actionTitleController.clear(); _syncActionContent(); }); await _runStep(VoiceAssistantStep.actionTitle); return; }
    if (command == VoiceCommandIntent.repeatContent || command == VoiceCommandIntent.repeatDescription) { setState(() { _actionDescriptionController.clear(); _syncActionContent(); }); await _runStep(VoiceAssistantStep.actionDescription); return; }
    if (command == VoiceCommandIntent.repeatDate) { setState(() { _actionDueTextController.clear(); _parsedDueAt = null; _parsedDueConfidence = null; }); await _runStep(VoiceAssistantStep.actionDate); return; }
    setState(() => _statusMessage = 'Comando no entendido.');
    await _runStep(VoiceAssistantStep.actionConfirm);
  }


  void _syncActionContent() {
    _titleController.text = _actionTitleController.text;
    _contentController.text = _actionDescriptionController.text;
  }

  void _parseDueText() {
    final parsed = parseSpanishDueText(_actionDueTextController.text, now: DateTime.now());
    if (mounted) {
      setState(() { _parsedDueAt = parsed.dueAt; _parsedDueConfidence = parsed.confidence; });
    } else {
      _parsedDueAt = parsed.dueAt; _parsedDueConfidence = parsed.confidence;
    }
  }

  List<TopicMaster> _topicsForSelectedArea(MasterData masters) {
    final area = _selectedArea;
    if (area == null) return masters.topics;
    final filtered = masters.topics.where((topic) => topic.areaId == area.id).toList(growable: false);
    if (filtered.isNotEmpty) return filtered;
    return masters.topics.where((topic) => topic.name.trim().toLowerCase() == 'general').toList(growable: false);
  }

  T? _findDefault<T>(List<T> items, String preferred, String Function(T item) label) {
    final normalizedPreferred = _normalizedCommand(preferred);
    for (final item in items) {
      if (_normalizedCommand(label(item)) == normalizedPreferred) return item;
    }
    for (final item in items) {
      if (_normalizedCommand(label(item)) == 'general') return item;
    }
    return items.firstOrNull;
  }

  Future<void> _saveNote({bool? calendarCreatedOverride, String? actionStatusOverride, bool popAfterSave = true}) async {
    if (_isSaving) return;
    if (_isActionMode) _syncActionContent();
    _parseDueText();
    final title = _isActionMode && _actionTitleController.text.trim().isNotEmpty ? _actionTitleController.text.trim() : _titleController.text.trim();
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
        content: _isActionMode ? _actionDescriptionController.text.trim() : content,
        source: _isActionMode ? 'voice_action' : 'voice_dictation',
        createdAt: now,
        updatedAt: now,
        syncStatus: attachments.isEmpty ? SyncStatus.uploaded : SyncStatus.pending,
        userId: uid,
        deviceId: await _firebaseSyncService.readDeviceId(),
        attachmentsCount: attachments.length,
        voiceTranscription: _isActionMode ? _actionDescriptionController.text.trim() : content,
        captureMode: _isActionMode ? 'voice_action' : 'voice_note',
        isActionCandidate: _isActionMode,
        actionStatus: _isActionMode ? (actionStatusOverride ?? 'pending_review') : null,
        actionText: _isActionMode ? _actionDescriptionController.text.trim() : null,
        actionTitle: _isActionMode ? _actionTitleController.text.trim() : null,
        actionDescription: _isActionMode ? _actionDescriptionController.text.trim() : null,
        actionDueText: _isActionMode && actionDueText.isNotEmpty ? actionDueText : null,
        parsedDueAt: _isActionMode ? _parsedDueAt : null,
        parsedDueConfidence: _isActionMode ? _parsedDueConfidence : null,
        calendarEventCandidate: _isActionMode,
        calendarCreated: calendarCreatedOverride ?? false,
        calendarEventId: null,
      );
      if (attachments.isEmpty) {
        await _firebaseSyncService.createTextNote(note);
      } else {
        await _firebaseSyncService.createNoteWithAttachments(note: note, attachments: attachments);
      }
      if (!mounted) return;
      _showMessage(_isActionMode ? 'Acción de voz guardada para revisión.' : 'Nota de voz guardada para sincronización.');
      if (popAfterSave) Navigator.pop(context);
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

  Future<void> _createCalendarEvent({bool saveSummary = true}) async {
    _parseDueText();
    final dueAt = _parsedDueAt;
    if (dueAt == null) {
      _showMessage('No he entendido la fecha. Dime cuándo quieres recordarlo.');
      setState(() => _assistantStep = 2);
      await _speak('No he entendido la fecha. Dime cuándo quieres recordarlo.');
      await _runStep(VoiceAssistantStep.actionDate);
      return;
    }
    final title = _actionTitleController.text.trim();
    if (title.isEmpty) return _showMessage('El título de la acción es obligatorio');
    if (!Platform.isAndroid) return _showMessage('Calendar Intent solo está disponible en Android');
    final endAt = dueAt.add(const Duration(minutes: 30));
    final intent = AndroidIntent(
      action: 'android.intent.action.INSERT',
      type: 'vnd.android.cursor.item/event',
      arguments: {
        'title': title,
        'description': _actionDescriptionController.text.trim(),
        'beginTime': dueAt.millisecondsSinceEpoch,
        'endTime': endAt.millisecondsSinceEpoch,
        'allDay': false,
        'hasAlarm': true,
      },
    );
    try {
      await intent.launch();
    } catch (error) {
      debugPrint('No se pudo abrir Calendar Intent: $error');
      _showMessage('No se pudo abrir Calendar. Puedes guardar la acción en Nexus.');
      return;
    }
    if (saveSummary) {
      await _saveActionSummary(calendarCreated: true, status: 'sent_to_calendar');
    }
  }

  Future<void> _saveActionSummary({required bool calendarCreated, required String status}) async {
    if (!_isActionMode) return;
    await _saveNote(calendarCreatedOverride: calendarCreated, actionStatusOverride: status);
  }

  void _showMessage(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  String _statusLabel() => switch (_status) {
        _VoiceNoteStatus.choosing => 'Elige qué quieres crear',
        _VoiceNoteStatus.ready => 'Preparado',
        _VoiceNoteStatus.listening => _dictationStateLabel,
        _VoiceNoteStatus.transcribing => 'Procesando respuesta...',
        _VoiceNoteStatus.speaking => 'Hablando...',
        _VoiceNoteStatus.preparing => 'Prepárate para responder...',
        _VoiceNoteStatus.waiting => 'Esperando respuesta',
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
              _selectedArea ??= _findDefault(masters.areas, 'archivo', (area) => area.name);
              _selectedType ??= _findDefault(masters.types, _isActionMode ? 'tarea' : 'nota', (type) => type.name);
              final topics = _topicsForSelectedArea(masters);
              if (_selectedTopic == null || !topics.contains(_selectedTopic)) {
                _selectedTopic = _findDefault(topics, 'anotaciones', (topic) => topic.name);
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
                      Text('Asistente manos libres: la app pregunta, escucha y avanza paso a paso. Los botones quedan como fallback.', style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
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
                      Text('Paso actual: ${_assistantStepState.name} · Pregunta actual: ${_currentPrompt.isEmpty ? (_mode == null ? '¿Quieres crear una nota o una acción?' : _promptForStep()) : _currentPrompt} · ${_statusMessage.isEmpty ? '' : 'Aviso: $_statusMessage · '}Respuesta detectada: ${_lastDetectedAnswer.isEmpty ? '—' : _lastDetectedAnswer} · Estado: ${_statusLabel()}', style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                      const SizedBox(height: 8),
                      if (_mode != null) Text('Modo seleccionado: ${_isActionMode ? 'Acción' : 'Nota'}', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      if (_mode != null) const SizedBox(height: 8),
                      if (_mode != null) Text('Paso actual: ${_assistantStep + 1} de ${_lastAssistantStep + 1} · Asistente: ${_assistantMode == VoiceAssistantMode.handsFree ? 'manos libres' : 'normal'}', style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                      const SizedBox(height: 16),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        FilledButton.icon(onPressed: _isSaving || _mode == null ? null : _startAssistant, icon: const Icon(Icons.play_arrow), label: const Text('Iniciar asistente')),
                        OutlinedButton.icon(onPressed: _isSaving || _mode == null ? null : _repeatStep, icon: const Icon(Icons.replay), label: const Text('Repetir paso')),
                        OutlinedButton.icon(onPressed: _isSaving || _mode == null || (_isRecording && _speech.isListening) ? null : _continueDictating, icon: const Icon(Icons.mic_none), label: const Text('Continuar dictando')),
                        FilledButton.tonalIcon(onPressed: _isSaving || _mode == null ? null : _finishStep, icon: const Icon(Icons.skip_next), label: const Text('Finalizar paso')),
                      ]),
                      const SizedBox(height: 12),
                      Card(child: ListTile(
                        leading: Icon(_isRecording ? Icons.graphic_eq : Icons.info_outline, color: AppColors.primaryBlue),
                        title: Text(_statusLabel()),
                        subtitle: Text('Pregunta: ${_currentPrompt.isEmpty ? _promptForStep() : _currentPrompt} · ${_statusMessage.isEmpty ? '' : 'Aviso: $_statusMessage · '}Respuesta detectada: ${_lastDetectedAnswer.isEmpty ? '—' : _lastDetectedAnswer} · Duración: ${_formatDuration(_recordingDuration)}${_hasRecordedAudio ? ' · Audio original listo' : ''}${_ttsAvailable ? '' : ' · TTS no disponible'}'),
                      )),
                      const SizedBox(height: 16),
                      NoteTextField(controller: _titleController, label: _isActionMode ? 'Título de la acción' : 'Título', hintText: _defaultTitle, textInputAction: TextInputAction.next),
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
                      if (!_isActionMode) ...[
                        if (_assistantStep == 2)
                          NoteTextField(
                            controller: _confirmationCommandController,
                            label: 'Comando de confirmación',
                            hintText: 'guardar, repetir o cancelar',
                          )
                        else
                          NoteTextField(
                            controller: _contentController,
                            label: _contentLabel,
                            hintText: 'La transcripción aparecerá aquí. Revísela antes de guardar.',
                            keyboardType: TextInputType.multiline,
                            minLines: 6,
                            maxLines: 12,
                          ),
                      ] else ...[
                        Text('Asistente de acción: paso ${_assistantStep + 1} de 4', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 12),
                        if (_assistantStep == 0)
                          NoteTextField(controller: _actionTitleController, label: '¿Qué quieres hacer?', hintText: 'Llamar a Johana', textInputAction: TextInputAction.next),
                        if (_assistantStep == 1)
                          NoteTextField(controller: _actionDescriptionController, label: 'Añade detalles', hintText: 'Preguntar si mañana el pedido de Free está hecho', keyboardType: TextInputType.multiline, minLines: 4, maxLines: 8),
                        if (_assistantStep == 2) ...[
                          NoteTextField(controller: _actionDueTextController, label: '¿Cuándo quieres recordarlo?', hintText: 'mañana a las ocho y media', textInputAction: TextInputAction.next),
                          const SizedBox(height: 8),
                          Builder(builder: (_) {
                            final parsed = parseSpanishDueText(_actionDueTextController.text, now: DateTime.now());
                            _parsedDueAt = parsed.dueAt; _parsedDueConfidence = parsed.confidence;
                            return Text(parsed.dueAt == null ? 'No se pudo interpretar la fecha' : 'Fecha interpretada: ${_formatDue(parsed.dueAt!)}');
                          }),
                        ],
                        if (_assistantStep == 3) Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Revisión final', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          Text('Título: ${_actionTitleController.text.trim()}'),
                          Text('Descripción: ${_actionDescriptionController.text.trim()}'),
                          Text(_parsedDueAt == null ? 'No se pudo interpretar la fecha' : 'Fecha interpretada: ${_formatDue(_parsedDueAt!)}'),
                          const SizedBox(height: 8),
                          NoteTextField(
                            controller: _confirmationCommandController,
                            label: 'Comando reconocido',
                            hintText: 'calendario, guardar, repetir o cancelar',
                          ),
                        ]))),
                        const SizedBox(height: 12),
                        Row(children: [
                          if (_assistantStep > 0) Expanded(child: OutlinedButton(onPressed: _isSaving || _isRecording ? null : () => setState(() => _assistantStep--), child: const Text('Atrás'))),
                          if (_assistantStep > 0) const SizedBox(width: 12),
                          if (_assistantStep < 3) Expanded(child: FilledButton(onPressed: _isSaving || _isRecording ? null : _finishStep, child: const Text('Siguiente'))),
                        ]),
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
                        onPressed: _isSaving || _isRecording || _mode == null ? null : () => _saveNote(),
                        icon: _isSaving ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.check_circle_outline),
                        label: Text(_isSaving ? 'Guardando...' : (_isActionMode ? 'Guardar como nota en Nexus' : 'Guardar nota')),
                      ),
                      if (_isActionMode) ...[
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _isSaving || _isRecording || _assistantStep != 3 ? null : () => _createCalendarEvent(saveSummary: true),
                          icon: const Icon(Icons.calendar_month_outlined),
                          label: const Text('Crear en Calendar'),
                        ),
                      ],
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
