import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/agent_bridge_spec.dart';
import '../services/byok_service.dart';
import '../services/llm/llm_provider.dart';
import '../services/llm/llm_provider_factory.dart';
import '../services/llm_service.dart';
import 'bro_code_agent_tools.dart';
import 'bro_code_workspace.dart';
import 'context_estimate.dart';

/// Outcome of a coding-agent IMPROVE session.
class BroCodeAgentResult {
  final bool verified;
  final AuthoredAgentDraft? draft;
  final String message;
  final int turnsUsed;
  final int estimatedTokensUsed;
  final int contextBudgetTokens;

  const BroCodeAgentResult({
    required this.verified,
    required this.message,
    this.draft,
    this.turnsUsed = 0,
    this.estimatedTokensUsed = 0,
    this.contextBudgetTokens = kDefaultContextBudgetTokens,
  });
}

/// Tool-loop coding agent for one Bro Code workspace (Cline-like, bounded arena).
class BroCodeCodingAgent {
  final Ref _ref;

  static const int maxTurns = 12;
  static const Duration wallClockLimit = Duration(seconds: 120);
  static const Duration heartbeatInterval = Duration(seconds: 6);

  BroCodeCodingAgent(this._ref);

  Future<BroCodeAgentResult> improve({
    required BroCodeWorkspace workspace,
    required String changeRequest,
    String? lastRunError,
    List<String> dueDiligenceFindings = const [],
    void Function(String message)? onProgress,
    void Function(int usedTokens, int budgetTokens)? onContextUpdate,
    String? priorFailureContext,
  }) async {
    final byok = _ref.read(byokServiceProvider);
    if (!byok.hasApiKey) {
      throw Exception('Configure your API Key in Settings to run the coding agent.');
    }

    void progress(String msg) => onProgress?.call(msg);

    final tools = BroCodeAgentTools(_ref, workspace);
    final budget = kDefaultContextBudgetTokens;
    final started = DateTime.now();
    var turns = 0;
    var estimatedTokens = 0;

    progress('Coding agent started for ${workspace.name}');
    progress(
      'Goal: ${changeRequest.length > 120 ? '${changeRequest.substring(0, 120)}…' : changeRequest}',
    );
    progress(
      'Budgets: ≤$maxTurns turns, ≤${BroCodeAgentTools.maxSandboxRuns} sandbox runs, '
      '${wallClockLimit.inSeconds}s wall, ~${_fmtK(budget)} token context',
    );

    final system = _systemPrompt();
    final userGoal = _userGoal(
      workspace: workspace,
      changeRequest: changeRequest,
      lastRunError: lastRunError,
      dueDiligenceFindings: dueDiligenceFindings,
      priorFailureContext: priorFailureContext,
    );

    estimatedTokens += estimateTokensFromParts([system, userGoal]);
    onContextUpdate?.call(estimatedTokens, budget);

    final messages = <LlmChatMessage>[
      LlmChatMessage(role: 'user', content: '$system\n\n$userGoal'),
    ];

    final provider =
        LlmProviderFactory.forConfig(_ref.read(byokServiceProvider));

    // Initial host checks — keep user engaged immediately.
    progress('Step: validate_syntax (baseline)…');
    var obs = await tools.execute('validate_syntax', {});
    progress(_shortObs(obs));
    _appendObs(messages, obs);
    estimatedTokens += estimateTokensFromString(obs.toAgentMessage());
    onContextUpdate?.call(estimatedTokens, budget);

    while (turns < maxTurns) {
      if (DateTime.now().difference(started) > wallClockLimit) {
        progress('Stopped: wall-clock budget (${wallClockLimit.inSeconds}s)');
        return BroCodeAgentResult(
          verified: false,
          message:
              'Timed out after ${wallClockLimit.inSeconds}s. Tap Retry — the agent continues with failure context.',
          turnsUsed: turns,
          estimatedTokensUsed: estimatedTokens,
          contextBudgetTokens: budget,
        );
      }
      if (estimatedTokens > (budget * 0.92).floor()) {
        progress('Stopped: estimated context near budget (~${_fmtK(estimatedTokens)})');
        return BroCodeAgentResult(
          verified: false,
          message:
              'Context budget nearly full. Tap Retry with a narrower change, or APPLY nothing yet.',
          turnsUsed: turns,
          estimatedTokensUsed: estimatedTokens,
          contextBudgetTokens: budget,
        );
      }

      turns++;
      progress('── Turn $turns/$maxTurns: asking model…');
      final heartbeat = Timer.periodic(heartbeatInterval, (t) {
        final secs = DateTime.now().difference(started).inSeconds;
        progress(
          'Still waiting on model (turn $turns, ${secs}s elapsed, '
          'est. context ${_fmtK(estimatedTokens)}/${_fmtK(budget)})…',
        );
      });

      String raw;
      try {
        raw = await provider.completeChat(
          messages: messages,
          jsonMode: true,
          timeout: const Duration(seconds: 55),
          maxTokens: 4096,
        );
      } on TimeoutException {
        heartbeat.cancel();
        progress('Model timed out on turn $turns');
        messages.add(const LlmChatMessage(
          role: 'user',
          content:
              'Observation: previous model call timed out. Reply with one JSON action only.',
        ));
        continue;
      } catch (e) {
        heartbeat.cancel();
        progress('Model error: $e');
        return BroCodeAgentResult(
          verified: false,
          message: 'Model call failed: $e',
          turnsUsed: turns,
          estimatedTokensUsed: estimatedTokens,
          contextBudgetTokens: budget,
        );
      } finally {
        heartbeat.cancel();
      }

      estimatedTokens += estimateTokensFromString(raw);
      onContextUpdate?.call(estimatedTokens, budget);
      progress('Model replied (${raw.length} chars)');
      messages.add(LlmChatMessage(role: 'model', content: raw));

      Map<String, dynamic> decoded;
      try {
        decoded = _parseActionJson(raw);
      } on FormatException catch (e) {
        progress('Could not parse action JSON: ${e.message}');
        final repair = LlmChatMessage(
          role: 'user',
          content:
              'Invalid JSON (${e.message}). Return ONLY one JSON object: '
              '{"thought":"...","action":"validate_syntax|apply_edit|write_full|sandbox_run|read_script|scan_policy|done","args":{}}',
        );
        messages.add(repair);
        estimatedTokens += estimateTokensFromString(repair.content);
        onContextUpdate?.call(estimatedTokens, budget);
        continue;
      }

      final thought = (decoded['thought'] as String?)?.trim();
      if (thought != null && thought.isNotEmpty) {
        progress('Thought: ${thought.length > 160 ? '${thought.substring(0, 160)}…' : thought}');
      }

      final action = (decoded['action'] as String?)?.trim().toLowerCase() ?? '';
      final args = decoded['args'] is Map
          ? Map<String, dynamic>.from(decoded['args'] as Map)
          : <String, dynamic>{};
      args.putIfAbsent('changeRequest', () => changeRequest);

      if (action == 'done') {
        progress('Model requested done — checking host gates…');
        if (!tools.canDeclareDone) {
          progress(
            'Rejected done: need validate_syntax + sandbox_run OK after last edit '
            '(syntax=${tools.syntaxOkAfterLastMutate}, sandbox=${tools.sandboxOkAfterLastMutate})',
          );
          obs = ToolObservation(
            ok: false,
            tool: 'done',
            summary: 'Host rejected done — gates not green',
            nextHint:
                'Call validate_syntax and sandbox_run successfully after your last edit, then done.',
          );
          _appendObs(messages, obs);
          estimatedTokens += estimateTokensFromString(obs.toAgentMessage());
          onContextUpdate?.call(estimatedTokens, budget);
          continue;
        }

        final notes = (args['notes'] as String?)?.trim() ??
            thought ??
            'Coding agent verified in sandbox.';
        progress('Verified: syntax + sandbox green — draft ready for APPLY');
        final changedAssets = <String, String>{};
        // Only emit assets that still exist (workspace is source of truth);
        // registry merge treats these as updates when non-empty.
        workspace.assets.forEach((k, v) {
          changedAssets[k] = v;
        });
        return BroCodeAgentResult(
          verified: true,
          message: notes,
          draft: AuthoredAgentDraft(
            name: workspace.name,
            description: workspace.description,
            inputSchema: workspace.inputSchema,
            script: workspace.script,
            notes: notes,
            assetUpdates: changedAssets,
          ),
          turnsUsed: turns,
          estimatedTokensUsed: estimatedTokens,
          contextBudgetTokens: budget,
        );
      }

      if (action.isEmpty) {
        progress('Empty action — prompting model again');
        messages.add(const LlmChatMessage(
          role: 'user',
          content: 'Missing action. Return a JSON action object.',
        ));
        continue;
      }

      progress('Tool → $action…');
      obs = await tools.execute(action, args);
      progress(_shortObs(obs));
      if (obs.detail.isNotEmpty && !obs.ok) {
        final snippet = obs.detail.length > 220
            ? '${obs.detail.substring(0, 220)}…'
            : obs.detail;
        progress('  detail: $snippet');
      }
      _appendObs(messages, obs);
      estimatedTokens += estimateTokensFromString(obs.toAgentMessage());
      onContextUpdate?.call(estimatedTokens, budget);
      _compactMessages(messages);
    }

    progress('Stopped: turn budget ($maxTurns)');
    return BroCodeAgentResult(
      verified: false,
      message:
          'Agent used $maxTurns turns without a verified result. Tap Retry to continue.',
      turnsUsed: turns,
      estimatedTokensUsed: estimatedTokens,
      contextBudgetTokens: budget,
      draft: AuthoredAgentDraft(
        name: workspace.name,
        description: workspace.description,
        inputSchema: workspace.inputSchema,
        script: workspace.script,
        notes: 'Unverified working copy after $maxTurns turns.',
        assetUpdates: Map<String, String>.from(workspace.assets),
      ),
    );
  }

