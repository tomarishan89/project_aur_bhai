import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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

/// Writes live device GPS + all available sensor streams into the **sovereign**
/// vault via [TelemetryBusService].
///
/// Dual write strategy:
///  - GPS-paced write (default 4 s) â†’ `telemetry` table (long history)
///  - IMU-paced write (default 0.5 s) â†’ `imu_telemetry` table (short
///    user-configurable retention, preserves high-freq events like bumps)
class TelemetryCollector extends ChangeNotifier {
  TelemetryCollector({
    required TelemetryBusService bus,
    this.sampleInterval = const Duration(seconds: 4),
    this.imuInterval = const Duration(milliseconds: 500),
    this.imuRetention = const Duration(minutes: 30),
    this.maxBackoff = const Duration(seconds: 30),
    Future<bool> Function()? requestLocationPermission,
    Future<Position?> Function()? readPosition,
    Stream<AccelerometerEvent> Function()? accelerometerEvents,
    bool? forceMobilePlatform,
    this.onSovereignSample,
  }) : _bus = bus,
       _requestLocationPermission =
           requestLocationPermission ?? _defaultRequestLocationPermission,
       _readPosition = readPosition ?? _defaultReadPosition,
       _customAccelerometerEvents = accelerometerEvents,
       _forceMobilePlatform = forceMobilePlatform;

  final TelemetryBusService _bus;
  final Duration sampleInterval;
  Duration imuInterval;
  Duration imuRetention;
  final Duration maxBackoff;
  final Future<bool> Function() _requestLocationPermission;
  final Future<Position?> Function() _readPosition;
  final Stream<AccelerometerEvent> Function()? _customAccelerometerEvents;
  final bool? _forceMobilePlatform;

  /// Optional Path L fine-buffer hook (MS-FINE-TELEMETRY / ambient capture).
  final void Function(
    double latitude,
    double longitude,
    double accelerometerZ,
    double compassDirection,
  )?
  onSovereignSample;

  // GPS timer
  Timer? _timer;
  // IMU high-frequency timer
  Timer? _imuTimer;
  // IMU rolling purge timer (fires every 60s)
  Timer? _imuPurgeTimer;

  // Sensor subscriptions
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<UserAccelerometerEvent>? _userAccelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  StreamSubscription<BarometerEvent>? _baroSub;

  // Track timestamp of last received hardware sensor event
  DateTime? _lastSensorEventAt;
  DateTime? _lastWatchdogResubscribeAt;

  // Live sensor values (updated continuously, snapshotted at write ticks)
  double _accelX = 0.0;
  double _accelY = 0.0;
  double _accelZ = 9.8; // gravity default until first event
  double _userAccelX = 0.0;
  double _userAccelY = 0.0;
  double _userAccelZ = 0.0;
  double _gyroX = 0.0;
  double _gyroY = 0.0;
  double _gyroZ = 0.0;
  double? _magX;
  double? _magY;
  double? _magZ;
  double? _pressure;

  // Sensor availability flags
  bool _hasGyro = false;
  bool _hasMag = false;
  bool _hasBaro = false;

  // Legacy alias kept for backward compat with Bro Code scripts
  double get _accelerometerZ => _accelZ;

  bool _running = false;
  bool _inFlight = false;
  bool _deniedLogged = false;
  bool _skippedLogged = false;
  Position? _lastPosition;
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

  double _magnitude(double x, double y, double z) =>
      math.sqrt(x * x + y * y + z * z);

  // ---------------------------------------------------------------------------
  // Public API for dashboard ⚙ settings
  // ---------------------------------------------------------------------------

  /// Update IMU write cadence. Restarts the IMU timer immediately if running.
  void setImuCadence(Duration interval) {
    imuInterval = interval;
    if (_running) {
      _imuTimer?.cancel();
      _imuTimer = Timer.periodic(
        imuInterval,
        (_) => unawaited(_writeImuRow()),
      );
    }
  }

  /// Update IMU retention window. Applied on next purge cycle.
  void setImuRetention(Duration retention) {
    imuRetention = retention;
  }

  // ---------------------------------------------------------------------------

