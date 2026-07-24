import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/js_bridge_service.dart';
import '../services/llm_service.dart';

/// Result of the internal Coder Agent (full Bro Code rewrite, not surgical patches).
class CoderAgentResult {
  final AuthoredAgentDraft draft;
  final bool usedFullRewrite;

  const CoderAgentResult({required this.draft, this.usedFullRewrite = true});
}

/// Internal AI Agent that authors or rewrites Bro Code as a complete script.
class CoderAgent {
  final Ref _ref;

  CoderAgent(this._ref);

  Future<CoderAgentResult> rewrite({
    required String broCodeName,
    required String currentScript,
    required String changeRequest,
    String? currentDescription,
    Map<String, dynamic>? currentInputSchema,
    String? lastRunError,
    List<String> dueDiligenceFindings = const [],
    void Function(String message)? onProgress,
  }) async {
    onProgress?.call('Coder Agent: requesting full Bro Code rewrite…');
    final llm = _ref.read(llmServiceProvider);
    final draft = await llm.rewriteBroCodeScript(
      broCodeName: broCodeName,
      currentScript: currentScript,
      changeRequest: changeRequest,
      currentDescription: currentDescription,
      currentInputSchema: currentInputSchema,
      lastRunError: lastRunError,
      dueDiligenceFindings: dueDiligenceFindings,
      onProgress: onProgress,
    );
    return CoderAgentResult(draft: draft, usedFullRewrite: true);
  }

  Future<AuthoredAgentDraft> author(String userRequest) {
    return _ref.read(llmServiceProvider).authorAgent(userRequest);
  }
}

final coderAgentProvider = Provider<CoderAgent>((ref) => CoderAgent(ref));

/// Outcome of the Tester Agent sandbox run.
class TesterAgentResult {
  final bool passed;
  final String message;
  final AgentExecutionResult? execution;

  const TesterAgentResult({
    required this.passed,
    required this.message,
    this.execution,
  });
}

/// Internal AI Agent that exercises Bro Code in the mock vault (no C2 needed).
class TesterAgent {
  final Ref _ref;

  TesterAgent(this._ref);

  Future<TesterAgentResult> runSandboxTest({
    required String broCodeName,
    required String script,
    Map<String, dynamic> parameters = const {},
    Map<String, String> assets = const {},
    void Function(String step)? onStepLog,
  }) async {
    final bridge = _ref.read(jsBridgeServiceProvider);
    final syntax = bridge.validateScriptSyntax(script);
    if (!syntax.ok) {
      return TesterAgentResult(
        passed: false,
        message: 'Syntax check failed: ${syntax.message}',
      );
    }

    final result = await bridge.executeAgentScript(
      agentName: broCodeName,
      script: script,
      parameters: parameters,
      onStepLog: onStepLog,
      sandboxMode: true,
      assets: assets,
    );

    return TesterAgentResult(
      passed: !result.isError,
      message: result.message,
      execution: result,
    );
  }

  /// Builds trivial params from an inputSchema map for smoke tests.
  static Map<String, dynamic> smokeParamsFromSchema(
    Map<String, dynamic>? inputSchema,
  ) {
    if (inputSchema == null || inputSchema.isEmpty) return {};
    final out = <String, dynamic>{};
    inputSchema.forEach((key, value) {
      if (value is! Map) {
        out[key] = '';
        return;
      }
      final type = (value['type'] as String?)?.toLowerCase() ?? 'string';
      out[key] = switch (type) {
        'number' => 1,
        'boolean' => true,
        _ => 'test',
      };
    });
    return out;
  }
}

final testerAgentProvider = Provider<TesterAgent>((ref) => TesterAgent(ref));

/// Orchestrates Coder → Tester → (caller deploys to vault).
class BroCodePipeline {
  final Ref _ref;

  BroCodePipeline(this._ref);

  Future<({AuthoredAgentDraft draft, TesterAgentResult test})> refineAndTest({
    required String broCodeName,
    required String currentScript,
    required String changeRequest,
    String? currentDescription,
    Map<String, dynamic>? currentInputSchema,
    String? lastRunError,
    List<String> dueDiligenceFindings = const [],
    void Function(String message)? onProgress,
  }) async {
    final coder = _ref.read(coderAgentProvider);
    final tester = _ref.read(testerAgentProvider);

    final coded = await coder.rewrite(
      broCodeName: broCodeName,
      currentScript: currentScript,
      changeRequest: changeRequest,
      currentDescription: currentDescription,
      currentInputSchema: currentInputSchema,
      lastRunError: lastRunError,
      dueDiligenceFindings: dueDiligenceFindings,
      onProgress: onProgress,
    );

    onProgress?.call('Tester Agent: sandbox smoke test…');
    final params = TesterAgent.smokeParamsFromSchema(coded.draft.inputSchema);
    final test = await tester.runSandboxTest(
      broCodeName: broCodeName,
      script: coded.draft.script,
      parameters: params,
      onStepLog: (s) => onProgress?.call(s),
    );

    onProgress?.call(
      test.passed
          ? 'Tester Agent: PASSED in sandbox'
          : 'Tester Agent: FAILED — ${test.message}',
    );

    return (draft: coded.draft, test: test);
  }
}

final broCodePipelineProvider = Provider<BroCodePipeline>(
  (ref) => BroCodePipeline(ref),
);