  void _appendObs(List<LlmChatMessage> messages, ToolObservation obs) {
    messages.add(LlmChatMessage(role: 'user', content: obs.toAgentMessage()));
  }

  /// Drop old middle turns; keep first user goal + last few exchanges.
  void _compactMessages(List<LlmChatMessage> messages) {
    const keepTail = 10;
    if (messages.length <= keepTail + 1) return;
    final head = messages.first;
    final tail = messages.sublist(messages.length - keepTail);
    messages
      ..clear()
      ..add(head)
      ..add(const LlmChatMessage(
        role: 'user',
        content:
            'Observation: earlier turns compacted to save context. Continue from the recent observations.',
      ))
      ..addAll(tail);
  }

  static String _shortObs(ToolObservation obs) =>
      '${obs.ok ? '✓' : '✗'} ${obs.tool}: ${obs.summary}';

  static String _fmtK(int tokens) {
    if (tokens >= 1000) {
      return '${(tokens / 1000).toStringAsFixed(tokens >= 10000 ? 0 : 1)}K';
    }
    return '$tokens';
  }

  static String _systemPrompt() => '''
You are the Bro Code Coding Agent for Project Aur Bhai (on-device).
You improve ONE Javascript Bro Code unit using tools. Respond in English.
Each turn return ONLY raw JSON (no markdown):
{"thought":"brief plan","action":"<name>","args":{}}

Actions:
- read_script: args optional {line} or {startLine,endLine}
- read_asset: {id}
- apply_edit: {old,new} or {oldStringBase64,newStringBase64}; optional {asset,replaceAll}
- write_full: {scriptBase64} or {content} — prefer apply_edit; limited uses
- validate_syntax: {}
- sandbox_run: {} — runs in in-memory vault (never sovereign data)
- scan_policy: {} — static due diligence (does not execute)
- done: {notes} — ONLY after validate_syntax AND sandbox_run both OK after your last edit

${AgentBridgeSpec.bridgeSpecForLlm}

Rules:
- Prefer small apply_edit changes; do not thrash write_full.
- After every mutate, validate_syntax then sandbox_run before done.
- The host WILL reject done if gates are not green.
- One action per turn.
''';

