import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;
import 'package:path_provider/path_provider.dart';
import 'package:porcupine_flutter/porcupine.dart';
import 'package:porcupine_flutter/porcupine_error.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'secure_secret_store.dart';
import 'wake_foreground_task.dart';

/// On-device wake listen (MS-OFFLINE-WAKE). Listen path never persists audio.
class WakeWordService extends ChangeNotifier {
  static const _prefsListen = 'wake_listen_enabled';
  static const _prefsAccessKey = 'picovoice_access_key';
  static const _prefsAcknowledgedPrivacy = 'wake_privacy_ack';

  WakeWordService({SecureSecretStore? secretStore})
      : _secrets = secretStore ??
            (Platform.environment.containsKey('FLUTTER_TEST')
                ? MemorySecureSecretStore()
                : FlutterSecureSecretStore()) {
    unawaited(_load());
  }

  final SecureSecretStore _secrets;
  PorcupineManager? _manager;
  bool _listenEnabled = false;
  bool _isListening = false;
  bool _privacyAck = false;
  String? _lastError;
  String _accessKey = '';
  VoidCallback? onWakeDetected;

  /// True while Porcupine/VoiceProcessor is running (RAM-only frames).
  bool get isListening => _isListening;
  bool get listenEnabled => _listenEnabled;
  bool get privacyAcknowledged => _privacyAck;
  String? get lastError => _lastError;
  bool get hasAccessKey => _accessKey.trim().isNotEmpty;

  /// Test / audit hook: listen path must never schedule file writes.
  bool get listenPathPersistsAudio => false;

  /// True when a custom Aur Bhai `.ppn` is loaded (not interim Jarvis).
  bool _usingCustomKeyword = false;
  bool get usingCustomKeyword => _usingCustomKeyword;

  /// Resolves custom keyword path: documents/wake/aur_bhai.ppn or asset copy.
  Future<String?> resolveCustomKeywordPath() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final docFile = File('${docs.path}/wake/aur_bhai.ppn');
      if (await docFile.exists()) return docFile.path;
    } catch (_) {}
    try {
      final data = await rootBundle.load('assets/wake/aur_bhai.ppn');
      final tmp = await getTemporaryDirectory();
      final out = File('${tmp.path}/aur_bhai.ppn');
      await out.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      return out.path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _listenEnabled = prefs.getBool(_prefsListen) ?? false;
    _privacyAck = prefs.getBool(_prefsAcknowledgedPrivacy) ?? false;
    _accessKey = await _secrets.read(_prefsAccessKey) ?? '';
    notifyListeners();
    if (_listenEnabled && _privacyAck && hasAccessKey) {
      await startListening();
    }
  }

  Future<void> acknowledgePrivacy() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsAcknowledgedPrivacy, true);
    _privacyAck = true;
    notifyListeners();
  }

  Future<void> setAccessKey(String key) async {
    _accessKey = key.trim();
    if (_accessKey.isEmpty) {
      await _secrets.delete(_prefsAccessKey);
    } else {
      await _secrets.write(_prefsAccessKey, _accessKey);
    }
    notifyListeners();
    if (_listenEnabled) {
      await stopListening();
      await startListening();
    }
  }

  Future<void> setListenEnabled(bool enabled) async {
    if (enabled && !_privacyAck) {
      _lastError = 'Acknowledge wake privacy before enabling listen.';
      notifyListeners();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsListen, enabled);
    _listenEnabled = enabled;
    notifyListeners();
    if (enabled) {
      await startListening();
    } else {
      await stopListening();
    }
  }

  Future<void> startListening() async {
    if (!AppConfig.wakeWordFeatureEnabled) return;
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      _lastError = 'Wake listen is supported on Android/iOS only.';
      notifyListeners();
      return;
    }
    if (!_listenEnabled || !_privacyAck) return;
    if (!hasAccessKey) {
      _lastError = AppConfig.wakeNeedsAccessKey;
      notifyListeners();
      return;
    }
    if (_isListening) return;

    try {
      await WakeForegroundTask.start();
      await _manager?.delete();
      void onDetect(_) {
        assert(!listenPathPersistsAudio);
        onWakeDetected?.call();
      }

      void onErr(PorcupineException e) {
        _lastError = e.message;
        notifyListeners();
      }

      final customPath = await resolveCustomKeywordPath();
      if (customPath != null) {
        _usingCustomKeyword = true;
        _manager = await PorcupineManager.fromKeywordPaths(
          _accessKey,
          [customPath],
          onDetect,
          errorCallback: onErr,
        );
        debugPrint(
          '[WakeWord] Custom keyword ${AppConfig.wakeWordPhraseLabel} @ $customPath',
        );
      } else {
        _usingCustomKeyword = false;
        _manager = await PorcupineManager.fromBuiltInKeywords(
          _accessKey,
          [BuiltInKeyword.JARVIS],
          onDetect,
          errorCallback: onErr,
        );
        debugPrint(
          '[WakeWord] Interim ${AppConfig.wakeWordInterimBuiltIn} '
          '(place assets/wake/aur_bhai.ppn or documents/wake/aur_bhai.ppn for Aur Bhai)',
        );
      }
      await _manager!.start();
      _isListening = true;
      _lastError = null;
      debugPrint('[WakeWord] Listen started (RAM-only; no audio persist).');
      notifyListeners();
    } catch (e) {
      _lastError = '$e';
      _isListening = false;
      await WakeForegroundTask.stop();
      debugPrint('[WakeWord] start failed: $e');
      notifyListeners();
    }
  }

  bool _disposed = false;

  Future<void> stopListening() async {
    try {
      await _manager?.stop();
      await _manager?.delete();
    } catch (e) {
      debugPrint('[WakeWord] stop: $e');
    }
    _manager = null;
    _isListening = false;
    await WakeForegroundTask.stop();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stopListening());
    super.dispose();
  }
}

final wakeWordServiceProvider =
    ChangeNotifierProvider<WakeWordService>((ref) {
  // ChangeNotifierProvider disposes the notifier; do not double-dispose.
  return WakeWordService();
});
