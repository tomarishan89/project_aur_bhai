import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/local_server_service.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('LocalServerService QR Code & Dashboard URL generation', () {
    late ProviderContainer container;
    late LocalServerService server;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      container = ProviderContainer();
      await container.read(telemetryBusProvider).initialize();
      server = container.read(localServerProvider);
      await server.startServer(preferredPort: 0);
    });

    tearDown(() async {
      await server.stopServer();
      container.dispose();
    });

    test('generateQrSvg produces pure vector SVG with dark modules', () {
      const url = 'http://192.168.1.5:8080/vault/telemeter.html?pair=ABC123';
      final svg = LocalServerService.generateQrSvg(url);

      expect(svg, isNotEmpty);
      expect(svg, contains('<svg xmlns="http://www.w3.org/2000/svg"'));
      expect(svg, contains('viewBox="0 0 '));
      expect(svg, contains('<rect width="100%" height="100%" fill="#ffffff"/>'));
      expect(svg, contains('<rect x='));
      expect(svg, contains('fill="#000000"/>'));
      expect(svg, contains('</svg>'));
    });

    test('generateQrSvg returns empty string for empty input', () {
      expect(LocalServerService.generateQrSvg(''), '');
      expect(LocalServerService.generateQrSvg('   '), '');
    });

    test('GET /api/qr returns HTTP 200 with image/svg+xml', () async {
      final base = server.localhostAddress;
      final client = HttpClient();

      const testUrl = 'http://localhost:8080/vault/telemeter.html?pair=XYZ999';
      final req = await client.getUrl(
        Uri.parse('$base/api/qr?data=${Uri.encodeComponent(testUrl)}'),
      );
      final res = await req.close();
      expect(res.statusCode, 200);
      expect(res.headers.contentType.toString(), contains('image/svg+xml'));

      final body = await res.transform(utf8.decoder).join();
      expect(body, contains('<svg xmlns="http://www.w3.org/2000/svg"'));
      expect(body, contains('</svg>'));

      client.close();
    });

    test('GET /api/qr rejects requests with missing data parameter', () async {
      final base = server.localhostAddress;
      final client = HttpClient();

      final req = await client.getUrl(Uri.parse('$base/api/qr'));
      final res = await req.close();
      expect(res.statusCode, 400);

      client.close();
    });

    test('GET / includes QR buttons and modal markup on Web Hub', () async {
      final base = server.localhostAddress;
      final client = HttpClient();

      final req = await client.getUrl(Uri.parse('$base/'));
      final res = await req.close();
      expect(res.statusCode, 200);

      final body = await res.transform(utf8.decoder).join();
      expect(body, contains('openQrModal'));
      expect(body, contains('id="qr-modal"'));
      expect(body, contains('id="qr-img"'));
      expect(body, contains('/api/qr?data='));

      client.close();
    });
  });
}
