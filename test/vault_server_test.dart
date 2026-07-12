import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/local_server_service.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Manifest Test Case A (vault integrity) + Test Case B (edge server health).
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('MS-VAULT-SERVER Test Case A — Sovereign Vault Integrity', () {
    late ProviderContainer container;

    setUp(() async {
      container = ProviderContainer();
      await container.read(telemetryBusProvider).initialize();
    });

    tearDown(() {
      container.dispose();
    });

    test('mock telemetry records persist in SQLite without query errors', () async {
      final bus = container.read(telemetryBusProvider);

      for (var i = 0; i < 5; i++) {
        await bus.addRecord(
          latitude: 28.6139 + i * 0.001,
          longitude: 77.2090 + i * 0.001,
          accelerometerZ: 9.8 + i * 0.1,
          compassDirection: 180.0 + i,
        );
      }

      final rows = await bus.executeQuery(
        'SELECT COUNT(*) AS count FROM telemetry',
      );
      expect(rows.first['count'], greaterThanOrEqualTo(5));

      final recent = await bus.getRecentRecords(5);
      expect(recent.length, 5);
      expect(recent.first.accelerometerZ, isNonZero);
    });
  });

  group('MS-VAULT-SERVER Test Case B — Edge Server Health', () {
    late ProviderContainer container;
    late LocalServerService server;

    setUp(() async {
      container = ProviderContainer();
      await container.read(telemetryBusProvider).initialize();
      server = container.read(localServerProvider);
      await server.startServer(preferredPort: 0);
    });

    tearDown(() async {
      await server.stopServer();
      container.dispose();
    });

    test('binds all interfaces — localhost still reachable', () async {
      expect(server.isRunning, isTrue);
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse('${server.localhostAddress}/api/status'),
      );
      final response = await request.close();
      expect(response.statusCode, 200);
      client.close();
    });

    test('GET /api/status returns active JSON', () async {
      expect(server.isRunning, isTrue);
      expect(server.port, isNotNull);

      final client = HttpClient();
      final base = server.localhostAddress;
      final request = await client.getUrl(Uri.parse('$base/api/status'));
      final response = await request.close();
      expect(response.statusCode, 200);

      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['status'], 'active');
      expect(json['engine'], 'Project Aur Bhai');
      client.close();
    });

    test('POST /api/query reads telemetry table', () async {
      final bus = container.read(telemetryBusProvider);
      await bus.addRecord(
        latitude: 28.61,
        longitude: 77.20,
        accelerometerZ: 9.8,
        compassDirection: 90.0,
      );

      final client = HttpClient();
      final base = server.localhostAddress;
      final request = await client.postUrl(Uri.parse('$base/api/query'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'sql': 'SELECT COUNT(*) AS count FROM telemetry',
      }));
      final response = await request.close();
      expect(response.statusCode, 200);

      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['success'], isTrue);
      expect((json['data'] as List).first['count'], greaterThanOrEqualTo(1));
      client.close();
    });
  });
}
