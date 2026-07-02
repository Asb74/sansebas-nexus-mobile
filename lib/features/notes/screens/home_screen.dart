import 'package:flutter/material.dart';

import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

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
