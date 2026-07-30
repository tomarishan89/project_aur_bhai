import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/wake_handshake_config.dart';
import 'llm/gemini_provider.dart';
import 'llm/llm_capability_catalog.dart';
import 'llm/llm_model_catalog.dart';
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
  static const String _keyThinkingLevel = 'byok_thinking_level';
  static const String _keyMaxOutputTokens = 'byok_max_output_tokens';

  static const String _keyMaxRecSeconds = 'byok_max_rec';
  static const String _keyResponseMode = 'byok_resp_mode';
  static const String _keyTapAck = 'byok_tap_ack';
  static const String _keyHoldAck = 'byok_hold_ack';
  static const String _keyVibrate = 'byok_vibrate';
  static const String _keyResponseWord = 'byok_resp_word';
  static const String _keyVoiceGender = 'byok_voice_gender';
  static const String _keyMediaControls = 'media_controls_to_aur_bhai';
  static const String _keyExternalPrefix = 'byok_ext_';
  static const String _migratedFlag = 'byok_secrets_migrated_v1';
  static const String _keyMultiSlot = 'byok_multi_slot_enabled';
  static const String _keySlotsJson = 'byok_slots_v1';

  String _apiProvider = "Google Gemini";
  String _apiKey = "";
  String _modelName = GeminiProvider.defaultModelId;
  String _customUrl = "";
  String? _thinkingLevel;
  int? _maxOutputTokens;

  int _maxRecordingSeconds = 10;
  String _tapResponseMode = WakeHandshakeConfig.tapSpoken;
  String _holdResponseMode = WakeHandshakeConfig.holdHaptic;
  bool _vibrateOnWake = false;
  String _responseWord = "Haan bhai";
  String _voiceGender = "Male";
  /// Android: Play/Pause/Next from buds/car/headset → handshake (default on).
  bool _mediaControlsToAurBhai = true;
  bool _multiSlotEnabled = false;
  final Map<LlmSlot, ByokSlotConfig> _slots = {};

  final Map<String, String> _externalPlatformKeys = {};

  bool _isLoaded = false;
  final SecureSecretStore _secrets;

  ByokService({SecureSecretStore? secretStore})
    : _secrets =
          secretStore ??
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
  String? get thinkingLevel => _thinkingLevel;
  int? get maxOutputTokens => _maxOutputTokens;

  int get maxRecordingSeconds => _maxRecordingSeconds;

  /// Tap / short-press ack (legacy alias of [tapResponseMode]).
  String get responseMode => _tapResponseMode;
  String get tapResponseMode => _tapResponseMode;
  String get holdResponseMode => _holdResponseMode;
  bool get vibrateOnWake => _vibrateOnWake;
  String get responseWord => _responseWord;
  String get voiceGender => _voiceGender;
  bool get mediaControlsToAurBhai => _mediaControlsToAurBhai;

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
      return _clampedSlot(
        ByokSlotConfig(
          provider: _apiProvider,
          apiKey: _apiKey,
          modelName: _modelName,
          customUrl: _customUrl,
          thinkingLevel: _thinkingLevel,
          maxOutputTokens: _maxOutputTokens,
        ),
      );
    }
    final dedicated = _slots[slot];
    if (dedicated != null && dedicated.hasKey) {
      return _clampedSlot(dedicated);
    }
    final def = _slots[LlmSlot.defaultSlot];
    if (def != null && def.hasKey) return _clampedSlot(def);
    return _clampedSlot(
      ByokSlotConfig(
        provider: _apiProvider,
        apiKey: _apiKey,
        modelName: _modelName,
        customUrl: _customUrl,
        thinkingLevel: _thinkingLevel,
        maxOutputTokens: _maxOutputTokens,
      ),
    );
  }

  ByokSlotConfig _clampedSlot(ByokSlotConfig cfg) {
    final thinking = LlmCapabilityCatalog.clampThinking(
      cfg.provider,
      cfg.modelName,
      cfg.thinkingLevel,
    );
    final maxTok = cfg.maxOutputTokens == null
        ? null
        : LlmCapabilityCatalog.clampMaxTokens(
            cfg.provider,
            cfg.modelName,
            cfg.maxOutputTokens,
          );
    if (thinking == cfg.thinkingLevel && maxTok == cfg.maxOutputTokens) {
      return cfg;
    }
    return cfg.copyWith(
      thinkingLevel: thinking,
      maxOutputTokens: maxTok,
      clearThinkingLevel: thinking == null && cfg.thinkingLevel != null,
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
      _modelName =
          prefs.getString(_keyModelName) ?? GeminiProvider.defaultModelId;
      _customUrl = prefs.getString(_keyCustomUrl) ?? "";
      _thinkingLevel = prefs.getString(_keyThinkingLevel);
      _maxOutputTokens = prefs.getInt(_keyMaxOutputTokens);
      final migrated = LlmModelCatalog.migrateDeprecated(
        _apiProvider,
        _modelName,
      );
      if (migrated != null) {
        _modelName = migrated;
        await prefs.setString(_keyModelName, migrated);
        debugPrint(
          '[ByokService] Migrated deprecated model → $migrated',
        );
      }
      _thinkingLevel = LlmCapabilityCatalog.clampThinking(
        _apiProvider,
        _modelName,
        _thinkingLevel,
      );
      if (_maxOutputTokens != null) {
        _maxOutputTokens = LlmCapabilityCatalog.clampMaxTokens(
          _apiProvider,
          _modelName,
          _maxOutputTokens,
        );
      }

      _maxRecordingSeconds = prefs.getInt(_keyMaxRecSeconds) ?? 10;
      final legacyMode = prefs.getString(_keyResponseMode);
      final tapStored = prefs.getString(_keyTapAck);
      _tapResponseMode = WakeHandshakeConfig.normalizeTapAck(
        tapStored ?? legacyMode,
      );
      _holdResponseMode = WakeHandshakeConfig.normalizeHoldAck(
        prefs.getString(_keyHoldAck),
      );
      _vibrateOnWake = prefs.getBool(_keyVibrate) ?? false;
      _responseWord = prefs.getString(_keyResponseWord) ?? "Haan bhai";
      _voiceGender = prefs.getString(_keyVoiceGender) ?? "Male";
      _mediaControlsToAurBhai = prefs.getBool(_keyMediaControls) ?? true;

      await _migratePlaintextSecretsIfNeeded(prefs);

      _apiKey = await _secrets.read(_keyApiKey) ?? '';
      _externalPlatformKeys.clear();
      for (final platform in ExternalPlatform.values) {
        final key = await _secrets.read('$_keyExternalPrefix${platform.name}');
        if (key != null && key.isNotEmpty) {
          _externalPlatformKeys[platform.name] = key;
        }
      }

      _multiSlotEnabled = prefs.getBool(_keyMultiSlot) ?? false;
      await _loadSlots();

      _isLoaded = true;
      notifyListeners();
      debugPrint(
        '[ByokService] Loaded configuration. Provider: $_apiProvider, Model: $_modelName multiSlot=$_multiSlotEnabled',
      );
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
        thinkingLevel: _thinkingLevel,
        maxOutputTokens: _maxOutputTokens,
      );
      return;
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      var slotsChanged = false;
      for (final e in map.entries) {
        final slot = LlmSlot.fromId(e.key);
        if (e.value is Map) {
          var cfg = ByokSlotConfig.fromJson(
            Map<String, dynamic>.from(e.value as Map),
          );
          final migrated = LlmModelCatalog.migrateDeprecated(
            cfg.provider,
            cfg.modelName,
          );
          if (migrated != null) {
            cfg = cfg.copyWith(modelName: migrated);
            slotsChanged = true;
          }
          final clampedThinking = LlmCapabilityCatalog.clampThinking(
            cfg.provider,
            cfg.modelName,
            cfg.thinkingLevel,
          );
          if (clampedThinking != cfg.thinkingLevel) {
            cfg = cfg.copyWith(
              thinkingLevel: clampedThinking,
              clearThinkingLevel: clampedThinking == null,
            );
            slotsChanged = true;
          }
          _slots[slot] = cfg;
        }
      }
      if (slotsChanged) {
        await _persistSlots();
        debugPrint('[ByokService] Persisted migrated slot model ids');
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
        thinkingLevel: _thinkingLevel,
        maxOutputTokens: _maxOutputTokens,
      );
      await _persistSlots();
    }
    notifyListeners();
  }

  Future<void> updateSlot(LlmSlot slot, ByokSlotConfig config) async {
    final clamped = _clampedSlot(config);
    _slots[slot] = clamped;
    if (slot == LlmSlot.defaultSlot) {
      _apiProvider = clamped.provider;
      _apiKey = clamped.apiKey;
      _modelName = clamped.modelName;
      _customUrl = clamped.customUrl;
      _thinkingLevel = clamped.thinkingLevel;
      _maxOutputTokens = clamped.maxOutputTokens;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyProvider, clamped.provider);
      await prefs.setString(_keyModelName, clamped.modelName);
      await prefs.setString(_keyCustomUrl, clamped.customUrl);
      await _persistThinkingPrefs(prefs);
      if (clamped.apiKey.isNotEmpty) {
        await _secrets.write(_keyApiKey, clamped.apiKey);
      } else {
        await _secrets.delete(_keyApiKey);
      }
    }
    await _persistSlots();
    notifyListeners();
  }

  Future<void> _persistThinkingPrefs(SharedPreferences prefs) async {
    if (_thinkingLevel != null && _thinkingLevel!.isNotEmpty) {
      await prefs.setString(_keyThinkingLevel, _thinkingLevel!);
    } else {
      await prefs.remove(_keyThinkingLevel);
    }
    if (_maxOutputTokens != null) {
      await prefs.setInt(_keyMaxOutputTokens, _maxOutputTokens!);
    } else {
      await prefs.remove(_keyMaxOutputTokens);
    }
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

  Future<void> setMediaControlsToAurBhai(bool enabled) async {
    _mediaControlsToAurBhai = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMediaControls, enabled);
    notifyListeners();
  }

  Future<void> updateConfig({
    required String provider,
    required String apiKey,
    required String modelName,
    required String customUrl,
    String? thinkingLevel,
    int? maxOutputTokens,
    bool clearThinkingLevel = false,
    bool clearMaxOutputTokens = false,
    int maxRecordingSeconds = 10,
    String responseMode = "Spoken Word",
    String? tapResponseMode,
    String? holdResponseMode,
    bool vibrateOnWake = false,
    String responseWord = "Haan bhai",
    String voiceGender = "Male",
    bool? mediaControlsToAurBhai,
    Map<String, String>? externalPlatformKeys,
  }) async {
    _apiProvider = provider;
    _apiKey = apiKey;
    _modelName = modelName;
    _customUrl = customUrl;
    final prev = _slots[LlmSlot.defaultSlot];
    final nextThinking = clearThinkingLevel
        ? null
        : (thinkingLevel ?? _thinkingLevel ?? prev?.thinkingLevel);
    final nextMax = clearMaxOutputTokens
        ? null
        : (maxOutputTokens ?? _maxOutputTokens ?? prev?.maxOutputTokens);
    final clamped = _clampedSlot(
      ByokSlotConfig(
        provider: provider,
        apiKey: apiKey.isNotEmpty ? apiKey : (prev?.apiKey ?? ''),
        modelName: modelName,
        customUrl: customUrl,
        thinkingLevel: nextThinking,
        maxOutputTokens: nextMax,
      ),
    );
    _thinkingLevel = clamped.thinkingLevel;
    _maxOutputTokens = clamped.maxOutputTokens;
    _slots[LlmSlot.defaultSlot] = clamped;
    _maxRecordingSeconds = maxRecordingSeconds;
    _tapResponseMode = WakeHandshakeConfig.normalizeTapAck(
      tapResponseMode ?? responseMode,
    );
    if (holdResponseMode != null) {
      _holdResponseMode = WakeHandshakeConfig.normalizeHoldAck(
        holdResponseMode,
      );
    }
    _vibrateOnWake = vibrateOnWake;
    _responseWord = responseWord.trim().isEmpty
        ? "Haan bhai"
        : responseWord.trim();
    _voiceGender = voiceGender;
    if (mediaControlsToAurBhai != null) {
      _mediaControlsToAurBhai = mediaControlsToAurBhai;
    }

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
      await _persistThinkingPrefs(prefs);
      await prefs.setInt(_keyMaxRecSeconds, maxRecordingSeconds);
      await prefs.setString(_keyResponseMode, _tapResponseMode);
      await prefs.setString(_keyTapAck, _tapResponseMode);
      await prefs.setString(_keyHoldAck, _holdResponseMode);
      await prefs.setBool(_keyVibrate, vibrateOnWake);
      await prefs.setString(_keyResponseWord, _responseWord);
      await prefs.setString(_keyVoiceGender, _voiceGender);
      await prefs.setBool(_keyMediaControls, _mediaControlsToAurBhai);
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
      await _persistSlots();
      notifyListeners();
      debugPrint(
        '[ByokService] Updated config: Provider: $provider, Model: $modelName '
        'thinking=$_thinkingLevel maxTok=$_maxOutputTokens '
        'multiSlot=$_multiSlotEnabled',
      );
    } catch (e) {
      debugPrint('[ByokService] Update error: $e');
    }
  }
}

final byokServiceProvider = Provider<ByokService>((ref) {
  return ByokService();
});
