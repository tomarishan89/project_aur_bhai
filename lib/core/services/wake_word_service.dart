import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../config/wake_handshake_config.dart';
import 'open_wake_word_runtime.dart';
import 'wake_foreground_task.dart';
import 'wake_model_library.dart';

/// On-device wake listen via free openWakeWord (no Picovoice key).
/// Listen path never persists audio frames.
class WakeWordService extends ChangeNotifier {
  static const _prefsListen = 'wake_listen_enabled';
  static const _prefsListenMode = 'wake_listen_mode';
  static const _prefsAcknowledgedPrivacy = 'wake_privacy_ack';
  static const _prefsMatchThreshold = 'wake_match_threshold';
  /// Default soft-trigger confidence (0..1). Native engine still uses ~0.5
  /// with several consecutive frames; this gate is what the Match % chip uses.
  static const double defaultMatchThreshold = 0.55;

  WakeWordService({WakeModelLibrary? library}) : _library = library ?? WakeModelLibrary() {
    unawaited(_load());
  }

  final WakeModelLibrary _library;
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<AudioDevicesChangedEvent>? _devicesSub;
  bool _listenEnabled = false;
  bool _isListening = false;
  bool _privacyAck = false;
  String? _lastError;
  String _listenMode = WakeHandshakeConfig.listenAlwaysOn;
  DateTime? _lastWakeAt;
  String? _lastWakeLabel;
  double _lastWakeMatch = 0;
  bool _wasActivated = false;
  String? _downloadingId;
  double _downloadProgress = 0;
  bool _disposed = false;
  int _pcmChunks = 0;
  double _maxProbSeen = 0;
  /// Raw model score used for trigger (spikes; often 0 between frames).
  double _rawMatch = 0;
  /// Held score for the chip so 0→1→55% does not look broken.
  double _displayMatch = 0;
  DateTime? _displayHoldUntil;
  int _levelPeak = 0;
  int _recentPeakMax = 0;
  int _highProbStreak = 0;
  double _matchThreshold = defaultMatchThreshold;
  String _inputRouteLabel = 'Mic idle';
  String _inputRouteShort = 'Mic idle';
  String _inputRouteKind = 'idle';
  bool _restartingForRoute = false;
  bool _handingOff = false;
  bool _startInFlight = false;
  int _zeroPeakStreak = 0;
  DateTime? _lastSilentBtRestartAt;
  /// Set when we tear down SCO for handshake/TTS; next BT listen must reclaim.
  bool _scoNeedsReclaim = false;
  /// Bumped to abort an in-flight start when loud TTS kills SCO mid-reclaim.
  int _listenGen = 0;
  VoidCallback? onWakeDetected;

  WakeModelLibrary get library => _library;

  bool get isListening => _isListening;
  bool get listenEnabled => _listenEnabled;
  bool get privacyAcknowledged => _privacyAck;
  String? get lastError => _lastError;
  String get listenMode => _listenMode;
  bool get isAlwaysOn => _listenMode == WakeHandshakeConfig.listenAlwaysOn;
  String get activeModelId => _library.activeId;
  String get activePhraseLabel =>
      WakeHandshakeConfig.labelForWakeModel(_library.activeId);
  String? get downloadingId => _downloadingId;
  double get downloadProgress => _downloadProgress;

  /// Human label for the mic currently used by wake listen (not playback).
  String get inputRouteLabel => _inputRouteLabel;

  /// Compact label for the status bar (avoids shoving other cues off-screen).
  String get inputRouteShort => _inputRouteShort;

  /// Coarse kind: `bluetooth` | `wired` | `phone` | `default` | `idle` | `handoff`.
  String get inputRouteKind => _inputRouteKind;

  /// Wake mic released so handshake can record the command.
  bool get isHandingOff => _handingOff;

  /// Wake-match confidence for UI (held peak; not a smooth progress bar).
  double get liveMatch => _displayMatch;

  /// Recent PCM peak (0..32767) for "is the mic hearing me?" feedback.
  int get levelPeak => _levelPeak;

