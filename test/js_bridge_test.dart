import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/agents/agent_base.dart';
import 'package:project_aur_bhai/core/agents/js_agent_adapter.dart';
import 'package:project_aur_bhai/core/services/agent_service.dart';
import 'package:project_aur_bhai/core/services/js_agent_registry.dart';
import 'package:project_aur_bhai/core/services/js_bridge_service.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

bool _quickJsNativeLibAvailable() {
  final override = Platform.environment['LIBQUICKJSC_TEST_PATH'];
  if (override != null && override.isNotEmpty && File(override).existsSync()) {
    return true;
  }
  const candidates = [
    'packages/quickjs_engine/native/build/quickjs_c_bridge_plugin.dll',
    '../packages/quickjs_engine/native/build/quickjs_c_bridge_plugin.dll',
    'native/build/quickjs_c_bridge_plugin.dll',
  ];
  return candidates.any((p) => File(p).existsSync());
}

/// MS-JS-BRIDGE validation: sandbox execution + System bridge APIs.
void main() {
  final quickJsAvailable = _quickJsNativeLibAvailable();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('MS-JS-BRIDGE — vault registry (no native QuickJS required)', () {
    late ProviderContainer container;

    setUp(() async {
      container = ProviderContainer();
      await container.read(telemetryBusProvider).initialize();
    });

    tearDown(() {
      container.dispose();
    });

    test('seed + load registers TelemetryCounter adapter', () async {
      final registry = container.read(jsAgentRegistryProvider);
      await registry.seedDemoAgentIfMissing();
      final count = await registry.loadAndRegisterAgents();
      expect(count, greaterThanOrEqualTo(1));

      final agentService = container.read(agentServiceProvider);
      final agent = agentService.findAgent('TelemetryCounter');
      expect(agent, isA<JsAgentAdapter>());
    });

    test('MS-CORE-JS-MIGRATION: core agents seed as C2 JS agents', () async {
      final registry = container.read(jsAgentRegistryProvider);
      await registry.seedCoreAgentsIfMissing();
      await registry.loadAndRegisterAgents();

      final agentService = container.read(agentServiceProvider);

      final calculator = agentService.findAgent('Calculator');
      expect(calculator, isA<JsAgentAdapter>());
      expect((calculator as JsAgentAdapter).securityClass,
          AgentSecurityClass.c2Verified);
      expect(calculator.script, contains('Math.pow'));

      final coach = agentService.findAgent('DrivingCoach');
      expect(coach, isA<JsAgentAdapter>());
      expect((coach as JsAgentAdapter).securityClass,
          AgentSecurityClass.c2Verified);
    });

    test('MS-USER-ECOSYSTEM lifecycle: save, list, export, delete', () async {
      if (!quickJsAvailable) {
        markTestSkipped(
          'Saving validates syntax; QuickJS native library is not built on this host',
        );
        return;
      }
      final registry = container.read(jsAgentRegistryProvider);
      final agentService = container.read(agentServiceProvider);

      final adapter = await registry.saveAndRegisterAgent(
        name: 'EchoAgent',
        description: 'Echoes a message.',
        inputSchema: const {
          'message': AgentParameter(type: 'string', description: 'msg'),
        },
        script: 'async function execute(params){ return params.message; }',
        securityClass: AgentSecurityClass.c3DueDiligence,
      );
      expect(adapter.securityClass, AgentSecurityClass.c3DueDiligence);
      expect(adapter.script, contains('execute'));

      // Registered live
      expect(agentService.findAgent('EchoAgent'), isA<JsAgentAdapter>());

      // Persisted to vault + listable
      final names = await registry.listJsAgentNames();
      expect(names, contains('EchoAgent'));

      // Exportable bundle carries script + schema + securityClass
      final bundle = await registry.exportAgentBundle('EchoAgent');
      expect(bundle, isNotNull);
      expect(bundle!['script'], contains('execute'));
      expect((bundle['schema'] as Map)['securityClass'], 'C3');

      // Survives a fresh registry reload from the vault
      await registry.loadAndRegisterAgents();
      final reloaded = agentService.findAgent('EchoAgent') as JsAgentAdapter;
      expect(reloaded.securityClass, AgentSecurityClass.c3DueDiligence);

      // Delete removes from both vault and live registry
      await registry.deleteAgent('EchoAgent');
      expect(agentService.findAgent('EchoAgent'), isNull);
      expect(await registry.listJsAgentNames(), isNot(contains('EchoAgent')));
    });
  });

  group('MS-JS-BRIDGE — QuickJS sandbox & System API', () {
    late ProviderContainer container;

    setUp(() async {
      container = ProviderContainer();
      await container.read(telemetryBusProvider).initialize();
    });

    tearDown(() {
      container.dispose();
    });

    test('System.querySQL returns telemetry row count', () async {
      final bus = container.read(telemetryBusProvider);
      await bus.addRecord(
        latitude: 28.61,
        longitude: 77.20,
        accelerometerZ: 9.8,
        compassDirection: 90.0,
      );

      final bridge = container.read(jsBridgeServiceProvider);
      final result = await bridge.executeAgentScript(
        agentName: 'QueryProbe',
        script: '''
async function execute(params) {
  const rows = await System.querySQL('SELECT COUNT(*) AS count FROM telemetry');
  return 'count:' + rows[0].count;
}
''',
        parameters: const {},
      );

      expect(result.message, contains('count:'));
    }, skip: quickJsAvailable ? false : 'QuickJS native library not built (cmake required on Windows)');

    test('System.writeVault persists to sovereign_vault', () async {
      final bridge = container.read(jsBridgeServiceProvider);
      final bus = container.read(telemetryBusProvider);

      final result = await bridge.executeAgentScript(
        agentName: 'VaultProbe',
        script: '''
async function execute(params) {
  await System.writeVault('js_bridge:test', 'hello-from-js', 'text/plain');
  return 'written';
}
''',
        parameters: const {},
      );

      expect(result.message, 'written');
      final entry = await bus.readVaultData('js_bridge:test');
      expect(entry?['value'], 'hello-from-js');
    }, skip: quickJsAvailable ? false : 'QuickJS native library not built (cmake required on Windows)');

    test('vault agent executes TelemetryCounter script', () async {
      final registry = container.read(jsAgentRegistryProvider);
      await registry.seedDemoAgentIfMissing();
      await registry.loadAndRegisterAgents();

      final agentService = container.read(agentServiceProvider);
      final agent = agentService.findAgent('TelemetryCounter');
      expect(agent, isNotNull);

      final spoken = await agent!.execute(const {});
      expect(spoken, contains('TelemetryCounter agent says'));
    }, skip: quickJsAvailable ? false : 'QuickJS native library not built (cmake required on Windows)');

    test('MS-CORE-JS-MIGRATION: JS Calculator handles the ^ power operator', () async {
      final registry = container.read(jsAgentRegistryProvider);
      await registry.seedCoreAgentsIfMissing();
      await registry.loadAndRegisterAgents();

      final agent =
          container.read(agentServiceProvider).findAgent('Calculator');
      expect(agent, isNotNull);

      final power = await agent!.execute(const {'expression': '2^3'});
      expect(power, contains('8'));

      final mixed = await agent.execute(const {'expression': '2 + 3 * 4'});
      expect(mixed, contains('14'));

      final parens = await agent.execute(const {'expression': '(2 + 3) ^ 2'});
      expect(parens, contains('25'));
    }, skip: quickJsAvailable ? false : 'QuickJS native library not built (cmake required on Windows)');

    test('MS-CORE-JS-MIGRATION: JS DrivingCoach predicts from telemetry', () async {
      final bus = container.read(telemetryBusProvider);
      for (var n = 0; n < 8; n++) {
        await bus.addRecord(
          latitude: 28.61,
          longitude: 77.20,
          accelerometerZ: 9.8 + (n % 3) * 0.1,
          compassDirection: 90.0,
        );
      }

      final registry = container.read(jsAgentRegistryProvider);
      await registry.seedCoreAgentsIfMissing();
      await registry.loadAndRegisterAgents();

      final agent =
          container.read(agentServiceProvider).findAgent('DrivingCoach');
      expect(agent, isNotNull);

      final spoken = await agent!.execute(const {'recordCount': 8});
      expect(spoken, contains('My model predicts you are currently'));
    }, skip: quickJsAvailable ? false : 'QuickJS native library not built (cmake required on Windows)');
    test('async agent returns spoken string not promise index', () async {
      final bridge = container.read(jsBridgeServiceProvider);
      final result = await bridge.executeAgentScript(
        agentName: 'FiveIntoSix',
        script: '''
async function execute(params) {
  System.log('Executing FiveIntoSix calculation');
  const result = 5 * 6;
  return 'Five times six is ' + result + '.';
}
''',
        parameters: const {},
      );

      expect(result.message, isNot('0'));
      expect(result.message, contains('30'));
      expect(result.message, contains('Five times six'));
    }, skip: quickJsAvailable ? false : 'QuickJS native library not built (cmake required on Windows)');
  });
}
