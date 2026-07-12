import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Supported external platforms for agent egress (Arch v3.7 slot 13).
enum ExternalPlatform {
  twitter('Twitter / X'),
  facebook('Facebook'),
  instagram('Instagram'),
  youtube('YouTube'),
  threads('Threads'),
  webhook('Custom Webhook');

  final String label;
  const ExternalPlatform(this.label);

  static ExternalPlatform? fromKey(String key) {
    for (final p in ExternalPlatform.values) {
      if (p.name == key) return p;
    }
    return null;
  }
}

class ByokService extends ChangeNotifier {
  static const String _keyProvider = 'byok_provider';
  static const String _keyApiKey = 'byok_api_key';
  static const String _keyModelName = 'byok_model_name';
  static const String _keyCustomUrl = 'byok_custom_url';

  static const String _keyMaxRecSeconds = 'byok_max_rec';
  static const String _keyResponseMode = 'byok_resp_mode';
  static const String _keyVibrate = 'byok_vibrate';
  static const String _keyExternalPrefix = 'byok_ext_';

  String _apiProvider = "Google Gemini";
  String _apiKey = "";
  String _modelName = "gemini-2.0-flash";
  String _customUrl = "";

  int _maxRecordingSeconds = 10;
  String _responseMode = "Spoken Word";
  bool _vibrateOnWake = false;

  final Map<String, String> _externalPlatformKeys = {};

  bool _isLoaded = false;

  ByokService() {
    _loadSettings();
  }

  bool get isLoaded => _isLoaded;
  String get apiProvider => _apiProvider;
  String get apiKey => _apiKey;
  String get modelName => _modelName;
  String get customUrl => _customUrl;

  int get maxRecordingSeconds => _maxRecordingSeconds;
  String get responseMode => _responseMode;
  bool get vibrateOnWake => _vibrateOnWake;

  bool get hasApiKey => _apiKey.trim().isNotEmpty;

  String externalKeyFor(ExternalPlatform platform) =>
      _externalPlatformKeys[platform.name] ?? '';

  bool hasExternalKey(ExternalPlatform platform) =>
      externalKeyFor(platform).trim().isNotEmpty;

  Map<String, String> get externalPlatformKeys =>
      Map.unmodifiable(_externalPlatformKeys);

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _apiProvider = prefs.getString(_keyProvider) ?? "Google Gemini";
      _apiKey = prefs.getString(_keyApiKey) ?? "";
      _modelName = prefs.getString(_keyModelName) ?? "gemini-2.0-flash";
      _customUrl = prefs.getString(_keyCustomUrl) ?? "";

      _maxRecordingSeconds = prefs.getInt(_keyMaxRecSeconds) ?? 10;
      _responseMode = prefs.getString(_keyResponseMode) ?? "Spoken Word";
      _vibrateOnWake = prefs.getBool(_keyVibrate) ?? false;

      _externalPlatformKeys.clear();
      for (final platform in ExternalPlatform.values) {
        final key = prefs.getString('$_keyExternalPrefix${platform.name}');
        if (key != null && key.isNotEmpty) {
          _externalPlatformKeys[platform.name] = key;
        }
      }

      _isLoaded = true;
      notifyListeners();
      debugPrint(
          '[ByokService] Loaded configuration. Provider: $_apiProvider, Model: $_modelName');
    } catch (e) {
      debugPrint('[ByokService] Load error: $e');
    }
  }

  Future<void> updateConfig({
    required String provider,
    required String apiKey,
    required String modelName,
    required String customUrl,
    int maxRecordingSeconds = 10,
    String responseMode = "Spoken Word",
    bool vibrateOnWake = false,
    Map<String, String>? externalPlatformKeys,
  }) async {
    _apiProvider = provider;
    _apiKey = apiKey;
    _modelName = modelName;
    _customUrl = customUrl;
    _maxRecordingSeconds = maxRecordingSeconds;
    _responseMode = responseMode;
    _vibrateOnWake = vibrateOnWake;

    if (externalPlatformKeys != null) {
      _externalPlatformKeys
        ..clear()
        ..addAll(externalPlatformKeys);
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyProvider, provider);
      await prefs.setString(_keyApiKey, apiKey);
      await prefs.setString(_keyModelName, modelName);
      await prefs.setString(_keyCustomUrl, customUrl);
      await prefs.setInt(_keyMaxRecSeconds, maxRecordingSeconds);
      await prefs.setString(_keyResponseMode, responseMode);
      await prefs.setBool(_keyVibrate, vibrateOnWake);

      for (final platform in ExternalPlatform.values) {
        final value = _externalPlatformKeys[platform.name] ?? '';
        if (value.isNotEmpty) {
          await prefs.setString('$_keyExternalPrefix${platform.name}', value);
        } else {
          await prefs.remove('$_keyExternalPrefix${platform.name}');
        }
      }

      notifyListeners();
      debugPrint(
          '[ByokService] Updated config: Provider: $provider, Model: $modelName');
    } catch (e) {
      debugPrint('[ByokService] Update error: $e');
    }
  }
}

final byokServiceProvider = Provider<ByokService>((ref) {
  return ByokService();
});