  /// `silent` | `low` | `ok` | `loud` — mic input level, not wake match.
  String get levelCue {
    if (!_isListening) return 'idle';
    if (_levelPeak < 40) return 'silent';
    if (_levelPeak < 400) return 'low';
    if (_levelPeak > 20000) return 'loud';
    return 'ok';
  }

  /// Soft wake trigger threshold (0..1). Shown as Match % in the status bar.
  double get matchThreshold => _matchThreshold;

  int get matchThresholdPercent =>
      (_matchThreshold * 100).clamp(35, 90).round();

  DateTime? get lastWakeAt => _lastWakeAt;
  String? get lastWakeLabel => _lastWakeLabel;

  /// Score at the last wake hit (for chip — activate outruns live %).
  double get lastWakeMatch => _lastWakeMatch;

  int get lastWakeMatchPercent =>
      (_lastWakeMatch * 100).clamp(0, 100).round();

  bool heardWakeRecently({Duration within = const Duration(seconds: 4)}) {
    final at = _lastWakeAt;
    if (at == null) return false;
    return DateTime.now().difference(at) <= within;
  }

  /// Audit hook: listen path must never schedule audio file writes.
  bool get listenPathPersistsAudio => false;

  /// @deprecated No AccessKey for openWakeWord; always true when feature on.
  bool get hasAccessKey => true;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _listenEnabled = prefs.getBool(_prefsListen) ?? false;
    _listenMode = WakeHandshakeConfig.normalizeListenMode(
      prefs.getString(_prefsListenMode),
    );
    if (prefs.getString(_prefsListenMode) == null && _listenEnabled) {
      _listenMode = WakeHandshakeConfig.listenAlwaysOn;
    }
    _privacyAck = prefs.getBool(_prefsAcknowledgedPrivacy) ?? false;
    _matchThreshold = _clampThreshold(
      prefs.getDouble(_prefsMatchThreshold) ?? defaultMatchThreshold,
    );
    await _library.load();
    notifyListeners();
    await _syncListeningToMode();
  }

  static double _clampThreshold(double v) => v.clamp(0.35, 0.90);

  /// Lower = easier wake (more false positives). Applies immediately.
  Future<void> setMatchThreshold(double value) async {
    _matchThreshold = _clampThreshold(value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefsMatchThreshold, _matchThreshold);
    notifyListeners();
  }

  Future<void> acknowledgePrivacy() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsAcknowledgedPrivacy, true);
    _privacyAck = true;
    notifyListeners();
  }

  Future<void> setListenMode(String mode) async {
    _listenMode = WakeHandshakeConfig.normalizeListenMode(mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsListenMode, _listenMode);
    _listenEnabled = isAlwaysOn;
    await prefs.setBool(_prefsListen, _listenEnabled);
    notifyListeners();
    await _syncListeningToMode();
  }

  /// Sets the active wake model (must already be installed).
  Future<void> setActiveWakeModel(String id) async {
    await _library.setActive(id);
    notifyListeners();
    if (_isListening) {
      await stopListening();
      await startListening();
    }
  }

  /// Backward-compatible name used by Settings save.
  Future<void> setBuiltinKeyword(String id) => setActiveWakeModel(id);

  String get builtinKeywordId => activeModelId;

  Future<void> setListenEnabled(bool enabled) async {
    if (enabled && !_privacyAck) {
      _lastError = 'Acknowledge wake privacy before enabling listen.';
      notifyListeners();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsListen, enabled);
    _listenEnabled = enabled;
    if (enabled) {
      _listenMode = WakeHandshakeConfig.listenAlwaysOn;
      await prefs.setString(_prefsListenMode, _listenMode);
    } else {
      _listenMode = WakeHandshakeConfig.listenOnDemand;
      await prefs.setString(_prefsListenMode, _listenMode);
    }
    notifyListeners();
    await _syncListeningToMode();
  }

  Future<void> downloadModel(String id) async {
    _downloadingId = id;
    _downloadProgress = 0;
    _lastError = null;
    notifyListeners();
    try {
      await _library.download(
        id,
        onProgress: (p) {
          _downloadProgress = p;
          notifyListeners();
        },
      );
    } catch (e) {
      _lastError = 'Download failed: $e';
      rethrow;
    } finally {
      _downloadingId = null;
      _downloadProgress = 0;
      notifyListeners();
    }
  }

  Future<void> deleteModel(String id) async {
    try {
      await _library.delete(id);
      _lastError = null;
    } catch (e) {
      _lastError = '$e';
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> _syncListeningToMode() async {
    if (isAlwaysOn && _listenEnabled && _privacyAck) {
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
    if (!isAlwaysOn || !_listenEnabled || !_privacyAck) {
      return;
    }
    if (_isListening || _startInFlight) return;
    _startInFlight = true;
    final gen = ++_listenGen;

    try {
      await WakeForegroundTask.start();
      if (gen != _listenGen) return;
      final shared = await _library.ensureSharedPaths();
      final wwPath = await _library.resolveActiveModelPath();
      final ok = OpenWakeWordRuntime.initFromPaths(
        melPath: shared.mel,
        embPath: shared.emb,
        wwPath: wwPath,
      );
      if (!ok) {
        throw StateError('openWakeWord engine failed to start');
      }

      if (!await _recorder.hasPermission()) {
        throw StateError('Microphone permission denied for wake listen');
      }
      if (gen != _listenGen) return;

      await _ensureAudioSessionForWake();
      var devices = await _recorder.listInputDevices();
      var pick = _preferWakeInputDevice(devices);
      final wantsBt = _isBluetoothPick(pick);
      var pinDevice = pick.device != null;
      // After yield/TTS we leave SCO dead while the SCO *device* still lists.
      // Pinning that zombie without reclaim => permanent 0%·mute (runtime).
      if (!kIsWeb && Platform.isAndroid && wantsBt && _scoNeedsReclaim) {
        final scoConnected = await _reclaimBluetoothScoForWake();
        if (gen != _listenGen) return;
        _scoNeedsReclaim = false;
        devices = await _recorder.listInputDevices();
        pick = _preferWakeInputDevice(devices);
        // Failed reclaim + pin = silent stream (runtime: peak~0).
        if (!scoConnected) {
          pick = (
            device: null,
            btPending: true,
            display: pick.display ?? pick.device,
          );
          pinDevice = false;
        } else {
          pinDevice = pick.device != null;
        }
      }
      // Label from display device; pin may be null so SCO can re-open cleanly.
      _setInputRoute(pick.display, btPending: pick.btPending || !pinDevice);

      _wasActivated = false;
      _handingOff = false;
      _pcmChunks = 0;
      _maxProbSeen = 0;
      _rawMatch = 0;
      _displayMatch = 0;
      _displayHoldUntil = null;
      _levelPeak = 0;
      _recentPeakMax = 0;
      _highProbStreak = 0;
      _zeroPeakStreak = 0;
      if (gen != _listenGen) return;
      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          device: pinDevice ? pick.device : null,
          // Keep streaming through focus ducks / BT handoffs.
          audioInterruption: AudioInterruptionMode.none,
          androidConfig: const AndroidRecordConfig(
            manageBluetooth: true,
            audioSource: AndroidAudioSource.voiceCommunication,
            audioManagerMode: AudioManagerMode.modeInCommunication,
          ),
        ),
      );
      if (gen != _listenGen) {
        try {
          await _recorder.stop();
        } catch (_) {}
        return;
      }
      _micSub = stream.listen(
        _onPcm,
        onError: (Object e) {
          _lastError = '$e';
          notifyListeners();
        },
      );

      _isListening = true;
      _lastError = null;
      debugPrint(
        '[WakeWord] listening for $activePhraseLabel via $_inputRouteLabel',
      );
      notifyListeners();
    } catch (e) {
      _lastError = '$e';
      _isListening = false;
      await _tearDownEngine();
      await WakeForegroundTask.stop();
      debugPrint('[WakeWord] start failed: $e');
      notifyListeners();
    } finally {
      _startInFlight = false;
    }
  }

  void _onPcm(Uint8List bytes) {
    assert(!listenPathPersistsAudio);
    if (bytes.isEmpty || !OpenWakeWordRuntime.isReady) return;
    // Align to int16 samples.
    final sampleCount = bytes.length ~/ 2;
    if (sampleCount == 0) return;
    final pcm = Int16List(sampleCount);
    final bd = ByteData.sublistView(bytes);
    var peak = 0;
    for (var i = 0; i < sampleCount; i++) {
      final s = bd.getInt16(i * 2, Endian.little);
      pcm[i] = s;
      final a = s.abs();
      if (a > peak) peak = a;
    }
    // Mild boost for quiet BT SCO - floor 8 (logs: peakAbs 2-4 often skips
    // gain entirely). Cap 24x so noise floor does not starve scores.
    var gainApplied = 1.0;
    final gainFloor = _inputRouteKind == 'bluetooth' ? 8 : 12;
    if (peak >= gainFloor && peak < 2500) {
      gainApplied = (6000 / peak).clamp(1.0, 24.0);
      for (var i = 0; i < sampleCount; i++) {
        final v = (pcm[i] * gainApplied).round();
        pcm[i] = v.clamp(-32768, 32767);
      }
    }
    OpenWakeWordRuntime.processAudio(pcm);
    final prob = OpenWakeWordRuntime.getProbability();
    if (prob > _maxProbSeen) _maxProbSeen = prob;
    if (prob > _rawMatch) _rawMatch = prob;
    // openWakeWord is spike-shaped (logs: 0 / ~1% noise / sudden 80%+).
    // Hold real peaks on the chip; ignore sub-2% noise as "1% progress".
    var displayJumped = false;
    if (prob >= 0.02 && prob > _displayMatch + 0.005) {
      _displayMatch = prob;
      _displayHoldUntil = DateTime.now().add(const Duration(milliseconds: 2000));
      displayJumped = true;
    }
    _levelPeak = peak;
    if (peak > _recentPeakMax) _recentPeakMax = peak;
    if (_pcmChunks % 20 == 0) {
      _recentPeakMax = (_recentPeakMax * 0.65).round();
    }
    _pcmChunks++;
    if (prob >= (_matchThreshold * 0.8)) {
      _highProbStreak++;
    } else if (_pcmChunks % 8 == 0 && _highProbStreak > 0) {
      // Most frames exchange prob=0; decay instead of hard-reset.
      _highProbStreak--;
    }
    // Decay raw trigger score slowly; decay display only after hold window.
    if (_pcmChunks % 12 == 0) {
      _rawMatch *= 0.97;
      if (_rawMatch < 0.005) _rawMatch = 0;
      final hold = _displayHoldUntil;
      if (hold == null || DateTime.now().isAfter(hold)) {
        _displayMatch *= 0.88;
        if (_displayMatch < 0.02) _displayMatch = 0;
      }
    }
    // Rare SCO recovery only — restarting every ~5s wiped the model state and
    // kept Match % stuck in single digits (runtime evidence).
    if (_inputRouteKind == 'bluetooth') {
      if (peak > 20) {
        _zeroPeakStreak = 0;
      } else {
        _zeroPeakStreak++;
        final now = DateTime.now();
        final cooled = _lastSilentBtRestartAt == null ||
            now.difference(_lastSilentBtRestartAt!) >
                const Duration(seconds: 45);
        if (!_restartingForRoute && cooled && _zeroPeakStreak >= 150) {
          _lastSilentBtRestartAt = now;
          _scoNeedsReclaim = true;
          unawaited(_restartForRouteChange());
        }
      }
    }
    // Immediate UI on real score jumps; otherwise ~8 Hz tick.
    if (!_disposed && (displayJumped || _pcmChunks % 6 == 0)) {
      notifyListeners();
    }
    // Sample every ~50 chunks to avoid log spam.
    if (_pcmChunks == 1 ||
        _pcmChunks == 50 ||
        _pcmChunks % 200 == 0 ||
        displayJumped) {
    }
    final activatedNative = OpenWakeWordRuntime.isActivated();
    // Soft path uses the user threshold. Native still needs several consecutive
    // frames above ~0.5 — a single 96% flash with mute mic often fails native.
    final activatedSoft = _rawMatch >= _matchThreshold &&
        _highProbStreak >= 1 &&
        _recentPeakMax >= 15;
    final activated = activatedNative || activatedSoft;
    if (activated && !_wasActivated) {
      final hit = _rawMatch > _displayMatch ? _rawMatch : _displayMatch;
      final hitClamped = hit > 0 ? hit : _maxProbSeen;
      _displayMatch = hitClamped;
      _lastWakeMatch = hitClamped;
      _displayHoldUntil =
          DateTime.now().add(const Duration(milliseconds: 2500));
      _wasActivated = true;
      _handingOff = true;
      _lastWakeAt = DateTime.now();
      _lastWakeLabel = activePhraseLabel;
      // Paint Heard·N% before mic teardown (logs: activate→yield in ~200ms
      // hid the spike behind "Heard" / "Cmd").
      notifyListeners();
      Future<void>.delayed(const Duration(seconds: 4), () {
        if (!_disposed) notifyListeners();
      });
      unawaited(() async {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (_disposed) return;
        await _yieldMicThenNotify();
      }());
    } else if (!activated) {
      _wasActivated = false;
    }
  }

  Future<void> _yieldMicThenNotify() async {
    try {
      await _micSub?.cancel();
      _micSub = null;
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}
    OpenWakeWordRuntime.destroy();
    // Release SCO before handshake ack/TTS so buds use media (A2DP) volume.
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final am = AndroidAudioManager();
        try {
          await am.clearCommunicationDevice();
        } catch (_) {}
        try {
          await am.stopBluetoothSco();
        } catch (_) {}
        try {
          await am.setBluetoothScoOn(false);
        } catch (_) {}
        try {
          await am.setMode(AndroidAudioHardwareMode.normal);
        } catch (_) {}
      } catch (_) {}
      _scoNeedsReclaim = true;
    }
    _isListening = false;
    _inputRouteKind = 'handoff';
    _inputRouteLabel = 'Wake → command';
    _inputRouteShort = 'Command';
    _handingOff = true;
    if (!_disposed) notifyListeners();
    onWakeDetected?.call();
  }

  Future<void> _tearDownEngine() async {
    await _micSub?.cancel();
    _micSub = null;
    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}
    OpenWakeWordRuntime.destroy();
  }

  Future<void> stopListening() async {
    try {
      await _tearDownEngine();
    } catch (e) {
      debugPrint('[WakeWord] stop: $e');
    }
    // Drop call-mode / SCO so the next ack can use A2DP media volume.
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final am = AndroidAudioManager();
        try {
          await am.clearCommunicationDevice();
        } catch (_) {}
        try {
          await am.stopBluetoothSco();
        } catch (_) {}
        try {
          await am.setBluetoothScoOn(false);
        } catch (_) {}
        try {
          await am.setMode(AndroidAudioHardwareMode.normal);
        } catch (_) {}
      } catch (_) {}
      _scoNeedsReclaim = true;
    }
    _isListening = false;
    _handingOff = false;
    _inputRouteLabel = 'Mic idle';
    _inputRouteShort = 'Mic idle';
    _inputRouteKind = 'idle';
    _rawMatch = 0;
    _displayMatch = 0;
    _displayHoldUntil = null;
    _levelPeak = 0;
    await WakeForegroundTask.stop();
    if (!_disposed) notifyListeners();
  }

  Future<void> _ensureAudioSessionForWake() async {
    try {
      final session = await AudioSession.instance;
      // Keep session media-friendly; RecordConfig still opens SCO for the mic.
      // voiceCommunication here made all app playback use the quiet call stream.
      await session.configure(
        AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.allowBluetooth |
              AVAudioSessionCategoryOptions.allowBluetoothA2dp,
          avAudioSessionMode: AVAudioSessionMode.spokenAudio,
          androidAudioAttributes: const AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            usage: AndroidAudioUsage.assistant,
          ),
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientMayDuck,
          androidWillPauseWhenDucked: false,
        ),
      );
      _devicesSub ??= session.devicesChangedEventStream.listen((_) {
        if (_disposed || !_isListening || _restartingForRoute) return;
        unawaited(_restartForRouteChange());
      });
    } catch (e) {
      debugPrint('[WakeWord] audio session: $e');
    }
  }

  Future<void> _restartForRouteChange() async {
    if (_restartingForRoute || !_isListening) return;
    _restartingForRoute = true;
    try {
      await stopListening();
      await startListening();
    } finally {
      _restartingForRoute = false;
    }
  }

  bool _isBluetoothPick(
    ({InputDevice? device, bool btPending, InputDevice? display}) pick,
  ) {
    if (pick.btPending) return true;
    final t = pick.display?.type ?? pick.device?.type;
    return t == InputDeviceType.bluetoothSco ||
        t == InputDeviceType.bluetoothA2dp ||
        t == InputDeviceType.bluetoothLe;
  }

  /// Loud TTS/ack is about to kill SCO. Abort in-flight reclaim/listen so we
  /// do not pin a zombie device (runtime: B4 during B5 -> mute).
  Future<void> yieldMicForLoudPlayback() async {
    _scoNeedsReclaim = true;
    _listenGen++;
    try {
      await _tearDownEngine();
    } catch (_) {}
    _isListening = false;
    _startInFlight = false;
    _handingOff = false;
    if (!_disposed) notifyListeners();
  }

  Future<bool> _pinScoCommunicationDevice(AndroidAudioManager am) async {
    try {
      final comm = await am.getAvailableCommunicationDevices();
      for (final d in comm) {
        if (d.type == AndroidAudioDeviceType.bluetoothSco) {
          return await am.setCommunicationDevice(d);
        }
      }
    } catch (_) {}
    return false;
  }

  /// Tear down zombie SCO, reopen, wait for CONNECTED, then pin communication
  /// device. Event-driven (no sleep-as-fix). Skip tear-down if already up.
  Future<bool> _reclaimBluetoothScoForWake() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    final am = AndroidAudioManager();
    var scoOnBefore = false;
    AndroidScoAudioState? stateBefore;
    try {
      scoOnBefore = await am.isBluetoothScoOn();
    } catch (_) {}
    stateBefore = am.currentScoAudioState;

    // Already live - do not bounce SCO (logs: tear-down of connected hurt hit rate).
    if (scoOnBefore || stateBefore == AndroidScoAudioState.connected) {
      await _pinScoCommunicationDevice(am);
      try {
        await am.setMode(AndroidAudioHardwareMode.inCommunication);
      } catch (_) {}
      return true;
    }

    try {
      await am.clearCommunicationDevice();
    } catch (_) {}
    try {
      await am.stopBluetoothSco();
    } catch (_) {}
    try {
      await am.setBluetoothScoOn(false);
    } catch (_) {}
    try {
      await am.setMode(AndroidAudioHardwareMode.normal);
    } catch (_) {}

    final connected = Completer<bool>();
    late final StreamSubscription<AndroidScoAudioEvent> sub;
    sub = am.scoAudioEventStream.listen((e) {
      if (connected.isCompleted) return;
      if (e.currentState == AndroidScoAudioState.connected) {
        connected.complete(true);
      } else if (e.currentState == AndroidScoAudioState.error) {
        connected.complete(false);
      }
    });

    try {
      await am.setMode(AndroidAudioHardwareMode.inCommunication);
    } catch (_) {}
    try {
      await am.setBluetoothScoOn(true);
    } catch (_) {}
    try {
      await am.startBluetoothSco();
    } catch (_) {}

    try {
      if (await am.isBluetoothScoOn() &&
          am.currentScoAudioState == AndroidScoAudioState.connected &&
          !connected.isCompleted) {
        connected.complete(true);
      }
    } catch (_) {}

    final ok = await connected.future.timeout(
      const Duration(seconds: 4),
      onTimeout: () => false,
    );
    await sub.cancel();

    if (ok) {
      await _pinScoCommunicationDevice(am);
    }

    var scoOnAfter = false;
    try {
      scoOnAfter = await am.isBluetoothScoOn();
    } catch (_) {}
    return ok || scoOnAfter;
  }

  /// Prefer pinning SCO when listed (better uplink). If only A2DP is visible,
  /// leave device null so manageBluetooth can open SCO.
  ({InputDevice? device, bool btPending, InputDevice? display})
  _preferWakeInputDevice(List<InputDevice> devices) {
    InputDevice? sco;
    InputDevice? ble;
    InputDevice? a2dp;
    InputDevice? wired;
    InputDevice? builtIn;
    for (final d in devices) {
      switch (d.type) {
        case InputDeviceType.bluetoothSco:
          sco ??= d;
          break;
        case InputDeviceType.bluetoothLe:
          ble ??= d;
          break;
        case InputDeviceType.bluetoothA2dp:
          a2dp ??= d;
          break;
        case InputDeviceType.wiredHeadset:
          wired ??= d;
          break;
        case InputDeviceType.builtIn:
          builtIn ??= d;
          break;
        default:
          break;
      }
    }
    if (sco != null) {
      return (device: sco, btPending: false, display: sco);
    }
    if (ble != null) {
      return (device: ble, btPending: false, display: ble);
    }
    if (a2dp != null) {
      return (device: null, btPending: true, display: a2dp);
    }
    final local = wired ?? builtIn;
    return (device: local, btPending: false, display: local);
  }

  void _setInputRoute(InputDevice? device, {bool btPending = false}) {
    if (btPending && device == null) {
      _inputRouteKind = 'bluetooth';
      _inputRouteLabel = 'Bluetooth mic (SCO)';
      _inputRouteShort = 'BT mic';
      return;
    }
    if (device == null) {
      _inputRouteKind = 'default';
      _inputRouteLabel = 'Default mic';
      _inputRouteShort = 'Mic';
      return;
    }
    switch (device.type) {
      case InputDeviceType.bluetoothSco:
      case InputDeviceType.bluetoothLe:
      case InputDeviceType.bluetoothA2dp:
        _inputRouteKind = 'bluetooth';
        final name = device.label.trim();
        _inputRouteLabel =
            name.isEmpty ? 'Bluetooth mic' : 'Bluetooth · $name';
        _inputRouteShort = name.isEmpty ? 'BT' : 'BT ${_shortDeviceName(name)}';
        break;
      case InputDeviceType.wiredHeadset:
        _inputRouteKind = 'wired';
        _inputRouteLabel = 'Wired headset mic';
        _inputRouteShort = 'Wired';
        break;
      case InputDeviceType.builtIn:
        _inputRouteKind = 'phone';
        _inputRouteLabel = 'Phone mic';
        _inputRouteShort = 'Phone';
        break;
      default:
        _inputRouteKind = 'default';
        final name = device.label.trim();
        _inputRouteLabel = name.isEmpty ? 'Default mic' : name;
        _inputRouteShort = _shortDeviceName(
          name.isEmpty ? 'Mic' : name,
        );
        break;
    }
  }

  String _shortDeviceName(String raw) {
    var s = raw.trim();
    // Drop common vendor noise: "OnePlus Nord Buds 4 Pro" → "Nord Buds"
    s = s
        .replaceAll(RegExp(r'\b(oneplus|samsung|sony|jabra|bose|apple)\b',
            caseSensitive: false), '')
        .replaceAll(RegExp(r'\b(pro|plus|max|anc)\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (s.isEmpty) s = raw.trim();
    if (s.length <= 12) return s;
    return '${s.substring(0, 11)}…';
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_devicesSub?.cancel());
    _devicesSub = null;
    unawaited(stopListening());
    unawaited(_recorder.dispose());
    super.dispose();
  }
}

final wakeWordServiceProvider = ChangeNotifierProvider<WakeWordService>((ref) {
  return WakeWordService();
});
