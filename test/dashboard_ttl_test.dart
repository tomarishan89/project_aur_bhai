import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('vault TTL set / purge / CSV export', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final bus = container.read(telemetryBusProvider);
    await bus.initialize();

    await bus.writeVaultData(
      'ttl_probe.html',
      '<html>ok</html>',
      mimeType: 'text/html',
      ttl: const Duration(milliseconds: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final purged = await bus.purgeExpiredVaultAssets();
    expect(purged, greaterThanOrEqualTo(1));
    expect(await bus.readVaultData('ttl_probe.html'), isNull);

    await bus.writeVaultData(
      'live.html',
      '<html>live</html>',
      mimeType: 'text/html',
      ttl: const Duration(hours: 24),
    );
    final ok = await bus.setVaultTtl('live.html', null);
    expect(ok, isTrue);
    final row = await bus.readVaultData('live.html');
    expect(row, isNotNull);
    expect(row!['expires_at'] ?? '', isEmpty);

    await bus.addRecord(
      latitude: 12.9,
      longitude: 77.6,
      accelerometerZ: 9.8,
      compassDirection: 90,
    );
    final csv = await bus.exportTelemetryCsv(limit: 10);
    expect(csv.contains('latitude'), isTrue);
    expect(csv.contains('12.9'), isTrue);
  });
}
