import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:project_aur_bhai/core/agents/agent_base.dart';
import 'package:project_aur_bhai/core/services/agent_service.dart';
import 'package:project_aur_bhai/core/services/llm_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockBroCode extends BroCode {
  @override
  final String name;
  @override
  final String description;
  @override
  final Map<String, BroCodeParameter> inputSchema;

  MockBroCode({
    required this.name,
    required this.description,
    this.inputSchema = const {},
  });

  @override
  Future<String> execute(Map<String, dynamic> parameters) async {
    return 'Executed $name with $parameters';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late BroCodeService agentService;
  late LlmService llmService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
    agentService = container.read(agentServiceProvider);
    llmService = container.read(llmServiceProvider);

    // Register standard test agents
    agentService.register(
      MockBroCode(
        name: 'Calculator',
        description: 'Standard arithmetic solver',
        inputSchema: {
          'expression': const BroCodeParameter(
            type: 'string',
            description: 'Math expression',
          ),
        },
      ),
    );

    agentService.register(
      MockBroCode(
        name: 'Telemeter',
        description: 'Sovereign IMU Dashboard',
        inputSchema: const {},
      ),
    );

    agentService.register(
      MockBroCode(
        name: 'Accountant',
        description: 'Personal expense tracker',
        inputSchema: {
          'text': const BroCodeParameter(
            type: 'string',
            description: 'Expense entry',
          ),
        },
      ),
    );

    agentService.register(
      MockBroCode(
        name: 'Note Taker',
        description: 'Offline voice note taker',
        inputSchema: {
          'note': const BroCodeParameter(
            type: 'string',
            description: 'Note text',
          ),
        },
      ),
    );
  });

  tearDown(() {
    container.dispose();
  });

  group('LlmService.parseTurn Fast-Path Routing (Zero-Key Execution)', () {
    test('routes exact agent name directly without API key', () async {
      final turn = await llmService.parseTurn(text: 'calculator');
      expect(turn.intent, AgentIntent.execute);
      expect(turn.targetAgent, 'Calculator');
      expect(turn.confirmation, contains('Calculator'));
    });

    test('routes action verbs (open/run/launch/start/show) directly', () async {
      final t1 = await llmService.parseTurn(text: 'open telemeter');
      expect(t1.intent, AgentIntent.execute);
      expect(t1.targetAgent, 'Telemeter');

      final t2 = await llmService.parseTurn(text: 'run accountant');
      expect(t2.intent, AgentIntent.execute);
      expect(t2.targetAgent, 'Accountant');

      final t3 = await llmService.parseTurn(text: 'launch note taker');
      expect(t3.intent, AgentIntent.execute);
      expect(t3.targetAgent, 'Note Taker');

      final t4 = await llmService.parseTurn(text: 'show telemeter dashboard');
      expect(t4.intent, AgentIntent.execute);
      expect(t4.targetAgent, 'Telemeter');
    });

    test('routes Calculator math shortcuts and extracts expression', () async {
      final t1 = await llmService.parseTurn(text: 'calc 25 * 4');
      expect(t1.intent, AgentIntent.execute);
      expect(t1.targetAgent, 'Calculator');
      expect(t1.parameters?['expression'], '25 * 4');

      final t2 = await llmService.parseTurn(text: 'calculate 2^16');
      expect(t2.intent, AgentIntent.execute);
      expect(t2.targetAgent, 'Calculator');
      expect(t2.parameters?['expression'], '2^16');

      final t3 = await llmService.parseTurn(text: '2 + 2');
      expect(t3.intent, AgentIntent.execute);
      expect(t3.targetAgent, 'Calculator');
      expect(t3.parameters?['expression'], '2 + 2');
    });

    test('routes ask/tell syntax directly with payload', () async {
      final turn = await llmService.parseTurn(
        text: 'ask accountant spent 50 on chai',
      );
      expect(turn.intent, AgentIntent.execute);
      expect(turn.targetAgent, 'Accountant');
      expect(turn.payload, 'spent 50 on chai');
      expect(turn.parameters?['text'], 'spent 50 on chai');
    });

    test('does NOT intercept author queries, falls back with guidance when no key', () async {
      final turn = await llmService.parseTurn(
        text: 'build a pomodoro timer app',
      );
      // Because no API key is configured, it falls back with guidance
      expect(turn.intent, AgentIntent.direct);
      expect(turn.confirmation, contains('configure your API Key'));
      expect(turn.confirmation, contains('Calculator, Telemeter'));
    });

    test('unknown non-command falls back with guidance when no key', () async {
      final turn = await llmService.parseTurn(
        text: 'what is the capital of France?',
      );
      expect(turn.intent, AgentIntent.direct);
      expect(turn.confirmation, contains('configure your API Key'));
    });
  });
}
