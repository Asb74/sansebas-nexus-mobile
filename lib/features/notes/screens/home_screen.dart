import 'package:flutter/material.dart';

import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../voice/models/recording_session.dart';
import '../../voice/services/recording_session_store.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _recordingStore = RecordingSessionStore();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerPendingRecording());
  }

  Future<void> _offerPendingRecording() async {
    final pending = await _recordingStore.pendingSessions();
    if (!mounted || pending.isEmpty) return;
    final session = pending.first;
    final action = await showDialog<_RecoveryAction>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Grabación pendiente'),
        content: const Text('Se encontró una grabación pendiente. El audio está guardado en este dispositivo.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, _RecoveryAction.delete), child: const Text('Eliminar')),
          TextButton(onPressed: () => Navigator.pop(context, _RecoveryAction.keep), child: const Text('Conservar para después')),
          FilledButton(onPressed: () => Navigator.pop(context, _RecoveryAction.continueProcessing), child: const Text('Continuar procesamiento')),
        ],
      ),
    );
    if (!mounted) return;
    if (action == _RecoveryAction.delete) {
      await _confirmDelete(session);
    } else if (action == _RecoveryAction.continueProcessing) {
      await Navigator.pushNamed(context, AppRoutes.voiceNote, arguments: session.id);
    }
  }

  Future<void> _confirmDelete(RecordingSession session) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('¿Eliminar grabación?'),
            content: const Text('Esta acción elimina la copia local y no se puede deshacer.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Eliminar')),
            ],
          ),
        ) ??
        false;
    if (confirmed) await _recordingStore.deleteSession(session);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Inicio')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x1A1D4ED8),
                          blurRadius: 24,
                          offset: Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Image.asset(
                        'assets/icon/icono_app.png',
                        width: 96,
                        height: 96,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Sansebas Nexus Mobile',
                    textAlign: TextAlign.center,
                    style: textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Captura rápida para Sansebas Nexus',
                    textAlign: TextAlign.center,
                    style: textTheme.titleMedium?.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 40),
                  FilledButton.icon(
                    onPressed: () =>
                        Navigator.pushNamed(context, AppRoutes.newNote),
                    icon: const Icon(Icons.note_add_outlined),
                    label: const Text('Nueva nota'),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    onPressed: () =>
                        Navigator.pushNamed(context, AppRoutes.voiceNote),
                    icon: const Icon(Icons.mic_none_outlined),
                    label: const Text('Dictar nota'),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () =>
                        Navigator.pushNamed(context, AppRoutes.notesList),
                    icon: const Icon(Icons.list_alt_outlined),
                    label: const Text('Lista de notas'),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () =>
                        Navigator.pushNamed(context, AppRoutes.settings),
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Configuración'),
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

enum _RecoveryAction { continueProcessing, keep, delete }