  void _subscribeSensors() {
    _unsubscribeSensors();
    final isTestMode = _customAccelerometerEvents != null;

    final accelStream = isTestMode
        ? _customAccelerometerEvents!()
        : accelerometerEventStream(
            samplingPeriod: SensorInterval.normalInterval,
          );
    _accelSub = accelStream.listen((e) {
      _accelX = e.x;
      _accelY = e.y;
      _accelZ = e.z;
      _lastSensorEventAt = DateTime.now();
    }, onError: (_) {});

    if (!isTestMode) {
      // User accelerometer (gravity-removed)
      try {
        _userAccelSub = userAccelerometerEventStream(
          samplingPeriod: SensorInterval.normalInterval,
        ).listen((e) {
          _userAccelX = e.x;
          _userAccelY = e.y;
          _userAccelZ = e.z;
          _lastSensorEventAt = DateTime.now();
        }, onError: (_) {});
      } catch (e) {
        debugPrint('[TelemetryCollector] UserAccelerometer unavailable: $e');
      }

      // Gyroscope
      try {
        _gyroSub = gyroscopeEventStream(
          samplingPeriod: SensorInterval.normalInterval,
        ).listen((e) {
          _gyroX = e.x;
          _gyroY = e.y;
          _gyroZ = e.z;
          _hasGyro = true;
          _lastSensorEventAt = DateTime.now();
        }, onError: (_) {});
      } catch (e) {
        debugPrint('[TelemetryCollector] Gyroscope unavailable: $e');
      }

      // Magnetometer
      try {
        _magSub = magnetometerEventStream(
          samplingPeriod: SensorInterval.normalInterval,
        ).listen((e) {
          _magX = e.x;
          _magY = e.y;
          _magZ = e.z;
          _hasMag = true;
          _lastSensorEventAt = DateTime.now();
        }, onError: (_) {});
      } catch (e) {
        debugPrint('[TelemetryCollector] Magnetometer unavailable: $e');
      }

      // Barometer
      try {
        _baroSub = barometerEventStream().listen((e) {
          _pressure = e.pressure;
          _hasBaro = true;
          _lastSensorEventAt = DateTime.now();
        }, onError: (_) {});
      } catch (e) {
        debugPrint('[TelemetryCollector] Barometer unavailable: $e');
      }
    }
  }

  void _unsubscribeSensors() {
    _accelSub?.cancel();
    _accelSub = null;
    _userAccelSub?.cancel();
    _userAccelSub = null;
    _gyroSub?.cancel();
    _gyroSub = null;
    _magSub?.cancel();
    _magSub = null;
    _baroSub?.cancel();
    _baroSub = null;
  }

