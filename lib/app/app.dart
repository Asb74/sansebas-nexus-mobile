import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../features/share/models/shared_capture_payload.dart';
import '../features/share/screens/share_capture_screen.dart';
import '../features/share/services/share_intent_service.dart';
import 'routes.dart';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

class SansebasNexusMobileApp extends StatefulWidget {
  const SansebasNexusMobileApp({super.key});

  @override
  State<SansebasNexusMobileApp> createState() => _SansebasNexusMobileAppState();
}

class _SansebasNexusMobileAppState extends State<SansebasNexusMobileApp> {
  StreamSubscription<SharedCapturePayload>? _shareSubscription;

  @override
  void initState() {
    super.initState();
    ShareIntentService.instance.start();
    _shareSubscription = ShareIntentService.instance.payloads.listen(_openShareCapture);
  }

  @override
  void dispose() {
    _shareSubscription?.cancel();
    super.dispose();
  }

  void _openShareCapture(SharedCapturePayload payload) {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) return;
    navigator.push(MaterialPageRoute<void>(builder: (_) => ShareCaptureScreen(payload: payload)));
  }

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
