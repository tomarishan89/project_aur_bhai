import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'llm/llm_slot.dart';
import 'secure_secret_store.dart';

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
  static const String _keyResponseWord = 'byok_resp_word';
  static const String _keyVoiceGender = 'byok_voice_gender';
  static const String _keyExternalPrefix = 'byok_ext_';
  static const String _migratedFlag = 'byok_secrets_migrated_v1';
  static const String _keyMultiSlot = 'byok_multi_slot_enabled';
  static const String _keySlotsJson = 'byok_slots_v1';

  String _apiProvider = "Google Gemini";
  String _apiKey = "";
  String _modelName = "gemini-2.0-flash";
  String _customUrl = "";

  int _maxRecordingSeconds = 10;
  String _responseMode = "Spoken Word";
  bool _vibrateOnWake = false;
  String _responseWord = "Haan bhai";
  String _voiceGender = "Male";
  bool _multiSlotEnabled = false;
  final Map<LlmSlot, ByokSlotConfig> _slots = {};

  final Map<String, String> _externalPlatformKeys = {};

  bool _isLoaded = false;
  final SecureSecretStore _secrets;

  ByokService({SecureSecretStore? secretStore})
      : _secrets = secretStore ??
            (Platform.environment.containsKey('FLUTTER_TEST')
                ? MemorySecureSecretStore()
                : FlutterSecureSecretStore()) {
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
  String get responseWord => _responseWord;
  String get voiceGender => _voiceGender;

  bool get hasApiKey {
    if (_multiSlotEnabled) {
      return configForSlot(LlmSlot.defaultSlot).hasKey;
    }
    return _apiKey.trim().isNotEmpty;
  }

  bool get multiSlotEnabled => _multiSlotEnabled;

  /// Effective config for [slot], falling back to default / legacy single key.
  ByokSlotConfig configForSlot(LlmSlot slot) {
    if (!_multiSlotEnabled) {
      return ByokSlotConfig(
        provider: _apiProvider,
        apiKey: _apiKey,
        modelName: _modelName,
        customUrl: _customUrl,
      );
    }
    final dedicated = _slots[slot];
    if (dedicated != null && dedicated.hasKey) return dedicated;
    final def = _slots[LlmSlot.defaultSlot];
    if (def != null && def.hasKey) return def;
    return ByokSlotConfig(
      provider: _apiProvider,
      apiKey: _apiKey,
      modelName: _modelName,
      customUrl: _customUrl,
    );
  }

  bool hasKeyForSlot(LlmSlot slot) => configForSlot(slot).hasKey;

  /// Dedicated slot config without fallback (null / empty key ⇒ use default).
  ByokSlotConfig? dedicatedSlotOrNull(LlmSlot slot) => _slots[slot];

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
      _modelName = prefs.getString(_keyModelName) ?? "gemini-2.0-flash";
      _customUrl = prefs.getString(_keyCustomUrl) ?? "";

      _maxRecordingSeconds = prefs.getInt(_keyMaxRecSeconds) ?? 10;
      _responseMode = prefs.getString(_keyResponseMode) ?? "Spoken Word";
      _vibrateOnWake = prefs.getBool(_keyVibrate) ?? false;
      _responseWord = prefs.getString(_keyResponseWord) ?? "Haan bhai";
      _voiceGender = prefs.getString(_keyVoiceGender) ?? "Male";

      await _migratePlaintextSecretsIfNeeded(prefs);

      _apiKey = await _secrets.read(_keyApiKey) ?? '';
      _externalPlatformKeys.clear();
      for (final platform in ExternalPlatform.values) {
        final key =
            await _secrets.read('$_keyExternalPrefix${platform.name}');
        if (key != null && key.isNotEmpty) {
          _externalPlatformKeys[platform.name] = key;
        }
      }

      _multiSlotEnabled = prefs.getBool(_keyMultiSlot) ?? false;
      await _loadSlots();

      _isLoaded = true;
      notifyListeners();
      debugPrint(
          '[ByokService] Loaded configuration. Provider: $_apiProvider, Model: $_modelName multiSlot=$_multiSlotEnabled');
    } catch (e) {
      debugPrint('[ByokService] Load error: $e');
    }
  }

  Future<void> _loadSlots() async {
    _slots.clear();
    final raw = await _secrets.read(_keySlotsJson);
    if (raw == null || raw.isEmpty) {
      // Seed default slot from legacy single-provider fields.
      _slots[LlmSlot.defaultSlot] = ByokSlotConfig(
        provider: _apiProvider,
        apiKey: _apiKey,
        modelName: _modelName,
        customUrl: _customUrl,
      );
      return;
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final e in map.entries) {
        final slot = LlmSlot.fromId(e.key);
        if (e.value is Map) {
          _slots[slot] =
              ByokSlotConfig.fromJson(Map<String, dynamic>.from(e.value as Map));
        }
      }
    } catch (e) {
      debugPrint('[ByokService] Slot load error: $e');
    }
  }

  Future<void> setMultiSlotEnabled(bool enabled) async {
    _multiSlotEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMultiSlot, enabled);
    if (enabled && !_slots.containsKey(LlmSlot.defaultSlot)) {
      _slots[LlmSlot.defaultSlot] = ByokSlotConfig(
        provider: _apiProvider,
        apiKey: _apiKey,
        modelName: _modelName,
        customUrl: _customUrl,
      );
      await _persistSlots();
    }
    notifyListeners();
  }

  Future<void> updateSlot(LlmSlot slot, ByokSlotConfig config) async {
    _slots[slot] = config;
    if (slot == LlmSlot.defaultSlot) {
      _apiProvider = config.provider;
      _apiKey = config.apiKey;
      _modelName = config.modelName;
      _customUrl = config.customUrl;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyProvider, config.provider);
      await prefs.setString(_keyModelName, config.modelName);
      await prefs.setString(_keyCustomUrl, config.customUrl);
      if (config.apiKey.isNotEmpty) {
        await _secrets.write(_keyApiKey, config.apiKey);
      } else {
        await _secrets.delete(_keyApiKey);
      }
    }
    await _persistSlots();
    notifyListeners();
  }

  Future<void> _persistSlots() async {
    final encoded = jsonEncode({
      for (final e in _slots.entries) e.key.id: e.value.toJson(),
    });
    await _secrets.write(_keySlotsJson, encoded);
  }

  /// Move API / platform keys out of SharedPreferences into secure storage.
  Future<void> _migratePlaintextSecretsIfNeeded(SharedPreferences prefs) async {
    if (prefs.getBool(_migratedFlag) == true) return;

    final legacyApi = prefs.getString(_keyApiKey);
    if (legacyApi != null && legacyApi.isNotEmpty) {
      await _secrets.write(_keyApiKey, legacyApi);
      await prefs.remove(_keyApiKey);
    }

    for (final platform in ExternalPlatform.values) {
      final prefKey = '$_keyExternalPrefix${platform.name}';
      final legacy = prefs.getString(prefKey);
      if (legacy != null && legacy.isNotEmpty) {
        await _secrets.write(prefKey, legacy);
        await prefs.remove(prefKey);
      }
    }

    await prefs.setBool(_migratedFlag, true);
    debugPrint('[ByokService] Migrated plaintext secrets → secure storage');
  }

  Future<void> updateConfig({
    required String provider,
    required String apiKey,
    required String modelName,
    required String customUrl,
    int maxRecordingSeconds = 10,
    String responseMode = "Spoken Word",
    bool vibrateOnWake = false,
    String responseWord = "Haan bhai",
    String voiceGender = "Male",
    Map<String, String>? externalPlatformKeys,
  }) async {
    _apiProvider = provider;
    _apiKey = apiKey;
    _modelName = modelName;
    _customUrl = customUrl;
    _maxRecordingSeconds = maxRecordingSeconds;
    _responseMode = responseMode;
    _vibrateOnWake = vibrateOnWake;
    _responseWord = responseWord.trim().isEmpty ? "Haan bhai" : responseWord.trim();
    _voiceGender = voiceGender;

    if (externalPlatformKeys != null) {
      _externalPlatformKeys
        ..clear()
        ..addAll(externalPlatformKeys);
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyProvider, provider);
      await prefs.setString(_keyModelName, modelName);
      await prefs.setString(_keyCustomUrl, customUrl);
      await prefs.setInt(_keyMaxRecSeconds, maxRecordingSeconds);
      await prefs.setString(_keyResponseMode, responseMode);
      await prefs.setBool(_keyVibrate, vibrateOnWake);
      await prefs.setString(_keyResponseWord, _responseWord);
      await prefs.setString(_keyVoiceGender, _voiceGender);
      // Never persist API keys in SharedPreferences (ENG5).
      await prefs.remove(_keyApiKey);

      if (apiKey.isNotEmpty) {
        await _secrets.write(_keyApiKey, apiKey);
      } else {
        await _secrets.delete(_keyApiKey);
      }

      for (final platform in ExternalPlatform.values) {
        final value = _externalPlatformKeys[platform.name] ?? '';
        final secretKey = '$_keyExternalPrefix${platform.name}';
        await prefs.remove(secretKey);
        if (value.isNotEmpty) {
          await _secrets.write(secretKey, value);
        } else {
          await _secrets.delete(secretKey);
        }
      }

      await prefs.setBool(_migratedFlag, true);
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
