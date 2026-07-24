import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:project_aur_bhai/core/pipeline/bro_code_agent_tools.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_coding_agent.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_workspace.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_workspace_snapshot.dart';
import 'package:project_aur_bhai/core/services/js_bridge_service.dart';
import 'package:project_aur_bhai/core/services/llm/llm_provider.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';

import 'support/bro_code_fixture_loader.dart';

bool _quickJsNativeLibAvailable() {
  const candidates = [
    'packages/quickjs_engine/native/build/quickjs_c_bridge_plugin.dll',
    '../packages/quickjs_engine/native/build/quickjs_c_bridge_plugin.dll',
    'native/build/quickjs_c_bridge_plugin.dll',
    'packages/quickjs_engine/native/build/libquickjs_c_bridge_plugin.dylib',
    '../packages/quickjs_engine/native/build/libquickjs_c_bridge_plugin.dylib',
  ];
  return candidates.any((p) => File(p).existsSync());
}

/// Deterministic LLM that returns queued JSON tool actions for E2E IMPROVE.
class ScriptedLlmProvider implements LlmProvider {
  ScriptedLlmProvider(this._replies);

  final List<String> _replies;
  var _i = 0;

  @override
  String get id => 'scripted-test';

  @override
  String get defaultModel => 'scripted';

  @override
  bool get requiresCustomUrl => false;

  @override
  bool get supportsAudioInput => false;

  @override
  bool get prefersAudioDirect => false;

  @override
  bool get supportsTts => false;

  @override
  Future<String> complete({
    required String prompt,
    bool jsonMode = false,
    Duration timeout = const Duration(seconds: 20),
    int maxTokens = 4000,
  }) async {
    if (_i >= _replies.length) {
      return jsonEncode({
        'thought': 'declare done',
        'action': 'done',
        'args': {'notes': 'scripted E2E complete'},
      });
    }
    return _replies[_i++];
  }

  @override
  Future<String> completeChat({
    required List<LlmChatMessage> messages,
    bool jsonMode = false,
    Duration timeout = const Duration(seconds: 20),
    int maxTokens = 4000,
  }) => complete(
    prompt: '',
    jsonMode: jsonMode,
    timeout: timeout,
    maxTokens: maxTokens,
  );

  @override
  Future<String> completeWithAudio({
    required String prompt,
    required File audio,
    bool jsonMode = false,
    Duration timeout = const Duration(seconds: 20),
  }) => throw UnsupportedError('scripted-test has no audio');

  @override
  Future<String> transcribe(
    File audio, {
    Duration timeout = const Duration(seconds: 15),
  }) => throw UnsupportedError('scripted-test has no transcribe');

  @override
  Future<List<int>> synthesizeSpeech({
    required String text,
    required String voice,
    Duration timeout = const Duration(seconds: 20),
  }) => throw UnsupportedError('scripted-test has no TTS');
}

BroCodeWorkspace _loadBrokenWorkspace() {
  final fixtures = loadBroCodeFixtures();
  final broken = fixtures.where((f) => f.fileName.contains('dev_loop_broken'));
  if (broken.isNotEmpty) {
    final f = broken.first;
    return BroCodeWorkspace(
      name: f.name,
      description: (f.schema['description'] as String?) ?? '',
      inputSchema: f.schema['inputSchema'] is Map
          ? Map<String, dynamic>.from(f.schema['inputSchema'] as Map)
          : const {},
      script: f.script,
      assets: f.assets,
    );
  }
  return BroCodeWorkspace(
    name: 'DevLoopBroken',
    description: 'E2E incomplete Bro Code',
    inputSchema: const {},
    script:
        'async function execute(params) {\n'
        '  return "broken"\n'
        '.\n'
        '}\n',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('MS-BROCODE-DEV-LOOP E2E improve pipeline', () {
    test('incomplete fixture is loadable and tagged as failing syntax', () {
      final fixtures = loadBroCodeFixtures()
          .where((f) => f.fileName.contains('dev_loop_broken'))
          .toList();
      if (fixtures.isEmpty) {
        // Captured bundles are gitignored; CI uses the inline broken workspace.
        final ws = _loadBrokenWorkspace();
        expect(ws.name, isNotEmpty);
        expect(ws.script, contains('.'));
        return;
      }
      expect(fixtures.first.expectSyntaxOk, isFalse);
      expect(fixtures.first.script, contains('.'));
      expect(fixtures.first.improveGoal, isNotNull);
    });

    test(
      'tools write_full improves incomplete Bro Code + records snapshots',
      () async {
        final workspace = _loadBrokenWorkspace();
        final snaps = BroCodeSnapshotStore();
        snaps.capture(workspace: workspace, action: 'baseline');

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final tools = container.read(
          Provider((ref) => BroCodeAgentTools(ref, workspace)),
        );

        const fixed =
            'async function execute(params) {\n'
            '  return "fixed";\n'
            '}\n';
        final obs = await tools.execute('write_full', {'content': fixed});
        expect(obs.ok, isTrue);
        expect(workspace.script, contains('return "fixed"'));
        expect(workspace.script, isNot(contains('return "broken"')));

        snaps.capture(
          workspace: workspace,
          action: 'write_full',
          summary: obs.summary,
          turn: 1,
        );
        expect(snaps.snapshots.length, 2);
        expect(snaps.head?.parentId, snaps.snapshots.first.id);
        expect(snaps.head?.script, contains('fixed'));
      },
    );

    test(
      'broken fixture fails gates; scripted agent improves to verified',
      () async {
        if (!_quickJsNativeLibAvailable()) {
          markTestSkipped('QuickJS native lib not built on this machine');
          return;
        }

        final workspace = _loadBrokenWorkspace();
        const goal = 'Fix the SyntaxError so execute returns a string.';

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final bus = container.read(telemetryBusProvider);
        await bus.initialize();
        await bus.openSandbox(reset: true);
        final bridge = container.read(jsBridgeServiceProvider);

        final before = bridge.validateScriptSyntax(workspace.script);
        expect(before.ok, isFalse, reason: 'fixture must start broken');

        final tools = container.read(
          Provider((ref) => BroCodeAgentTools(ref, workspace)),
        );
        final synObs = await tools.execute('validate_syntax', {});
        expect(synObs.ok, isFalse);

        const fixed =
            'async function execute(params) {\n'
            '  return "fixed";\n'
            '}\n';
        final replies = [
          jsonEncode({
            'thought': 'overwrite broken script with valid execute',
            'action': 'write_full',
            'args': {'content': fixed},
          }),
          jsonEncode({
            'thought': 'gates should be green',
            'action': 'done',
            'args': {'notes': 'E2E scripted fix'},
          }),
        ];

        final snaps = BroCodeSnapshotStore();
        final agent = container.read(broCodeCodingAgentProvider);
        final result = await agent.improve(
          workspace: workspace,
          changeRequest: goal,
          providerOverride: ScriptedLlmProvider(replies),
          snapshotStore: snaps,
          persistSnapshotsToVault: false,
        );

        expect(result.verified, isTrue, reason: result.message);
        expect(workspace.script, contains('return "fixed"'));
        expect(
          snaps.snapshots.length,
          greaterThanOrEqualTo(2),
          reason: 'baseline + post-edit snapshot',
        );
        expect(snaps.snapshots.any((s) => s.action == 'write_full'), isTrue);

        final after = bridge.validateScriptSyntax(workspace.script);
        expect(after.ok, isTrue);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