  static String _userGoal({
    required BroCodeWorkspace workspace,
    required String changeRequest,
    String? lastRunError,
    List<String> dueDiligenceFindings = const [],
    String? priorFailureContext,
  }) {
    final buf = StringBuffer();
    buf.writeln('Bro Code: ${workspace.name}');
    buf.writeln('Description: ${workspace.description}');
    buf.writeln('inputSchema: ${jsonEncode(workspace.inputSchema)}');
    buf.writeln('Script length: ${workspace.scriptCharCount} chars');
    if (workspace.assets.isNotEmpty) {
      buf.writeln('Assets: ${workspace.assets.keys.join(', ')}');
    }
    buf.writeln();
    buf.writeln('USER CHANGE REQUEST:');
    buf.writeln(changeRequest);
    if (lastRunError != null && lastRunError.trim().isNotEmpty) {
      buf.writeln();
      buf.writeln('LAST RUN ERROR:');
      buf.writeln(lastRunError);
    }
    if (dueDiligenceFindings.isNotEmpty) {
      buf.writeln();
      buf.writeln('DUE DILIGENCE FINDINGS:');
      for (final f in dueDiligenceFindings) {
        buf.writeln('• $f');
      }
    }
    if (priorFailureContext != null && priorFailureContext.trim().isNotEmpty) {
      buf.writeln();
      buf.writeln('PRIOR ATTEMPT FAILURE:');
      buf.writeln(priorFailureContext);
    }
    buf.writeln();
    buf.writeln('Start by reading what you need, then edit, validate_syntax, sandbox_run, done.');
    return buf.toString();
  }

  static Map<String, dynamic> _parseActionJson(String raw) {
    var clean = raw.trim();
    if (clean.startsWith('```')) {
      clean = clean.replaceFirst(RegExp(r'^```(?:json)?'), '');
      if (clean.endsWith('```')) {
        clean = clean.substring(0, clean.length - 3);
      }
      clean = clean.trim();
    }
    final decoded = jsonDecode(clean);
    if (decoded is! Map) {
      throw const FormatException('Action JSON must be an object');
    }
    return Map<String, dynamic>.from(decoded);
  }
}

final broCodeCodingAgentProvider =
    Provider<BroCodeCodingAgent>((ref) => BroCodeCodingAgent(ref));
