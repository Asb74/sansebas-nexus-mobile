import 'package:flutter/material.dart';

import '../../features/notes/models/sync_status.dart';

class AppColors {
  const AppColors._();

  static const primaryBlue = Color(0xFF1D4ED8);
  static const primaryBlueDark = Color(0xFF1E3A8A);
  static const primaryBlueLight = Color(0xFFDBEAFE);
  static const background = Color(0xFFF8FAFC);
  static const surface = Color(0xFFFFFFFF);
  static const textPrimary = Color(0xFF0F172A);
  static const textSecondary = Color(0xFF64748B);
  static const border = Color(0xFFE2E8F0);

  static const pending = Color(0xFFF59E0B);
  static const uploading = Color(0xFF3B82F6);
  static const uploaded = Color(0xFF10B981);
  static const imported = Color(0xFF6366F1);
  static const error = Color(0xFFEF4444);

  static Color forSyncStatus(SyncStatus status) {
    return switch (status) {
      SyncStatus.pending => pending,
      SyncStatus.uploading => uploading,
      SyncStatus.uploaded => uploaded,
      SyncStatus.imported => imported,
      SyncStatus.error => error,
    };
  }
}
