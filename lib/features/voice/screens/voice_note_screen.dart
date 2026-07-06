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

enum VoiceCommandIntent { save, cancel, repeat, repeatTitle, repeatContent, repeatDate, calendar, note, action, unknown }

enum VoiceAssistantState { askMode, askTitle, askContent, askDate, confirm, save, cancel, finished }

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
  if (hasAny(const ['repetir fecha', 'repetir hora', 'repetir recordatorio', 'cambiar fecha', 'cambiar hora'])) return VoiceCommandIntent.repeatDate;
  if (hasAny(const ['empezar de nuevo', 'repetir todo', 'repetir', 'repite'])) return VoiceCommandIntent.repeat;
  if (hasAny(const ['cancelar', 'cancela', 'salir', 'descartar', 'no'])) return VoiceCommandIntent.cancel;
  if (hasAny(const ['crear nota', 'nota'])) return VoiceCommandIntent.note;
  if (hasAny(const ['accion', 'tarea', 'recordatorio'])) return VoiceCommandIntent.action;
  return VoiceCommandIntent.unknown;
}

class _VoiceListeningConfig {
  const _VoiceListeningConfig({
    required this.minimumListeningTime,
    required this.silenceAfterSpeech,
    required this.maxListeningTime,
    this.allowContinueDictating = false,
  });

  final Duration minimumListeningTime;
  final Duration silenceAfterSpeech;
  final Duration maxListeningTime;
  final bool allowContinueDictating;
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
  VoiceAssistantState _assistantState = VoiceAssistantState.askMode;
  String _currentPrompt = '';
  String _lastDetectedAnswer = '';
  int _attemptCounter = 0;
  bool _returnToConfirmAfterEdit = false;
  bool _ttsAvailable = true;
  bool _isSaving = false;
  bool _attachOriginalAudio = false;
  DateTime? _recordingStartedAt;
  DateTime? _listeningStartedAt;
  DateTime? _speechFirstDetectedAt;
  Duration _recordingDuration = Duration.zero;
  Timer? _durationTimer;
  String? _audioPath;
  int? _audioDurationSeconds;
  String _finalSpeechBuffer = '';
  String _lastPartialSpeech = '';
  bool _manualStopRequested = false;
  bool _speechUnavailable = false;
  Timer? _autoAdvanceTimer;
  Timer? _maxListeningTimer;
  String _dictationStateLabel = 'Finalizado';
  DateTime? _parsedDueAt;
  double? _parsedDueConfidence;

