import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:project_aur_bhai/core/services/telemetry_bus.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('sandbox vault is isolated from sovereign vault', () async {
    final bus = TelemetryBusService();
    await bus.initialize();

    await bus.writeVaultData('sovereign-only', 'real-secret', mimeType: 'text/plain');

    await bus.openSandbox(reset: true);
    expect(bus.isSandboxActive, isTrue);

    final seedRows = await bus.executeQuery('SELECT COUNT(*) AS c FROM telemetry');
    expect(seedRows.first['c'], 8,
        reason: 'sandbox must seed a synthetic telemetry cluster');

    await bus.writeVaultData('sandbox-key', 'mock-only', mimeType: 'text/plain');
    final sandboxRead = await bus.readVaultData('sandbox-key');
    // readVaultData always hits sovereign DB (registry/admin path).
    expect(sandboxRead, isNull);

    final sandboxedRows = await bus.executeQuery(
      "SELECT value FROM sovereign_vault WHERE key = 'sandbox-key'",
    );
    expect(sandboxedRows, isNotEmpty);
    expect(sandboxedRows.first['value'], 'mock-only');

    final leakCheck = await bus.executeQuery(
      "SELECT value FROM sovereign_vault WHERE key = 'sovereign-only'",
    );
    expect(leakCheck, isEmpty,
        reason: 'sandbox must not see sovereign vault rows');

    await bus.closeSandbox();
    expect(bus.isSandboxActive, isFalse);

    final sovereign = await bus.readVaultData('sovereign-only');
    expect(sovereign?['value'], 'real-secret');
    final afterClose = await bus.executeQuery(
      "SELECT value FROM sovereign_vault WHERE key = 'sandbox-key'",
    );
    expect(afterClose, isEmpty);

    bus.dispose();
  });
}
