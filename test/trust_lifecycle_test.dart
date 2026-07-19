import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:project_aur_bhai/core/agents/js_agent_adapter.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_capability_judge.dart';
import 'package:project_aur_bhai/core/services/agent_verification_service.dart';
import 'package:project_aur_bhai/core/services/js_agent_registry.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('due diligence returns structured finding codes', () {
    final v = AgentVerificationService();
    final scan = v.scanScript('eval("x"); const api_key = "x";');
    expect(scan.passed, isFalse);
    expect(scan.findings.any((f) => f.code == 'DD_DYNAMIC_CODE'), isTrue);
    expect(scan.findings.any((f) => f.code == 'DD_HARDCODED_SECRET'), isTrue);
  });

  test('C4→C3→C2 promotion path', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final bus = container.read(telemetryBusProvider);
    await bus.initialize();
    final registry = container.read(jsAgentRegistryProvider);
    final verification = container.read(agentVerificationProvider);

    const name = 'TrustProbe';
    const script = 'async function execute(p) { return "ok"; }';
    // Avoid QuickJS native DLL in this test — write vault rows directly.
    await bus.writeVaultData(
      registry.vaultKeyFor(name),
      script,
      mimeType: 'application/javascript',
    );
    await bus.writeVaultData(
      registry.schemaKeyFor(name),
      jsonEncode({
        'name': name,
        'description': 'probe',
        'securityClass': AgentSecurityClass.c4Unverified.id,
        'createdAt': DateTime.now().toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
        'inputSchema': <String, dynamic>{},
      }),
      mimeType: 'application/json',
    );

    final scan = verification.scanScript(script);
    expect(scan.passed, isTrue);

    expect(
      await verification.promoteToVerified(
        registry: registry,
        agentName: name,
        priorScan: scan,
      ),
      isFalse,
      reason: 'cannot skip C3',
    );

    expect(
      await verification.promoteToDueDiligence(
        registry: registry,
        agentName: name,
        priorScan: scan,
      ),
      isTrue,
    );

    final mid = await registry.exportAgentBundle(name);
    expect((mid?['schema'] as Map)['securityClass'], 'C3');

    expect(
      await verification.promoteToVerified(
        registry: registry,
        agentName: name,
        priorScan: scan,
      ),
      isTrue,
    );
    final end = await registry.exportAgentBundle(name);
    expect((end?['schema'] as Map)['securityClass'], 'C2');
  });

  test('capability judge fail-closed on empty trace', () async {
    final judge = HeuristicBroCodeCapabilityJudge();
    final j = await judge.judge(
      changeRequest: 'post a tweet',
      trace: const BroCodeExecutionTrace(ranOk: true, events: []),
    );
    expect(j.ok, isFalse);
  });
}
