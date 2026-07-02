import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import 'routes.dart';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

class SansebasNexusMobileApp extends StatefulWidget {
  const SansebasNexusMobileApp({super.key});

  @override
  State<SansebasNexusMobileApp> createState() => _SansebasNexusMobileAppState();
}

class _SansebasNexusMobileAppState extends State<SansebasNexusMobileApp> {
  // TODO(share-intent): Re-enable Android share capture in a later phase with
  // a stable implementation that does not block Android/Kotlin builds.

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'Sansebas Nexus Mobile',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      initialRoute: AppRoutes.splash,
      routes: AppRoutes.routes,
    );
  }
}
