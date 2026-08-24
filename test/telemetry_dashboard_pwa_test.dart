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

void main() {
  final quickJsAvailable = _quickJsNativeLibAvailable();
  late final String telemeterScript;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    telemeterScript = File('examples/TelemetryDashboard.js').readAsStringSync();
  });

  group('Telemeter PWA Dashboard — Unit & Bridge Tests', () {
    late ProviderContainer container;
    late LocalServerService server;

    setUp(() async {
      container = ProviderContainer();
      await container.read(telemetryBusProvider).initialize();
      final bus = container.read(telemetryBusProvider);
      for (var i = 0; i < 10; i++) {
        await bus.addRecord(
          latitude: 28.6139 + i * 0.001,
          longitude: 77.2090 + i * 0.001,
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

    test('Telemeter script passes automated due diligence security scan', () {
      final scan = AgentVerificationService().scanScript(telemeterScript);
      expect(scan.passed, isTrue, reason: scan.findings.join(', '));
    });

    test('Telemeter dashboard.html asset includes dual range slider with end time initialized at end', () {
      final dashboardFile = File('assets/bro_code/telemeter/dashboard.html');
      expect(dashboardFile.existsSync(), isTrue);
      final html = dashboardFile.readAsStringSync();
      expect(html, contains('id="panSliderStart"'));
      expect(html, contains('id="panSliderEnd"'));
      expect(html, contains('id="rangeTrack"'));
      expect(html, contains('id="win-start"'));
      expect(html, contains('id="win-end"'));
      expect(html, contains('startSlider.value = minTs;'));
      expect(html, contains('endSlider.value = maxTs;'));
      expect(html, contains('onPanSlider(event)'));
      expect(html, contains('onPresetChange'));
    });

    test(
      'Execution of Telemeter writes telemeter.html & telemetry_dashboard.html PWA documents',
      () async {
        final registry = container.read(jsAgentRegistryProvider);
        await registry.saveAndRegisterAgent(
          name: 'Telemeter',
          description: 'Sovereign Telemetry PWA Dashboard',
          inputSchema: const {},
          script: telemeterScript,
          securityClass: AgentSecurityClass.c2Verified,
        );

        final agent = container.read(agentServiceProvider).findAgent('Telemeter');
        expect(agent, isNotNull);

        final spoken = await agent!.execute(const {});
        expect(spoken.toLowerCase(), contains('telemeter'));
        expect(spoken.toLowerCase(), contains('dashboard'));

        final telemeterVault = await container
            .read(telemetryBusProvider)
            .readVaultData('telemeter.html');
        expect(telemeterVault, isNotNull);
        expect(telemeterVault!['mime_type'], 'text/html');

        final html = telemeterVault['value']!;
        expect(html, contains('<title>Telemeter — Sovereign Telemetry Dashboard</title>'));
        expect(html, contains('rel="manifest"'));
        expect(html, contains('leaflet'));
        expect(html, contains('data-theme="cyber"'));
        expect(html, contains('doExport'));
        expect(html, contains('application/geo+json'));
        expect(html, contains('text/csv'));
      },
      skip: quickJsAvailable ? false : 'QuickJS native library not built',
    );

    test(
      'Local Edge Server serves /vault/telemeter.html with valid PWA headers',
      () async {
        final bridge = container.read(jsBridgeServiceProvider);
        await bridge.executeAgentScript(
          agentName: 'Telemeter',
          script: telemeterScript,
          parameters: const {},
        );

        final base = server.localhostAddress;
        final client = HttpClient();

        final req = await client.getUrl(Uri.parse('$base/vault/telemeter.html'));
        final res = await req.close();
        expect(res.statusCode, 200);

        final body = await res.transform(utf8.decoder).join();
        expect(body, contains('TELEMETER'));
        expect(body, contains('motionChart'));
        expect(body, contains('kpi-dist'));

        client.close();
      },
      skip: quickJsAvailable ? false : 'QuickJS native library not built',
    );
  });
}
