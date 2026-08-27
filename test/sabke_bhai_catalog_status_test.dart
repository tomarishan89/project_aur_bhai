import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:project_aur_bhai/core/agents/agent_base.dart';
import 'package:project_aur_bhai/core/agents/js_agent_adapter.dart';
import 'package:project_aur_bhai/core/models/lineage_entry.dart';
import 'package:project_aur_bhai/core/services/agent_service.dart';
import 'package:project_aur_bhai/core/services/bhai_code_origin.dart';
import 'package:project_aur_bhai/core/services/marketplace_catalog.dart';
import 'package:project_aur_bhai/presentation/screens/ambient_hub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Sabke Bhai Live Status Resolution Specification', () {
    test('identifies In Mere Bhai when agent is C1 Core or C2 Verified', () {
      final dummyProvider = Provider<Ref>((ref) => ref);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ref = container.read(dummyProvider);
      final agentService = container.read(agentServiceProvider);

      // Register Calculator as C2 Verified
      final calculator = JsAgentAdapter(
        ref: ref,
        name: 'Calculator',
        description: 'Sovereign math evaluator',
        inputSchema: {},
        script: 'async function execute(){}',
        securityClass: AgentSecurityClass.c2Verified,
        source: BhaiCodeOrigin.pool,
        author: '@core',
      );
      agentService.registerAgent(calculator);

      final installed = agentService.findAgent('Calculator');
      expect(installed, isNotNull);
      final isMereBhai = installed is JsAgentAdapter &&
          (installed.securityClass == AgentSecurityClass.c1Core ||
              installed.securityClass == AgentSecurityClass.c2Verified);
      final isSandbox = installed is JsAgentAdapter &&
          (installed.securityClass == AgentSecurityClass.c3DueDiligence ||
              installed.securityClass == AgentSecurityClass.c4Unverified);

      expect(isMereBhai, isTrue);
      expect(isSandbox, isFalse);
    });

    test('identifies In Sandbox when agent is C4 Unverified or C3 Due Diligence', () {
      final dummyProvider = Provider<Ref>((ref) => ref);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ref = container.read(dummyProvider);
      final agentService = container.read(agentServiceProvider);

      // Register Accountant as C4 Unverified
      final accountant = JsAgentAdapter(
        ref: ref,
        name: 'Accountant',
        description: 'Sovereign expenditure logger',
        inputSchema: {},
        script: 'async function execute(){}',
        securityClass: AgentSecurityClass.c4Unverified,
        source: BhaiCodeOrigin.pool,
        author: '@core',
      );
      agentService.registerAgent(accountant);

      final installed = agentService.findAgent('Accountant');
      expect(installed, isNotNull);
      final isMereBhai = installed is JsAgentAdapter &&
          (installed.securityClass == AgentSecurityClass.c1Core ||
              installed.securityClass == AgentSecurityClass.c2Verified);
      final isSandbox = installed is JsAgentAdapter &&
          (installed.securityClass == AgentSecurityClass.c3DueDiligence ||
              installed.securityClass == AgentSecurityClass.c4Unverified);

      expect(isMereBhai, isFalse);
      expect(isSandbox, isTrue);
    });

    test('identifies Browse · Get when agent is not installed in vault', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final agentService = container.read(agentServiceProvider);

      final installed = agentService.findAgent('UninstalledTool');
      expect(installed, isNull);
    });
  });
}
