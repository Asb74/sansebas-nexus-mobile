import 'package:flutter/material.dart';

import '../features/auth/screens/login_screen.dart';
import '../features/notes/screens/home_screen.dart';
import '../features/notes/screens/new_note_screen.dart';
import '../features/notes/screens/note_detail_screen.dart';
import '../features/notes/screens/notes_list_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/voice/screens/voice_note_screen.dart';
import '../features/splash/splash_screen.dart';

class AppRoutes {
  const AppRoutes._();

  static const splash = '/splash';
  static const login = '/login';
  static const home = '/';
  static const newNote = '/notes/new';
  static const notesList = '/notes';
  static const voiceNote = '/notes/voice';
  static const noteDetail = '/notes/detail';
  static const settings = '/settings';

  static Map<String, WidgetBuilder> get routes => {
        splash: (_) => const SplashScreen(),
        login: (context) {
          final error = ModalRoute.of(context)?.settings.arguments as String?;
          return LoginScreen(initialError: error);
        },
        home: (_) => const HomeScreen(),
        newNote: (_) => const NewNoteScreen(),
        notesList: (_) => const NotesListScreen(),
        voiceNote: (_) => const VoiceNoteScreen(),
        noteDetail: (_) => const NoteDetailScreen(),
        settings: (_) => const SettingsScreen(),
      };
}
