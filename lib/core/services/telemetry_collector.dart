import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'model_studio/ambient_capture_service.dart';
import 'telemetry_bus.dart';

enum TelemetryCollectorStatus {
  idle,
  running,
  denied,
  skippedPlatform,
  backoff,
  paused,
}

/// Writes live device GPS / accelerometer into the **sovereign** vault only
/// via [TelemetryBusService.addRecord].
///
/// Single-flight GPS: never stacks overlapping high-accuracy position reads.
class TelemetryCollector extends ChangeNotifier {
  TelemetryCollector({
    required TelemetryBusService bus,
    this.sampleInterval = const Duration(seconds: 4),
    this.maxBackoff = const Duration(minutes: 2),
    Future<bool> Function()? requestLocationPermission,
    Future<Position?> Function()? readPosition,
    Stream<AccelerometerEvent> Function()? accelerometerEvents,
    bool? forceMobilePlatform,
    this.onSovereignSample,
  })  : _bus = bus,
        _requestLocationPermission =
            requestLocationPermission ?? _defaultRequestLocationPermission,
        _readPosition = readPosition ?? _defaultReadPosition,
        _accelerometerEvents =
            accelerometerEvents ?? _defaultAccelerometerEvents,
        _forceMobilePlatform = forceMobilePlatform;

  final TelemetryBusService _bus;
  final Duration sampleInterval;
  final Duration maxBackoff;
  final Future<bool> Function() _requestLocationPermission;
  final Future<Position?> Function() _readPosition;
  final Stream<AccelerometerEvent> Function() _accelerometerEvents;
  final bool? _forceMobilePlatform;

  /// Optional Path L fine-buffer hook (MS-FINE-TELEMETRY / ambient capture).
  final void Function(
    double latitude,
    double longitude,
    double accelerometerZ,
    double compassDirection,
  )? onSovereignSample;

  Timer? _timer;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  double _accelerometerZ = 9.8;
  bool _running = false;
  bool _inFlight = false;
  bool _deniedLogged = false;
  bool _skippedLogged = false;
  int _failureStreak = 0;
  Duration _currentBackoff = Duration.zero;
  DateTime? _nextAllowedSample;
  DateTime? _lastSuccessAt;
  String? _lastError;
  TelemetryCollectorStatus _status = TelemetryCollectorStatus.idle;

  bool get isRunning => _running;
  bool get inFlight => _inFlight;
  TelemetryCollectorStatus get status => _status;
  DateTime? get lastSuccessAt => _lastSuccessAt;
  String? get lastError => _lastError;
  Duration get currentBackoff => _currentBackoff;

