import 'package:flutter/material.dart';

import '../features/notes/screens/home_screen.dart';
import '../features/notes/screens/new_note_screen.dart';
import '../features/notes/screens/notes_list_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/splash/splash_screen.dart';

class AppRoutes {
  const AppRoutes._();

  static const splash = '/splash';
  static const home = '/';
  static const newNote = '/notes/new';
  static const notesList = '/notes';
  static const settings = '/settings';

  static Map<String, WidgetBuilder> get routes => {
        splash: (_) => const SplashScreen(),
        home: (_) => const HomeScreen(),
        newNote: (_) => const NewNoteScreen(),
        notesList: (_) => const NotesListScreen(),
        settings: (_) => const SettingsScreen(),
      };
}
