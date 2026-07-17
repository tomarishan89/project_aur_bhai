import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'telemetry_bus.dart';

/// Writes live device GPS / accelerometer into the **sovereign** vault only
/// via [TelemetryBusService.addRecord].
///
/// Never seeds or writes the sandbox DB. Due-diligence / marketplace Bro Code
/// must use [TelemetryBusService.openSandbox] synthetic rows only.
class TelemetryCollector {
  TelemetryCollector({
    required TelemetryBusService bus,
    this.sampleInterval = const Duration(seconds: 4),
    Future<bool> Function()? requestLocationPermission,
    Future<Position?> Function()? readPosition,
    Stream<AccelerometerEvent> Function()? accelerometerEvents,
    bool? forceMobilePlatform,
  })  : _bus = bus,
        _requestLocationPermission =
            requestLocationPermission ?? _defaultRequestLocationPermission,
        _readPosition = readPosition ?? _defaultReadPosition,
        _accelerometerEvents =
            accelerometerEvents ?? _defaultAccelerometerEvents,
        _forceMobilePlatform = forceMobilePlatform;

  final TelemetryBusService _bus;
  final Duration sampleInterval;
  final Future<bool> Function() _requestLocationPermission;
  final Future<Position?> Function() _readPosition;
  final Stream<AccelerometerEvent> Function() _accelerometerEvents;
  final bool? _forceMobilePlatform;

  Timer? _timer;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  double _accelerometerZ = 9.8;
  bool _running = false;
  bool _deniedLogged = false;
  bool _skippedLogged = false;

  bool get isRunning => _running;

  bool get _isMobile {
    if (_forceMobilePlatform != null) return _forceMobilePlatform!;
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  /// Start sampling after the UI is up. No-op on desktop / when permission denied.
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
      return;
    }

    _running = true;
    _accelSub = _accelerometerEvents().listen((event) {
      _accelerometerZ = event.z;
    });

    _timer = Timer.periodic(sampleInterval, (_) => _sampleOnce());
    await _sampleOnce();
    debugPrint('[TelemetryCollector] Live sampling started ($sampleInterval)');
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _accelSub?.cancel();
    _accelSub = null;
    _running = false;
  }

  Future<void> _sampleOnce() async {
    if (!_running) return;
    try {
      final position = await _readPosition();
      if (position == null) return;

      double heading = position.heading;
      if (heading.isNaN || heading < 0) heading = 0.0;

      await _bus.addRecord(
        latitude: position.latitude,
        longitude: position.longitude,
        accelerometerZ: _accelerometerZ,
        compassDirection: heading,
      );
    } catch (e) {
      debugPrint('[TelemetryCollector] Sample failed: $e');
    }
  }

  static Future<bool> _defaultRequestLocationPermission() async {
    var status = await Permission.locationWhenInUse.status;
    if (status.isGranted) return true;
    status = await Permission.locationWhenInUse.request();
    if (status.isGranted) return true;

    // Geolocator can surface service-disabled separately from OS permission.
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
  final collector = TelemetryCollector(bus: bus);
  ref.onDispose(() {
    unawaited(collector.stop());
  });
  return collector;
});