  @override
  void initState() {
    super.initState();
    _mastersFuture = _masterService.loadMasters();
    _draftMobileNoteId = _uuid.v4();
    unawaited(_configureTts().then((_) => _startModeChoice()));
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _autoAdvanceTimer?.cancel();
    _maxListeningTimer?.cancel();
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
  bool get _isConfirmationStep => _assistantStep == _lastAssistantStep;
  bool get _isLongContentStep => _mode != null && ((_isActionMode && _assistantStep == 1) || (!_isActionMode && _assistantStep == 1));

  _VoiceListeningConfig get _listeningConfig {
    if (_isLongContentStep) {
      return const _VoiceListeningConfig(
        minimumListeningTime: Duration(milliseconds: 4000),
        silenceAfterSpeech: Duration(milliseconds: 2500),
        maxListeningTime: Duration(seconds: 60),
        allowContinueDictating: true,
      );
    }
    if (_mode != null && ((_isActionMode && (_assistantStep == 0 || _assistantStep == 2)) || (!_isActionMode && _assistantStep == 0))) {
      return const _VoiceListeningConfig(
        minimumListeningTime: Duration(milliseconds: 2500),
        silenceAfterSpeech: Duration(milliseconds: 1200),
        maxListeningTime: Duration(seconds: 10),
      );
    }
    return const _VoiceListeningConfig(
      minimumListeningTime: Duration(milliseconds: 2500),
      silenceAfterSpeech: Duration(milliseconds: 900),
      maxListeningTime: Duration(seconds: 7),
    );
  }

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

  Future<void> _speak(String text) async {
    if (!mounted) return;
    setState(() {
      _currentPrompt = text;
      _status = _VoiceNoteStatus.speaking;
    });
    if (!_ttsAvailable) {
      setState(() => _status = _VoiceNoteStatus.preparing);
      return;
    }
    try {
      debugPrint('Asistente voz - TTS start state=$_assistantState prompt="$text"');
      await _tts.stop();
      await _tts.speak(text);
      debugPrint('Asistente voz - TTS end state=$_assistantState');
    } catch (error) {
      debugPrint('No se pudo reproducir prompt TTS: $error');
      if (mounted) setState(() => _ttsAvailable = false);
    } finally {
      if (mounted && _status == _VoiceNoteStatus.speaking) {
        setState(() => _status = _VoiceNoteStatus.preparing);
      }
    }
  }

  String _formatDue(DateTime dueAt) => '${dueAt.day.toString().padLeft(2, '0')}/${dueAt.month.toString().padLeft(2, '0')}/${dueAt.year} ${dueAt.hour.toString().padLeft(2, '0')}:${dueAt.minute.toString().padLeft(2, '0')}';

  VoiceAssistantState _stateForStep() {
    if (_mode == null) return VoiceAssistantState.askMode;
    if (_assistantStep == 0) return VoiceAssistantState.askTitle;
    if (_assistantStep == 1) return VoiceAssistantState.askContent;
    if (_isActionMode && _assistantStep == 2) return VoiceAssistantState.askDate;
    return VoiceAssistantState.confirm;
  }

  void _syncStateFromStep() {
    _assistantState = _stateForStep();
  }

  String _promptForStep() {
    _syncStateFromStep();
    if (_mode == null) return '¿Quieres crear una nota o una acción?';
    if (!_isActionMode) {
      return switch (_assistantStep) {
        0 => 'Título de la nota',
        1 => '¿Qué quieres anotar?',
        _ => 'Nota lista. Di guardar, repetir o cancelar.',
      };
    }
    return switch (_assistantStep) {
      0 => 'Título de la acción',
      1 => 'Describe la acción',
      2 => '¿Cuándo quieres recordarlo?',
      _ => 'Acción lista. Di calendario, guardar, repetir o cancelar.',
    };
  }

  Future<void> _startModeChoice() async {
    if (!mounted || _mode != null || _isSaving) return;
    setState(() {
      _assistantMode = VoiceAssistantMode.handsFree;
      _status = _VoiceNoteStatus.choosing;
    });
    await _speak('¿Quieres crear una nota o una acción?');
    await _startRecordingAfterTts();
  }

  void _selectMode(VoiceCaptureMode mode, {bool autoStart = false}) {
    if (_isSaving || _isRecording) return;
    setState(() {
      _mode = mode;
      _status = _VoiceNoteStatus.ready;
      _selectedArea = null;
      _selectedTopic = null;
      _selectedType = null;
      _assistantStep = 0;
      _assistantState = VoiceAssistantState.askTitle;
      _currentPrompt = '';
      _lastDetectedAnswer = '';
      _attemptCounter = 0;
      _returnToConfirmAfterEdit = false;
      _finalSpeechBuffer = '';
      _lastPartialSpeech = '';
      _titleController.clear();
      _contentController.clear();
      _actionTitleController.clear();
      _actionDescriptionController.clear();
      _actionDueTextController.clear();
      _confirmationCommandController.clear();
      _parsedDueAt = null;
      _parsedDueConfidence = null;
    });
    if (autoStart) {
      _confirmationCommandController.clear();
      unawaited(_startAssistant());
    }
  }
  bool get _hasRecordedAudio => _audioPath != null;

  Future<void> _startAssistant() async {
    if (_mode == null || _isSaving) return;
    setState(() => _status = _VoiceNoteStatus.ready);
    await _speak(_promptForStep());
    await _startRecordingAfterTts();
  }

  Future<void> _repeatStep() async {
    if (_mode == null || _isSaving) return;
    if (_isRecording) await _stopRecording(markReview: false);
    _activeDictationController.clear();
    _commitActiveController();
    await _speak(_promptForStep());
    await _startRecordingAfterTts();
  }

  Future<void> _continueDictating() async {
    if (_mode == null || _isSaving) return;
    if (_isRecording && !_speech.isListening) {
      _manualStopRequested = false;
      await _listenContinuously(localeId: await _preferredSpanishLocaleId());
      if (mounted) setState(() => _dictationStateLabel = 'Escuchando...');
      return;
    }
    if (!_isRecording) await _startRecordingAfterTts();
  }

  bool _isCommandOnly(String text) {
    final normalized = normalizeVoiceCommand(text);
    const commands = {'guardar', 'guarda', 'guardalo', 'cancelar', 'cancela', 'repetir', 'repite', 'repetir todo', 'si', 'no'};
    return commands.contains(normalized);
  }

  bool _looksInvalidSpeech(String text) {
    final normalized = normalizeVoiceCommand(text);
    if (normalized.isEmpty) return true;
    if (!_isConfirmationStep && _isCommandOnly(normalized)) return true;
    final words = normalized.split(' ').where((word) => word.isNotEmpty).toList();
    return words.length == 1 && words.single.length <= 2;
  }

  Future<void> _retryCurrentQuestion({String message = 'No te he oído.'}) async {
    _attemptCounter++;
    _activeDictationController.clear();
    _finalSpeechBuffer = '';
    _lastPartialSpeech = '';
    if (_attemptCounter >= 3) {
      await _speak('He tenido problemas para entenderte. ¿Quieres continuar manualmente?');
      if (mounted) setState(() => _status = _VoiceNoteStatus.ready);
      return;
    }
    await _speak('$message ${_promptForStep()}.');
    await _startRecordingAfterTts();
  }

  String _monthName(int month) => const [
        'enero',
        'febrero',
        'marzo',
        'abril',
        'mayo',
        'junio',
        'julio',
        'agosto',
        'septiembre',
        'octubre',
        'noviembre',
        'diciembre',
      ][month - 1];

  String _confirmationSummary() {
    if (!_isActionMode) {
      return 'He entendido: Título: ${_titleController.text.trim()}. Contenido: ${_contentController.text.trim()}. ¿Quieres guardar, repetir o cancelar?';
    }
    _parseDueText();
    final dueAt = _parsedDueAt;
    final interpreted = dueAt == null
        ? 'No he podido interpretar una fecha exacta.'
        : 'Se guardará el día ${dueAt.day} de ${_monthName(dueAt.month)} a las ${dueAt.hour.toString().padLeft(2, '0')}:${dueAt.minute.toString().padLeft(2, '0')}.';
    return 'He entendido: Título: ${_actionTitleController.text.trim()}. Acción: ${_actionDescriptionController.text.trim()}. Fecha: ${_actionDueTextController.text.trim()}. $interpreted ¿Quieres guardar, repetir o cancelar?';
  }

  Future<void> _finishStep({String reason = 'manual o final'}) async {
    final listened = _listeningStartedAt == null ? Duration.zero : DateTime.now().difference(_listeningStartedAt!);
    debugPrint('Asistente voz - process response state=$_assistantState reason=$reason listened=${listened.inMilliseconds}ms minMet=${listened >= _listeningConfig.minimumListeningTime}');
    if (_isRecording) await _stopRecording(markReview: false);
    _commitActiveController();
    final spokenText = _activeDictationController.text;
    final intent = detectVoiceCommand(spokenText);
    debugPrint('Asistente voz - comando detectado=$intent textPresent=${spokenText.trim().isNotEmpty}');
    setState(() => _lastDetectedAnswer = spokenText.trim());
    if (_looksInvalidSpeech(spokenText)) {
      await _retryCurrentQuestion(message: spokenText.trim().isEmpty ? 'No te he oído.' : 'No he entendido la respuesta.');
      return;
    }
    if (_mode == null) {
      if (intent == VoiceCommandIntent.note) { _selectMode(VoiceCaptureMode.note, autoStart: true); return; }
      if (intent == VoiceCommandIntent.action) { _selectMode(VoiceCaptureMode.action, autoStart: true); return; }
      await _retryCurrentQuestion(message: 'No he entendido la respuesta.');
      return;
    }
    if (_isConfirmationStep && await _handleVoiceCommand(intent)) return;
    if (_returnToConfirmAfterEdit) {
      setState(() {
        _assistantStep = _lastAssistantStep;
        _attemptCounter = 0;
        _returnToConfirmAfterEdit = false;
        _syncStateFromStep();
      });
      await _speak(_confirmationSummary());
      await _startRecordingAfterTts();
    } else if (_assistantStep < _lastAssistantStep) {
      setState(() {
        _assistantStep++;
        _attemptCounter = 0;
        _syncStateFromStep();
      });
      await _speak(_isConfirmationStep ? _confirmationSummary() : _promptForStep());
      await _startRecordingAfterTts();
    } else {
      await _speak(_confirmationSummary());
      await _startRecordingAfterTts();
    }
  }

  Future<void> _startRecording() async {
    try {
      _autoAdvanceTimer?.cancel();
      _maxListeningTimer?.cancel();
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
      final now = DateTime.now();
      setState(() {
        _status = _VoiceNoteStatus.listening;
        _recordingStartedAt = now;
        _listeningStartedAt = now;
        _speechFirstDetectedAt = null;
        _recordingDuration = Duration.zero;
        _audioPath = path;
        _audioDurationSeconds = null;
      });

      _manualStopRequested = false;
      _speechUnavailable = false;
      _primeSpeechBuffer();
      await _listenContinuously(localeId: localeId);
      debugPrint('Asistente voz - listen start state=$_assistantState min=${_listeningConfig.minimumListeningTime.inMilliseconds}ms silence=${_listeningConfig.silenceAfterSpeech.inMilliseconds}ms max=${_listeningConfig.maxListeningTime.inMilliseconds}ms listening=${_speech.isListening}');
      _scheduleMaxListeningTimeout();

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

  Future<void> _startRecordingAfterTts() async {
    if (!mounted) return;
    debugPrint('Asistente voz - prep before listen state=$_assistantState');
    setState(() => _status = _VoiceNoteStatus.preparing);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted || _isSaving) return;
    await _startRecording();
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

  Future<void> _stopRecording({bool markReview = true}) async {
    setState(() => _status = _VoiceNoteStatus.transcribing);
    _durationTimer?.cancel();
    _autoAdvanceTimer?.cancel();
    _maxListeningTimer?.cancel();
    final startedAt = _recordingStartedAt;
    try {
      _manualStopRequested = true;
      await _speech.stop();
      final stoppedPath = await _audioRecorder.isRecording()
          ? await _audioRecorder.stop()
          : _audioPath;
      if (!mounted) return;
      setState(() {
        _status = markReview ? _VoiceNoteStatus.review : _VoiceNoteStatus.ready;
        _audioPath = stoppedPath ?? _audioPath;
        _audioDurationSeconds = startedAt == null ? null : DateTime.now().difference(startedAt).inSeconds;
        _recordingStartedAt = null;
        _listeningStartedAt = null;
        _speechFirstDetectedAt = null;
        _dictationStateLabel = 'Finalizado';
      });
      _commitActiveController();
      _showMessage(markReview ? 'Texto listo para revisar' : 'Paso finalizado');
    } catch (error) {
      debugPrint('No se pudo detener dictado. Error exacto: $error');
      if (!mounted) return;
      setState(() => _status = _VoiceNoteStatus.review);
      _showMessage('Transcripción lista para revisar');
    }
  }

  TextEditingController get _activeDictationController {
    if (_mode == null) return _confirmationCommandController;
    if (!_isActionMode) {
      return switch (_assistantStep) {
        0 => _titleController,
        1 => _contentController,
        _ => _confirmationCommandController,
      };
    }
    return switch (_assistantStep) {
      0 => _actionTitleController,
      1 => _actionDescriptionController,
      2 => _actionDueTextController,
      3 => _confirmationCommandController,
      _ => _confirmationCommandController,
    };
  }

  void _primeSpeechBuffer() {
    final text = _activeDictationController.text.trim();
    _finalSpeechBuffer = text;
    _lastPartialSpeech = '';
    _dictationStateLabel = 'Escuchando...';
  }

  Future<void> _listenContinuously({String? localeId}) async {
    final config = _listeningConfig;
    await _speech.listen(
      onResult: _onSpeechResult,
      listenMode: ListenMode.dictation,
      partialResults: true,
      listenFor: config.maxListeningTime,
      pauseFor: config.silenceAfterSpeech,
      localeId: localeId,
    );
  }

  void _scheduleMaxListeningTimeout() {
    _maxListeningTimer?.cancel();
    final config = _listeningConfig;
    _maxListeningTimer = Timer(config.maxListeningTime, () {
      if (!mounted || !_isRecording || _manualStopRequested) return;
      final text = _activeDictationController.text.trim();
      debugPrint('Asistente voz - max listen reached state=$_assistantState textPresent=${text.isNotEmpty}');
      if (text.isEmpty) {
        unawaited(_finishStep(reason: 'maxListeningTime sin texto'));
      } else {
        _scheduleAutoAdvance(reason: 'maxListeningTime con texto');
      }
    });
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    if (!mounted) return;
    var recognized = result.recognizedWords.trim();
    if (recognized.isEmpty) return;
    _speechFirstDetectedAt ??= DateTime.now();
    debugPrint('Asistente voz - texto ${result.finalResult ? 'final' : 'parcial'} state=$_assistantState length=${recognized.length}');
    if (result.finalResult && result.confidence > 0 && result.confidence < .25) {
      _scheduleAutoAdvance(reason: 'confianza baja');
      return;
    }
    final finishDictation = _mode != null && !_isConfirmationStep && normalizeVoiceCommand(recognized).split(' ').contains('finalizar');
    if (finishDictation) {
      recognized = recognized.replaceAll(RegExp(r'\bfinalizar\b', caseSensitive: false), '').trim();
      if (recognized.isEmpty) {
        unawaited(_finishStep(reason: 'comando finalizar'));
        return;
      }
    }
    if (result.finalResult) {
      if (!_finalSpeechBuffer.endsWith(recognized)) {
        _finalSpeechBuffer = [_finalSpeechBuffer, recognized].where((part) => part.trim().isNotEmpty).join(' ');
      }
      _lastPartialSpeech = '';
    } else {
      _lastPartialSpeech = recognized;
    }
    final merged = [_finalSpeechBuffer, _lastPartialSpeech].where((part) => part.trim().isNotEmpty).join(' ').trim();
    final controller = _activeDictationController;
    controller.text = merged;
    controller.selection = TextSelection.collapsed(offset: controller.text.length);
    _commitActiveController();
    if (finishDictation) {
      unawaited(_finishStep(reason: 'comando finalizar'));
    } else if (result.finalResult) {
      _scheduleAutoAdvance(reason: 'finalResult');
    }
  }

  void _scheduleAutoAdvance({String reason = 'silenceAfterSpeech'}) {
    _autoAdvanceTimer?.cancel();
    final config = _listeningConfig;
    final listened = _listeningStartedAt == null ? Duration.zero : DateTime.now().difference(_listeningStartedAt!);
    final minimumRemaining = config.minimumListeningTime - listened;
    final delay = minimumRemaining.isNegative ? config.silenceAfterSpeech : minimumRemaining;
    debugPrint('Asistente voz - scheduling process reason=$reason delay=${delay.inMilliseconds}ms listened=${listened.inMilliseconds}ms minMet=${listened >= config.minimumListeningTime} voiceStarted=${_speechFirstDetectedAt != null}');
    _autoAdvanceTimer = Timer(delay, () {
      if (mounted && _isRecording && !_manualStopRequested) {
        setState(() => _dictationStateLabel = 'Procesando respuesta...');
        unawaited(_finishStep(reason: reason));
      }
    });
  }

  void _onSpeechStatus(String status) {
    if (!mounted) return;
    if (status == 'notListening' || status == 'done') {
      debugPrint('Dictado voz - listening false, estado speech_to_text: $status');
      if (_isRecording && !_manualStopRequested && !_speechUnavailable) {
        final text = _activeDictationController.text.trim();
        if (text.isEmpty) {
          final listened = _listeningStartedAt == null ? Duration.zero : DateTime.now().difference(_listeningStartedAt!);
          if (listened < _listeningConfig.maxListeningTime) {
            debugPrint('Asistente voz - STT ended without text before max; waiting maxListeningTime listened=${listened.inMilliseconds}ms');
            return;
          }
        }
        setState(() => _dictationStateLabel = 'Procesando respuesta...');
        _scheduleAutoAdvance(reason: 'speech status $status');
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
      final listened = _listeningStartedAt == null ? Duration.zero : DateTime.now().difference(_listeningStartedAt!);
      if (listened < _listeningConfig.maxListeningTime && _activeDictationController.text.trim().isEmpty) {
        debugPrint('Asistente voz - speech error before max; waiting maxListeningTime listened=${listened.inMilliseconds}ms');
        return;
      }
      unawaited(_finishStep(reason: 'speech error ${error.errorMsg}'));
    } else if (error.permanent) {
      _speechUnavailable = true;
      _showMessage('Reconocimiento de voz no disponible en este dispositivo');
    }
  }

  void _commitActiveController() {
    if (_isActionMode) {
      _syncActionContent();
      if (_assistantStep == 2) _parseDueText();
    }
  }

  String _normalizedCommand(String text) => normalizeVoiceCommand(text);

  Future<bool> _handleVoiceCommand(VoiceCommandIntent intent) async {
    if (intent == VoiceCommandIntent.cancel) {
      await _speak('Cancelado');
      if (mounted) Navigator.pop(context);
      return true;
    }
    if (intent == VoiceCommandIntent.repeat) {
      _resetCurrentFlow();
      await _speak(_promptForStep());
      await _startRecordingAfterTts();
      return true;
    }
    if (intent == VoiceCommandIntent.repeatTitle) {
      await _repeatSpecificStep(0);
      return true;
    }
    if (intent == VoiceCommandIntent.repeatContent) {
      await _repeatSpecificStep(1);
      return true;
    }
    if (_isActionMode && intent == VoiceCommandIntent.repeatDate) {
      await _repeatSpecificStep(2);
      return true;
    }
    if (_isActionMode && intent == VoiceCommandIntent.calendar) {
      if (_parsedDueAt == null) {
        await _speak('No he entendido la fecha. Dime cuándo quieres recordarlo.');
        setState(() => _assistantStep = 2);
        await _startRecordingAfterTts();
        return true;
      }
      await _createCalendarEvent(saveSummary: true);
      return true;
    }
    if (intent == VoiceCommandIntent.save) {
      await _speak(_isActionMode ? 'Acción guardada' : 'Nota guardada');
      await _saveNote();
      return true;
    }
    return false;
  }

  Future<void> _repeatSpecificStep(int step) async {
    setState(() {
      _assistantStep = step;
      _attemptCounter = 0;
      _returnToConfirmAfterEdit = true;
      _confirmationCommandController.clear();
      if (step == 0) {
        _titleController.clear();
        _actionTitleController.clear();
      } else if (step == 1) {
        _contentController.clear();
        _actionDescriptionController.clear();
      } else if (step == 2) {
        _actionDueTextController.clear();
        _parsedDueAt = null;
        _parsedDueConfidence = null;
      }
      _syncStateFromStep();
    });
    await _speak(_promptForStep());
    await _startRecordingAfterTts();
  }

  void _resetCurrentFlow() {
    setState(() {
      _assistantStep = 0;
      _assistantState = VoiceAssistantState.askTitle;
      _attemptCounter = 0;
      _returnToConfirmAfterEdit = false;
      _titleController.clear();
      _contentController.clear();
      _actionTitleController.clear();
      _actionDescriptionController.clear();
      _actionDueTextController.clear();
      _confirmationCommandController.clear();
      _parsedDueAt = null;
      _parsedDueConfidence = null;
      _finalSpeechBuffer = '';
      _lastPartialSpeech = '';
    });
  }


  void _syncActionContent() {
    _titleController.text = _actionTitleController.text;
    _contentController.text = _actionDescriptionController.text;
  }

  void _parseDueText() {
    final parsed = parseSpanishDueText(_actionDueTextController.text, now: DateTime.now());
    setState(() {
      _parsedDueAt = parsed.dueAt;
      _parsedDueConfidence = parsed.confidence;
    });
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
      await _startRecordingAfterTts();
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
                      Text('Paso actual: ${_assistantState.name} · Pregunta actual: ${_currentPrompt.isEmpty ? (_mode == null ? '¿Quieres crear una nota o una acción?' : _promptForStep()) : _currentPrompt} · Respuesta detectada: ${_lastDetectedAnswer.isEmpty ? '—' : _lastDetectedAnswer} · Estado: ${_statusLabel()}', style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
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
                        subtitle: Text('Pregunta: ${_currentPrompt.isEmpty ? _promptForStep() : _currentPrompt} · Respuesta detectada: ${_lastDetectedAnswer.isEmpty ? '—' : _lastDetectedAnswer} · Duración: ${_formatDuration(_recordingDuration)}${_hasRecordedAudio ? ' · Audio original listo' : ''}${_ttsAvailable ? '' : ' · TTS no disponible'}'),
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
