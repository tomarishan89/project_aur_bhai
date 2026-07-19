import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';
import 'package:project_aur_bhai/core/services/telemetry_collector.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Classic fake injector coordinates — must never appear from permission-deny path.
const _delhiLat = 28.6139;
const _delhiLng = 77.2090;

int _dbSeq = 0;

TelemetryBusService _freshBus() {
  _dbSeq++;
  return TelemetryBusService(
    databaseFileName: 'telemetry_iso_test_${_dbSeq}_${DateTime.now().microsecondsSinceEpoch}.db',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('permission denied does not write Delhi (or any) sovereign fallback', () async {
    final bus = _freshBus();
    await bus.initialize();

    final collector = TelemetryCollector(
      bus: bus,
      sampleInterval: const Duration(milliseconds: 50),
      forceMobilePlatform: true,
      requestLocationPermission: () async => false,
      accelerometerEvents: () => const Stream.empty(),
      readPosition: () async {
        fail('readPosition must not run when denied');
        return null;
      },
    );

    await collector.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(collector.isRunning, isFalse);
    final rows = await bus.getRecentRecords(50);
    expect(rows, isEmpty);
    expect(
      rows.any(
        (r) =>
            (r.latitude - _delhiLat).abs() < 0.01 &&
            (r.longitude - _delhiLng).abs() < 0.01,
      ),
      isFalse,
    );

    await collector.stop();
    bus.dispose();
  });

  test('non-mobile platform skips collection without writing fakes', () async {
    final bus = _freshBus();
    await bus.initialize();

    var permissionCalls = 0;
    final collector = TelemetryCollector(
      bus: bus,
      forceMobilePlatform: false,
      accelerometerEvents: () => const Stream.empty(),
      requestLocationPermission: () async {
        permissionCalls++;
        return true;
      },
      readPosition: () async {
        fail('must not read position on desktop');
        return null;
      },
    );

    await collector.start();
    expect(collector.isRunning, isFalse);
    expect(permissionCalls, 0);
    expect(await bus.getRecentRecords(10), isEmpty);

    await collector.stop();
    bus.dispose();
  });

  test('granted path writes real coords via addRecord (sovereign only)', () async {
    final bus = _freshBus();
    await bus.initialize();

    final collector = TelemetryCollector(
      bus: bus,
      sampleInterval: const Duration(hours: 1),
      forceMobilePlatform: true,
      requestLocationPermission: () async => true,
      accelerometerEvents: () => Stream.value(
        AccelerometerEvent(0, 0, 9.81, DateTime.now()),
      ),
      readPosition: () async => Position(
        longitude: -122.4194,
        latitude: 37.7749,
        timestamp: DateTime.now(),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 45,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      ),
    );

    await collector.start();
    expect(collector.isRunning, isTrue);

    final rows = await bus.getRecentRecords(5);
    expect(rows, isNotEmpty);
    expect(rows.first.latitude, closeTo(37.7749, 0.0001));
    expect(rows.first.longitude, closeTo(-122.4194, 0.0001));
    expect(
      (rows.first.latitude - _delhiLat).abs() > 1.0,
      isTrue,
      reason: 'must not be Delhi fake',
    );

    await collector.stop();
    bus.dispose();
  });

  test('sandbox seed is synthetic; sovereign count unchanged by sandbox SQL',
      () async {
    final bus = _freshBus();
    await bus.initialize();

    await bus.addRecord(
      latitude: 12.34,
      longitude: 56.78,
      accelerometerZ: 1.0,
      compassDirection: 10.0,
    );
    final sovereignBefore = await bus.getRecentRecords(100);
    expect(sovereignBefore.length, 1);

    await bus.openSandbox(reset: true);
    final sandboxed = await bus.executeQuery(
      'SELECT id, latitude, longitude FROM telemetry ORDER BY id LIMIT 50',
    );
    expect(sandboxed.length, 8);
    expect(sandboxed.first['id'], 'sandbox-seed-0');
    expect(sandboxed.first['latitude'] as double, closeTo(41.0, 0.01));
    expect(
      sandboxed.any((r) => (r['latitude'] as double) == 12.34),
      isFalse,
      reason: 'sandbox must not contain sovereign telemetry',
    );

    await bus.closeSandbox();

    final sovereignAfter = await bus.getRecentRecords(100);
    expect(sovereignAfter.length, sovereignBefore.length);
    expect(sovereignAfter.first.latitude, 12.34);

    bus.dispose();
  });

  test('single-flight skips overlapping GPS reads', () async {
    final bus = _freshBus();
    await bus.initialize();

    var reads = 0;
    final started = <Completer<Position?>>[];
    final collector = TelemetryCollector(
      bus: bus,
      sampleInterval: const Duration(milliseconds: 20),
      forceMobilePlatform: true,
      requestLocationPermission: () async => true,
      accelerometerEvents: () => const Stream.empty(),
      readPosition: () async {
        reads++;
        final c = Completer<Position?>();
        started.add(c);
        return c.future;
      },
    );

    unawaited(collector.start());
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(reads, 1, reason: 'second tick must not stack while in-flight');
    expect(collector.inFlight, isTrue);

    started.first.complete(
      Position(
        longitude: 1,
        latitude: 2,
        timestamp: DateTime.now(),
        accuracy: 1,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await collector.stop();
    bus.dispose();
  });

  test('backoff engages after consecutive failures', () async {
    final bus = _freshBus();
    await bus.initialize();

    final collector = TelemetryCollector(
      bus: bus,
      sampleInterval: const Duration(milliseconds: 30),
      maxBackoff: const Duration(seconds: 2),
      forceMobilePlatform: true,
      requestLocationPermission: () async => true,
      accelerometerEvents: () => const Stream.empty(),
      readPosition: () async {
        throw TimeoutException('gps');
      },
    );

    await collector.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(collector.status, TelemetryCollectorStatus.backoff);
    expect(collector.currentBackoff > Duration.zero, isTrue);

    await collector.stop();
    bus.dispose();
  });

  test('addRecord while sandbox open still writes sovereign only', () async {
    final bus = _freshBus();
    await bus.initialize();
    await bus.openSandbox(reset: true);

    final sandboxCount = (await bus.executeQuery(
      'SELECT COUNT(*) AS c FROM telemetry',
    ))
        .first['c'] as int;

    await bus.addRecord(
      latitude: 99.0,
      longitude: 88.0,
      accelerometerZ: 2.0,
      compassDirection: 0.0,
    );

    final sandboxAfter = (await bus.executeQuery(
      'SELECT COUNT(*) AS c FROM telemetry',
    ))
        .first['c'] as int;
    expect(sandboxAfter, sandboxCount);

    await bus.closeSandbox();
    final sovereign = await bus.getRecentRecords(5);
    expect(sovereign.any((r) => r.latitude == 99.0), isTrue);

    bus.dispose();
  });
}
