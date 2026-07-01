import 'package:flutter/material.dart';

import 'routes.dart';
import '../core/theme/app_theme.dart';

class SansebasNexusMobileApp extends StatelessWidget {
  const SansebasNexusMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sansebas Nexus Mobile',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      initialRoute: AppRoutes.splash,
      routes: AppRoutes.routes,
    );
  }
}