  bool get _isMobile {
    if (_forceMobilePlatform != null) return _forceMobilePlatform;
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  Future<void> start() async {
    if (_running) return;

    if (!_isMobile) {
      if (!_skippedLogged) {
        _skippedLogged = true;
        debugPrint(
          '[TelemetryCollector] No device sensors on this platform — '
          'skipping live sovereign collection (not writing fakes).',
        );
      }
      _status = TelemetryCollectorStatus.skippedPlatform;
      notifyListeners();
      return;
    }

    final granted = await _requestLocationPermission();
    if (!granted) {
      if (!_deniedLogged) {
        _deniedLogged = true;
        debugPrint(
          '[TelemetryCollector] Location permission denied — '
          'sovereign vault will stay empty until granted (no Delhi fallback).',
        );
      }
      _status = TelemetryCollectorStatus.denied;
      notifyListeners();
      return;
    }

    _running = true;
    _status = TelemetryCollectorStatus.running;
    _accelSub = _accelerometerEvents().listen((event) {
      _accelerometerZ = event.z;
    });

    _timer = Timer.periodic(sampleInterval, (_) => unawaited(_sampleOnce()));
    await _sampleOnce();
    notifyListeners();
    debugPrint('[TelemetryCollector] Live sampling started ($sampleInterval)');
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _accelSub?.cancel();
    _accelSub = null;
    _running = false;
    _inFlight = false;
    _status = TelemetryCollectorStatus.idle;
    notifyListeners();
  }

  Future<void> pause() async {
    if (!_running) return;
    _timer?.cancel();
    _timer = null;
    _status = TelemetryCollectorStatus.paused;
    notifyListeners();
  }

  Future<void> resume() async {
    if (!_running || _timer != null) return;
    if (_status == TelemetryCollectorStatus.denied ||
        _status == TelemetryCollectorStatus.skippedPlatform) {
      return;
    }
    _status = _failureStreak > 0
        ? TelemetryCollectorStatus.backoff
        : TelemetryCollectorStatus.running;
    _timer = Timer.periodic(sampleInterval, (_) => unawaited(_sampleOnce()));
    notifyListeners();
    await _sampleOnce();
  }

  Future<void> _sampleOnce() async {
    if (!_running) return;
    if (_inFlight) return; // single-flight
    if (_nextAllowedSample != null &&
        DateTime.now().isBefore(_nextAllowedSample!)) {
      _status = TelemetryCollectorStatus.backoff;
      return;
    }

    _inFlight = true;
    try {
      final position = await _readPosition();
      if (position == null) {
        _onSampleFailure('null position');
        return;
      }

      double heading = position.heading;
      if (heading.isNaN || heading < 0) heading = 0.0;

      await _bus.addRecord(
        latitude: position.latitude,
        longitude: position.longitude,
        accelerometerZ: _accelerometerZ,
        compassDirection: heading,
      );
      onSovereignSample?.call(
        position.latitude,
        position.longitude,
        _accelerometerZ,
        heading,
      );
      _failureStreak = 0;
      _currentBackoff = Duration.zero;
      _nextAllowedSample = null;
      _lastSuccessAt = DateTime.now();
      _lastError = null;
      _status = TelemetryCollectorStatus.running;
      notifyListeners();
    } catch (e) {
      _onSampleFailure('$e');
      debugPrint('[TelemetryCollector] Sample failed: $e');
    } finally {
      _inFlight = false;
    }
  }

  void _onSampleFailure(String err) {
    _failureStreak++;
    _lastError = err;
    final baseMs = sampleInterval.inMilliseconds.clamp(50, maxBackoff.inMilliseconds);
    final mult = 1 << (_failureStreak.clamp(1, 5) - 1);
    final ms = (baseMs * mult).clamp(baseMs, maxBackoff.inMilliseconds);
    _currentBackoff = Duration(milliseconds: ms);
    _nextAllowedSample = DateTime.now().add(_currentBackoff);
    _status = TelemetryCollectorStatus.backoff;
    notifyListeners();
  }

  static Future<bool> _defaultRequestLocationPermission() async {
    var status = await Permission.locationWhenInUse.status;
    if (status.isGranted) return true;
    status = await Permission.locationWhenInUse.request();
    if (status.isGranted) return true;

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('[TelemetryCollector] Location services disabled');
      return false;
    }
    var geo = await Geolocator.checkPermission();
    if (geo == LocationPermission.denied) {
      geo = await Geolocator.requestPermission();
    }
    return geo == LocationPermission.whileInUse ||
        geo == LocationPermission.always;
  }

  static Future<Position?> _defaultReadPosition() async {
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 8),
      ),
    );
  }

  static Stream<AccelerometerEvent> _defaultAccelerometerEvents() {
    return accelerometerEventStream();
  }
}

final telemetryCollectorProvider = Provider<TelemetryCollector>((ref) {
  final bus = ref.watch(telemetryBusProvider);
  final ambient = ref.watch(ambientCaptureProvider);
  final collector = TelemetryCollector(
    bus: bus,
    onSovereignSample: (lat, lng, z, h) {
      ambient.ingestSample(
        latitude: lat,
        longitude: lng,
        accelerometerZ: z,
        compassDirection: h,
      );
    },
  );
  ref.onDispose(() {
    unawaited(collector.stop());
  });
  return collector;
});
