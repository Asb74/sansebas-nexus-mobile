import '../models/app_settings.dart';

class SettingsService {
  AppSettings _settings = AppSettings.defaults();

  Future<AppSettings> loadSettings() async {
    // Placeholder: return defaults until local persistence is introduced.
    return _settings;
  }

  Future<void> saveSettings(AppSettings settings) async {
    // Placeholder: keep settings in memory until persistence is introduced.
    _settings = settings;
  }

  Future<AppSettings> resetSettings() async {
    // Placeholder: reset in-memory settings to the corporate defaults.
    _settings = AppSettings.defaults();
    return _settings;
  }
}
