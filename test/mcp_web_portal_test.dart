import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/local_server_service.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Developer MCP Web Portal & Edge Hub', () {
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

    test('GET /tool/mcp_proxy.py returns downloadable Python proxy script', () async {
      final client = HttpClient();
      final base = server.localhostAddress;
      final request = await client.getUrl(Uri.parse('$base/tool/mcp_proxy.py'));
      final response = await request.close();

      expect(response.statusCode, 200);
      expect(
        response.headers.value('content-type'),
        contains('text/x-python'),
      );
      expect(
        response.headers.value('content-disposition'),
        contains('attachment; filename="mcp_proxy.py"'),
      );

      final body = await response.transform(utf8.decoder).join();
      expect(body, contains('MCP Proxy for Project Aur Bhai'));
      expect(body, contains('urllib.request'));
      client.close();
    });

    test('GET /dev returns Developer Setup Portal with IDE configs', () async {
      final client = HttpClient();
      final base = server.localhostAddress;
      final request = await client.getUrl(Uri.parse('$base/dev'));
      final response = await request.close();

      expect(response.statusCode, 200);
      expect(
        response.headers.value('content-type'),
        contains('text/html'),
      );

      final body = await response.transform(utf8.decoder).join();
      expect(body, contains('Aur Bhai // Developer Portal'));
      expect(body, contains('Download mcp_proxy.py'));
      expect(body, contains('mcp_list_agents'));
      expect(body, contains('mcp_deploy_agent'));
      client.close();
    });

    test('GET / returns Unified Web Hub landing page', () async {
      final client = HttpClient();
      final base = server.localhostAddress;
      final request = await client.getUrl(Uri.parse('$base/'));
      final response = await request.close();

      expect(response.statusCode, 200);
      expect(
        response.headers.value('content-type'),
        contains('text/html'),
      );

      final body = await response.transform(utf8.decoder).join();
      expect(body, contains('Aur Bhai // Web Hub'));
      expect(body, contains('Open Developer Portal'));
      client.close();
    });

    test('GET /api/events connects and receives broadcastDashboardOpen', () async {
      final client = HttpClient()..autoUncompress = false;
      final base = server.localhostAddress;
      final request = await client.getUrl(Uri.parse('$base/api/events'));
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();

      expect(response.statusCode, 200);
      expect(
        response.headers.value('content-type'),
        contains('text/event-stream'),
      );

      final connectedCompleter = Completer<void>();
      final broadcastCompleter = Completer<void>();
      final chunks = <String>[];

      final sub = response.transform(utf8.decoder).listen((chunk) {
        chunks.add(chunk);
        if (chunk.contains(': connected') && !connectedCompleter.isCompleted) {
          connectedCompleter.complete();
        }
        if (chunk.contains('open_dashboard') && !broadcastCompleter.isCompleted) {
          broadcastCompleter.complete();
        }
      });

      await connectedCompleter.future.timeout(const Duration(seconds: 3));
      server.broadcastDashboardOpen('wishes.html');
      await broadcastCompleter.future.timeout(const Duration(seconds: 3));

      expect(chunks.any((c) => c.contains(': connected')), isTrue);
      expect(chunks.any((c) => c.contains('open_dashboard')), isTrue);

      await sub.cancel();
      client.close(force: true);
    });
  });
}