  /// Explicitly re-subscribes to platform sensor event channels.
  /// Call when resuming from background or screen unlock to wake up hardware streams.
  void resubscribeSensors() {
    if (!_running) return;
    _subscribeSensors();
    debugPrint('[TelemetryCollector] Re-subscribed to hardware sensor streams');
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
          'sovereign vault will stay empty until granted.',
        );
      }
      _status = TelemetryCollectorStatus.denied;
      notifyListeners();
      return;
    }

    _running = true;
    _status = TelemetryCollectorStatus.running;

    // --- Subscribe to sensor streams ---
    _subscribeSensors();

    // GPS-paced timer → telemetry table
    _timer = Timer.periodic(sampleInterval, (_) => unawaited(_sampleOnce()));
    await _sampleOnce();

    // IMU high-freq timer → imu_telemetry table
    _imuTimer = Timer.periodic(imuInterval, (_) => unawaited(_writeImuRow()));

    // Rolling IMU purge (every 60s)
    _imuPurgeTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(_bus.purgeOldImuRecords(imuRetention)),
    );

    notifyListeners();
    debugPrint(
      '[TelemetryCollector] Started '
      '(GPS: $sampleInterval, IMU: $imuInterval, retain: $imuRetention)',
    );
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _imuTimer?.cancel();
    _imuTimer = null;
    _imuPurgeTimer?.cancel();
    _imuPurgeTimer = null;
    _unsubscribeSensors();
    _lastPosition = null;
    _running = false;
    _inFlight = false;
    _status = TelemetryCollectorStatus.idle;
    notifyListeners();
  }

  Future<void> pause() async {
    if (!_running) return;
    _timer?.cancel();
    _timer = null;
    _imuTimer?.cancel();
    _imuTimer = null;
    _unsubscribeSensors();
    _status = TelemetryCollectorStatus.paused;
    notifyListeners();
  }

  Future<void> resume() async {
    if (!_running) return;
    if (_status == TelemetryCollectorStatus.denied ||
        _status == TelemetryCollectorStatus.skippedPlatform) {
      return;
    }

    // Always re-subscribe hardware sensor streams upon resume
    _subscribeSensors();

    // Reset failure streak and backoff on resume to query GPS immediately
    _failureStreak = 0;
    _currentBackoff = Duration.zero;
    _nextAllowedSample = null;
    _status = TelemetryCollectorStatus.running;

    _timer?.cancel();
    _timer = Timer.periodic(sampleInterval, (_) => unawaited(_sampleOnce()));

    _imuTimer?.cancel();
    _imuTimer = Timer.periodic(imuInterval, (_) => unawaited(_writeImuRow()));

    notifyListeners();
    await _sampleOnce();
  }

  /// Writes one row to the high-frequency imu_telemetry table.
  Future<void> _writeImuRow() async {
    if (!_running) return;
    final now = DateTime.now();

    // Watchdog: If sensor stream has gone completely silent (> 4s) on real mobile,
    // re-subscribe to recover broken native listeners.
    if (_isMobile &&
        _customAccelerometerEvents == null &&
        _lastSensorEventAt != null &&
        now.difference(_lastSensorEventAt!) > const Duration(seconds: 4)) {
      final lastResub = _lastWatchdogResubscribeAt;
      if (lastResub == null || now.difference(lastResub) > const Duration(seconds: 6)) {
        _lastWatchdogResubscribeAt = now;
        debugPrint('[TelemetryCollector] Sensor stream silent watchdog triggered — re-subscribing');
        _subscribeSensors();
      }
    }

    await _bus.addImuRecord(
      ImuRecord(
        id: '${now.microsecondsSinceEpoch}',
        timestampMs: now.millisecondsSinceEpoch,
        accelX: _accelX,
        accelY: _accelY,
        accelZ: _accelZ,
        accelMagnitude: _magnitude(_accelX, _accelY, _accelZ),
        userAccelX: _userAccelX,
        userAccelY: _userAccelY,
        userAccelZ: _userAccelZ,
        gyroX: _hasGyro ? _gyroX : null,
        gyroY: _hasGyro ? _gyroY : null,
        gyroZ: _hasGyro ? _gyroZ : null,
        gyroMagnitude: _hasGyro ? _magnitude(_gyroX, _gyroY, _gyroZ) : null,
        magX: _hasMag ? _magX : null,
        magY: _hasMag ? _magY : null,
        magZ: _hasMag ? _magZ : null,
        pressure: _hasBaro ? _pressure : null,
      ),
    );
  }

  Future<void> _sampleOnce() async {
    if (!_running) return;
    if (_inFlight) return;
    if (_nextAllowedSample != null &&
        DateTime.now().isBefore(_nextAllowedSample!)) {
      _status = TelemetryCollectorStatus.backoff;
      return;
    }

    _inFlight = true;
    try {
      Position? position;
      try {
        position = await _readPosition();
      } catch (e) {
        debugPrint('[TelemetryCollector] _readPosition error: $e');
      }

      if (position != null) {
        _lastPosition = position;
      } else {
        position = _lastPosition;
      }

      if (position == null) {
        _onSampleFailure('null position');
        return;
      }

      double heading = position.heading;
      if (heading.isNaN || heading < 0) heading = 0.0;

      final accelMag = _magnitude(_accelX, _accelY, _accelZ);
      final gyroMag = _hasGyro ? _magnitude(_gyroX, _gyroY, _gyroZ) : null;

      await _bus.addRecord(
        latitude: position.latitude,
        longitude: position.longitude,
        accelerometerZ: _accelerometerZ,
        compassDirection: heading,
        accelX: _accelX,
        accelY: _accelY,
        accelZ: _accelZ,
        accelMagnitude: accelMag,
        userAccelX: _userAccelX,
        userAccelY: _userAccelY,
        userAccelZ: _userAccelZ,
        gyroX: _hasGyro ? _gyroX : null,
        gyroY: _hasGyro ? _gyroY : null,
        gyroZ: _hasGyro ? _gyroZ : null,
        gyroMagnitude: gyroMag,
        magX: _hasMag ? _magX : null,
        magY: _hasMag ? _magY : null,
        magZ: _hasMag ? _magZ : null,
        pressure: _hasBaro ? _pressure : null,
        altitude: position.altitude,
        altitudeAccuracy: position.altitudeAccuracy,
        speed: position.speed,
        speedAccuracy: position.speedAccuracy,
        gpsAccuracy: position.accuracy,
        headingAccuracy: position.headingAccuracy,
        floor: position.floor,
        isMocked: position.isMocked ? 1 : 0,
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
    final baseMs = sampleInterval.inMilliseconds.clamp(
      50,
      maxBackoff.inMilliseconds,
    );
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
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 4),
        ),
      );
    } catch (e) {
      debugPrint('[TelemetryCollector] Location fix timeout/error ($e), trying getLastKnownPosition');
      try {
        return await Geolocator.getLastKnownPosition();
      } catch (_) {
        return null;
      }
    }
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
