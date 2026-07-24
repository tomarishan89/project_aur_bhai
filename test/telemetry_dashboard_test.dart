import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/agents/js_agent_adapter.dart';
import 'package:project_aur_bhai/core/services/agent_service.dart';
import 'package:project_aur_bhai/core/services/agent_verification_service.dart';
import 'package:project_aur_bhai/core/services/js_agent_registry.dart';
import 'package:project_aur_bhai/core/services/js_bridge_service.dart';
import 'package:project_aur_bhai/core/services/local_server_service.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

bool _quickJsNativeLibAvailable() {
  const candidates = [
    'packages/quickjs_engine/native/build/quickjs_c_bridge_plugin.dll',
    '../packages/quickjs_engine/native/build/quickjs_c_bridge_plugin.dll',
    'native/build/quickjs_c_bridge_plugin.dll',
  ];
  return candidates.any((p) => File(p).existsSync());
}

String _dashboardWithDownload(String baseScript) {
  return baseScript
      .replaceFirst('<header>', '<header><button id="dl">Download CSV</button>')
      .replaceFirst('  refresh();', r'''  async function downloadCsv() {
    const rows = await query('SELECT * FROM telemetry ORDER BY timestamp DESC LIMIT 500');
    if (!rows.length) return;
    const keys = Object.keys(rows[0]);
    const lines = [keys.join(',')].concat(rows.map(function(r) {
      return keys.map(function(k) { return r[k]; }).join(',');
    }));
    const blob = new Blob([lines.join('\n')], { type: 'text/csv' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'telemetry.csv';
    a.click();
    URL.revokeObjectURL(a.href);
  }
  document.getElementById('dl').onclick = downloadCsv;
  refresh();''');
}

/// Dashboard Agent Readiness — Goals 1 & 2 (automated path).
void main() {
  final quickJsAvailable = _quickJsNativeLibAvailable();
  late final String dashboardScript;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dashboardScript = File('examples/TelemetryDashboard.js').readAsStringSync();
  });

  group('Goal 1 — Telemetry dashboard agent + LAN edge URL', () {
    late ProviderContainer container;
    late LocalServerService server;

    setUp(() async {
      container = ProviderContainer();
      await container.read(telemetryBusProvider).initialize();
      final bus = container.read(telemetryBusProvider);
      for (var i = 0; i < 10; i++) {
        await bus.addRecord(
          latitude: 28.6139 + i * 0.001,
          longitude: 77.2090,
          accelerometerZ: 9.8 + i * 0.05,
          compassDirection: 180.0,
        );
      }
      server = container.read(localServerProvider);
      await server.startServer(preferredPort: 0);
    });

    tearDown(() async {
      await server.stopServer();
      container.dispose();
    });

    test(
      'Path B: import TelemetryDashboard.js, RUN writes live chart HTML to vault',
      () async {
        final registry = container.read(jsAgentRegistryProvider);
        await registry.saveAndRegisterAgent(
          name: 'TelemetryDashboard',
          description: 'Live telemetry charts from vault',
          inputSchema: const {},
          script: dashboardScript,
          securityClass: AgentSecurityClass.c2Verified,
        );

        final agent = container
            .read(agentServiceProvider)
            .findAgent('TelemetryDashboard');
        expect(agent, isNotNull);
        expect((agent as JsAgentAdapter).canExecute, isTrue);

        final spoken = await agent.execute(const {});
        expect(spoken.toLowerCase(), contains('dashboard'));
        expect(agent.lastExecutionResult?.vaultHtmlKeysWritten, isNotEmpty);

        final vault = await container
            .read(telemetryBusProvider)
            .readVaultData('telemetry_dashboard.html');
        expect(vault, isNotNull);
        expect(vault!['mime_type'], 'text/html');
        expect(vault['value'], contains('id="chart"'));
        expect(vault['value'], contains('/api/query'));
        expect(vault['value'], contains('setInterval'));
      },
      skip: quickJsAvailable ? false : 'QuickJS native library not built',
    );

    test(
      'dashboard HTML is served at /vault/ and /api/query returns telemetry',
      () async {
        final bridge = container.read(jsBridgeServiceProvider);
        await bridge.executeAgentScript(
          agentName: 'TelemetryDashboard',
          script: dashboardScript,
          parameters: const {},
        );

        final base = server.localhostAddress;
        final client = HttpClient();

        final vaultReq = await client.getUrl(
          Uri.parse('$base/vault/telemetry_dashboard.html'),
        );
        final vaultRes = await vaultReq.close();
        expect(vaultRes.statusCode, 200);
        final html = await vaultRes.transform(utf8.decoder).join();
        expect(html, contains('PROJECT AUR BHAI'));
        expect(html, contains('canvas'));

        final queryReq = await client.postUrl(Uri.parse('$base/api/query'));
        queryReq.headers.contentType = ContentType.json;
        queryReq.write(
          jsonEncode({'sql': 'SELECT COUNT(*) AS c FROM telemetry'}),
        );
        final queryRes = await queryReq.close();
        expect(queryRes.statusCode, 200);
        final queryJson =
            jsonDecode(await queryRes.transform(utf8.decoder).join())
                as Map<String, dynamic>;
        expect(queryJson['success'], isTrue);
        expect(
          (queryJson['data'] as List).first['c'],
          greaterThanOrEqualTo(10),
        );

        client.close();
      },
      skip: quickJsAvailable ? false : 'QuickJS native library not built',
    );

    test('vaultUrl builds reachable dashboard path', () async {
      await server.refreshLanIp();
      final url = server.vaultUrl('telemetry_dashboard.html');
      expect(url, contains('http://'));
      expect(url, endsWith('/vault/telemetry_dashboard.html'));
    });
  });

  group('Goal 2 — Refined dashboard with client-side CSV download', () {
    late ProviderContainer container;

    setUp(() async {
      container = ProviderContainer();
      await container.read(telemetryBusProvider).initialize();
    });

    tearDown(() {
      container.dispose();
    });

    test('download patch template passes due diligence scan', () {
      final withDownload = _dashboardWithDownload(dashboardScript);
      final scan = AgentVerificationService().scanScript(withDownload);
      expect(scan.passed, isTrue, reason: scan.findings.join(', '));
      expect(withDownload, contains('createObjectURL'));
    });

    test(
      'refined script with Download CSV passes due diligence and writes HTML',
      () async {
        final withDownload = _dashboardWithDownload(dashboardScript);
        expect(withDownload, contains('Download CSV'));

        final verification = AgentVerificationService();
        final scan = verification.scanScript(withDownload);
        expect(scan.passed, isTrue, reason: scan.findings.join(', '));

        final registry = container.read(jsAgentRegistryProvider);
        await registry.refineAndReregister(
          name: 'TelemetryDashboard',
          script: withDownload,
          description: 'Dashboard with CSV export',
        );

        final agent = container
            .read(agentServiceProvider)
            .findAgent('TelemetryDashboard');
        await agent!.execute(const {});

        final html = (await container
            .read(telemetryBusProvider)
            .readVaultData('telemetry_dashboard.html'))!['value']!;
        expect(html, contains('Download CSV'));
        expect(html, contains('createObjectURL'));
        expect(html, contains('text/csv'));
      },
      skip: quickJsAvailable ? false : 'QuickJS native library not built',
    );
  });
}
