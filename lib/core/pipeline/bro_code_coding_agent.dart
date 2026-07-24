import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/agent_bridge_spec.dart';
import '../services/byok_service.dart';
import '../services/llm/llm_provider.dart';
import '../services/llm/llm_provider_factory.dart';
import '../services/llm/llm_slot.dart';
import '../services/llm_service.dart';
import '../services/telemetry_bus.dart';
import 'bro_code_agent_tools.dart';
import 'bro_code_capability_judge.dart';
import 'bro_code_platform_integrity.dart';
import 'bro_code_workspace.dart';
import 'bro_code_workspace_snapshot.dart';
import 'context_estimate.dart';

/// Outcome of a coding-agent IMPROVE session.
class BroCodeAgentResult {
  final bool verified;
  final AuthoredAgentDraft? draft;
  final String message;
  final int turnsUsed;
  final int estimatedTokensUsed;
  final int contextBudgetTokens;
  final ToolObservation? baselineSyntax;
  final ToolObservation? lastSyntaxError;
  final ToolObservation? lastSandboxError;
  final ToolObservation? lastFormatError;
  final ToolObservation? lastStyleError;
  final ToolObservation? lastPolicyError;
  final ToolObservation? lastGoalError;
  final List<ToolObservation> failingObservations;

  const BroCodeAgentResult({
    required this.verified,
    required this.message,
    this.draft,
    this.turnsUsed = 0,
    this.estimatedTokensUsed = 0,
    this.contextBudgetTokens = kDefaultContextBudgetTokens,
    this.baselineSyntax,
    this.lastSyntaxError,
    this.lastSandboxError,
    this.lastFormatError,
    this.lastStyleError,
    this.lastPolicyError,
    this.lastGoalError,
    this.failingObservations = const [],
  });
}

/// Tool-loop coding agent for one Bro Code workspace (Cline-like, bounded arena).
class BroCodeCodingAgent {
  final Ref _ref;

  static const int maxTurns = 12;
  static const int maxIdenticalFailures = 3;
  static const int maxEmptyWriteFullRecoveries = 2;
  static const Duration wallClockLimit = Duration(seconds: 120);
  static const Duration heartbeatInterval = Duration(seconds: 6);
  static const int readTurnMaxTokens = 4096;
  static const int mutationTurnMaxTokens = 8192;

  BroCodeCodingAgent(this._ref);

  Future<BroCodeAgentResult> improve({
    required BroCodeWorkspace workspace,
    required String changeRequest,
    String? lastRunError,
    List<String> dueDiligenceFindings = const [],
    void Function(String message)? onProgress,
    void Function(int usedTokens, int budgetTokens)? onContextUpdate,
    String? priorFailureContext,

    /// Test / scripted IMPROVE: skip live BYOK when set.
    LlmProvider? providerOverride,

    /// Optional in-memory snapshot log (Git-lite). Created if null.
    BroCodeSnapshotStore? snapshotStore,
    bool persistSnapshotsToVault = true,
  }) async {
    final byok = _ref.read(byokServiceProvider);
    if (providerOverride == null && !byok.hasKeyForSlot(LlmSlot.improve)) {
      throw Exception(
        'Configure your API Key (improve slot or default) in Settings to run the coding agent.',
      );
    }

    void progress(String msg) => onProgress?.call(msg);

    final tools = BroCodeAgentTools(_ref, workspace);
    tools.lastChangeRequest = changeRequest;
    // MS-BROCODE-PLATFORM-ENG4 — LLM judge on judge slot when BYOK present.
    if (byok.hasKeyForSlot(LlmSlot.capabilityJudge)) {
      final judgeProvider = LlmProviderFactory.forConfig(
        byok,
        slot: LlmSlot.capabilityJudge,
      );
      progress(
        'Capability judge slot=${LlmSlot.capabilityJudge.id} '
        'provider=${judgeProvider.id}',
      );
      tools.capabilityJudge = LlmBroCodeCapabilityJudge(
        complete: (prompt) => judgeProvider.complete(prompt: prompt),
      );
    }
    final snaps = snapshotStore ?? BroCodeSnapshotStore();
    snaps.capture(
      workspace: workspace,
      action: 'baseline',
      summary: 'IMPROVE start',
      turn: 0,
    );
    final budget = kDefaultContextBudgetTokens;
    final started = DateTime.now();
    var turns = 0;
    var estimatedTokens = 0;
    var consecutiveReads = 0;
    var consecutiveEmptyWriteFull = 0;
    var preferApplyEditOnly = false;
    var nestedTemplateHintCount = 0;
    var preferAssetExtraction = false;
    ToolObservation? baselineSyntax;
    ToolObservation? lastSyntaxError;
    ToolObservation? lastSandboxError;
    ToolObservation? lastFormatError;
    ToolObservation? lastStyleError;
    ToolObservation? lastPolicyError;
    ToolObservation? lastGoalError;
    final failingObservations = <ToolObservation>[];
    String? lastFailureFingerprint;
    var identicalFailureCount = 0;

    AuthoredAgentDraft workingDraft({
      String notes = 'Unverified working copy.',
    }) => AuthoredAgentDraft(
      name: workspace.name,
      description: workspace.description,
      inputSchema: workspace.inputSchema,
      script: workspace.script,
      notes: notes,
      assetUpdates: Map<String, String>.from(workspace.assets),
    );

    /// Gates that failed after the latest verify (for near-green guidance).
    List<String> redGates() {
      final red = <String>[];
      if (!tools.formatOkAfterLastMutate) red.add('format');
      if (!tools.syntaxOkAfterLastMutate) red.add('syntax');
      if (!tools.styleOkAfterLastMutate) red.add('style');
      if (!tools.policyOkAfterLastMutate) red.add('policy');
      if (!tools.integrityOkAfterLastMutate) red.add('platform integrity');
      if (!tools.sandboxOkAfterLastMutate) red.add('sandbox');
      if (!tools.goalOkAfterLastMutate) red.add('dashboard goals');
      return red;
    }

    String remainingFindingsMessage(String prefix) {
      final red = redGates();
      if (red.isEmpty) {
        return '$prefix Tap Retry to continue.';
      }
      final details = <String>[];
      for (final g in red) {
        switch (g) {
          case 'syntax':
            if (lastSyntaxError != null) {
              details.add('syntax: ${lastSyntaxError!.summary}');
            } else {
              details.add('syntax');
            }
          case 'policy':
            if (lastPolicyError != null) {
              details.add('policy: ${lastPolicyError!.summary}');
            } else {
              details.add('policy');
            }
          case 'style':
            if (lastStyleError != null) {
              details.add('style: ${lastStyleError!.summary}');
            } else {
              details.add('style');
            }
          case 'sandbox':
            if (lastSandboxError != null) {
              details.add('sandbox: ${lastSandboxError!.summary}');
            } else {
              details.add('sandbox');
            }
          case 'dashboard goals':
            if (lastGoalError != null) {
              details.add('goals: ${lastGoalError!.summary}');
            } else {
              details.add('dashboard goals');
            }
          case 'platform integrity':
            details.add(
              'integrity: ${tools.lastIntegrityResult?.findings.firstOrNull ?? "platform wiring"}',
            );
          default:
            details.add(g);
        }
      }
      final joined = details.take(3).join('; ');
      return '$prefix Remaining: $joined. Tap Retry to continue.';
    }

    void recordFailure(ToolObservation observation) {
      if (observation.ok) return;
      if (failingObservations.length < 30) {
        failingObservations.add(observation);
      }
      switch (observation.tool) {
        case 'validate_syntax':
          lastSyntaxError = observation;
        case 'sandbox_run':
          lastSandboxError = observation;
        case 'check_format':
          lastFormatError = observation;
        case 'check_style':
          lastStyleError = observation;
        case 'scan_policy':
          lastPolicyError = observation;
        case 'check_dashboard_goals':
          lastGoalError = observation;
        case 'check_platform_integrity':
          // findings live on tools.lastIntegrityResult
          break;
      }
    }

    BroCodeAgentResult finish({
      required bool verified,
      required String message,
      AuthoredAgentDraft? draft,
    }) {
      return BroCodeAgentResult(
        verified: verified,
        message: message,
        draft: draft,
        turnsUsed: turns,
        estimatedTokensUsed: estimatedTokens,
        contextBudgetTokens: budget,
        baselineSyntax: baselineSyntax,
        lastSyntaxError: lastSyntaxError,
        lastSandboxError: lastSandboxError,
        lastFormatError: lastFormatError,
        lastStyleError: lastStyleError,
        lastPolicyError: lastPolicyError,
        lastGoalError: lastGoalError,
        failingObservations: List.unmodifiable(failingObservations),
      );
    }

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
        providerOverride ??
        LlmProviderFactory.forConfig(
          _ref.read(byokServiceProvider),
          slot: LlmSlot.improve,
        );
    progress('IMPROVE slot=${LlmSlot.improve.id} provider=${provider.id}');

    Future<void> persistSnapshots() async {
      if (!persistSnapshotsToVault) return;
      try {
        final bus = _ref.read(telemetryBusProvider);
        await bus.writeVaultData(
          BroCodeSnapshotStore.vaultIndexKey(workspace.name),
          jsonEncode(snaps.toJson()),
          mimeType: 'application/json',
        );
      } catch (_) {
        // Snapshot persistence is best-effort; never fail IMPROVE for it.
      }
    }

    Future<void> ingestObs(ToolObservation observation) async {
      recordFailure(observation);
      progress(_shortObs(observation));
      if (observation.detail.isNotEmpty && !observation.ok) {
        final snippet = observation.detail.length > 220
            ? '${observation.detail.substring(0, 220)}…'
            : observation.detail;
        progress('  detail: $snippet');
      }
      _appendObs(messages, observation);
      estimatedTokens += estimateTokensFromString(observation.toAgentMessage());
      onContextUpdate?.call(estimatedTokens, budget);

      if (!observation.ok) {
        // Empty recovered write_full payloads must not burn the stuck-loop budget;
        // the model needs room to retry with apply_edit / valid Base64.
        final skipIdentical = observation.data?['skipIdenticalFailure'] == true;
        if (!skipIdentical) {
          final fp = failureFingerprint(observation);
          if (fp == lastFailureFingerprint) {
            identicalFailureCount++;
          } else {
            lastFailureFingerprint = fp;
            identicalFailureCount = 1;
          }
        }
      }
    }

    Future<void> emitNearGreenHint() async {
      final red = redGates();
      if (red.isEmpty || red.length > 2) return;
      // Integrity wiring failures are host-repairable — do not force apply_edit thrash.
      if (red.contains('platform integrity')) return;
      final thrashOnly =
          tools.syntaxOkAfterLastMutate &&
          red.every(
            (g) => g == 'policy' || g == 'style' || g == 'dashboard goals',
          );
      if (!thrashOnly && red.length > 1) return;
      preferApplyEditOnly = true;
      final obs = ToolObservation(
        ok: false,
        tool: 'host_near_green',
        summary: 'Near-green: only ${red.join(", ")} still failing',
        detail:
            'Do not write_full on the main script. Fix with apply_edit '
            '(prefer {"asset":"<id>"} when Assets are listed). '
            'Asset write_full is allowed after repeated apply_edit misses.',
        nextHint:
            'Return JSON apply_edit with a small unique old/new snippet for: '
            '${red.join(", ")}.',
        data: {
          'nearGreen': true,
          'redGates': red,
          'skipIdenticalFailure': true,
        },
      );
      await ingestObs(obs);
      progress('Near-green: forcing apply_edit for ${red.join(", ")}');
    }

    /// Host rewrite of execute() when orphan HTML / half-thin wiring is the issue.
    Future<bool> tryHostThinRepair({required String label}) async {
      final integrity = tools.checkPlatformIntegrity();
      await ingestObs(integrity);
      if (integrity.ok) return false;
      final result = tools.lastIntegrityResult;
      if (result == null || !BroCodePlatformIntegrity.canAutoRepair(result)) {
        return false;
      }
      // Auto-repair when integrity is red and syntax is already broken or
      // goals fail solely because publish path is wrong — avoid 12-turn thrash.
      final shouldRepair =
          result.halfThinScript ||
          result.orphanAssetIds.isNotEmpty ||
          !tools.syntaxOkAfterLastMutate;
      if (!shouldRepair) return false;

      progress(
        'Host auto-repair ($label): thin execute → '
        '${result.suggestedPublishAssetId}',
      );
      final repair = tools.applyThinPublishRepair(
        htmlAssetId: result.suggestedPublishAssetId,
      );
      await ingestObs(repair);
      if (!repair.ok) return false;

      preferApplyEditOnly = false;
      preferAssetExtraction = false;
      nestedTemplateHintCount = 0;

      // Re-verify after host rewrite (caller continues verify).
      return true;
    }

    Future<void> emitNestedTemplateHint(ToolObservation synObs) async {
      if (synObs.ok) return;
      if (!looksLikeNestedHtmlTemplateSyntaxFailure(
        script: workspace.script,
        syntaxObservation: synObs,
      )) {
        return;
      }
      nestedTemplateHintCount++;
      preferAssetExtraction = nestedTemplateHintCount >= 2;
      preferApplyEditOnly = false; // asset extraction needs write_full on asset
      String? existingHtml;
      for (final k in workspace.assets.keys) {
        if (k.toLowerCase().endsWith('.html')) {
          existingHtml = k;
          break;
        }
      }
      final safeName = workspace.name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '');
      final htmlId = existingHtml ?? '${safeName}Dashboard.html';
      final obs = ToolObservation(
        ok: false,
        tool: 'host_nested_template',
        summary:
            'Nested HTML template literal — extract to System.assets (hint $nestedTemplateHintCount)',
        detail:
            'QuickJS cannot parse browser JS nested inside an execute() HTML '
            'template (inner backticks / \${…}). Do not keep patching the monolith. '
            'Move the HTML into an asset and leave a thin execute that '
            'System.writeVault(key, System.assets["$htmlId"], "text/html").',
        nextHint: preferAssetExtraction
            ? 'REQUIRED: write_full with {"asset":"$htmlId","content":"<full HTML>"} '
                  'then thin execute via apply_edit/write_full on the script only. '
                  'Monolith apply_edit is rejected until assets hold the HTML.'
            : 'Prefer write_full {"asset":"$htmlId","content":"…"} (or scriptBase64) '
                  'for the dashboard HTML; thin execute with System.assets.',
        data: {
          'nestedHtmlTemplate': true,
          'preferAssetExtraction': preferAssetExtraction,
          'suggestedAssetId': htmlId,
          'skipIdenticalFailure': true,
        },
      );
      await ingestObs(obs);
      progress(
        preferAssetExtraction
            ? 'Forcing asset extraction (nested HTML template)'
            : 'Hint: extract nested HTML template to System.assets',
      );
    }

    Future<void> runHostVerify({
      required String label,
      bool runSandbox = false,
      Map<String, dynamic> sandboxArgs = const {},
      bool captureBaselineSyntax = false,
    }) async {
      progress('Host verify ($label): format…');
      await ingestObs(tools.ensureFormat());

      progress('Host verify ($label): syntax…');
      final synObs = await tools.execute('validate_syntax', {});
      if (captureBaselineSyntax && !synObs.ok) {
        baselineSyntax = synObs;
      }
      await ingestObs(synObs);
      if (!synObs.ok) {
        await emitNestedTemplateHint(synObs);
      } else if (nestedTemplateHintCount > 0) {
        nestedTemplateHintCount = 0;
        preferAssetExtraction = false;
      }

      progress('Host verify ($label): style…');
      await ingestObs(await tools.execute('check_style', {}));

      progress('Host verify ($label): policy…');
      await ingestObs(await tools.execute('scan_policy', {}));

      progress('Host verify ($label): platform integrity…');
      var integrityObs = tools.checkPlatformIntegrity();
      await ingestObs(integrityObs);

      // Structural auto-repair for ANY Bro Code (orphan HTML / half-thin).
      if (!integrityObs.ok &&
          BroCodePlatformIntegrity.canAutoRepair(tools.lastIntegrityResult!)) {
        final repaired = await tryHostThinRepair(label: label);
        if (repaired) {
          progress('Host verify ($label): format… (post-repair)');
          await ingestObs(tools.ensureFormat());
          progress('Host verify ($label): syntax… (post-repair)');
          final syn2 = await tools.execute('validate_syntax', {});
          await ingestObs(syn2);
          progress('Host verify ($label): style… (post-repair)');
          await ingestObs(await tools.execute('check_style', {}));
          progress('Host verify ($label): policy… (post-repair)');
          await ingestObs(await tools.execute('scan_policy', {}));
          integrityObs = tools.checkPlatformIntegrity();
          await ingestObs(integrityObs);
        }
      }

      if (runSandbox && tools.syntaxOkAfterLastMutate) {
        progress('Host verify ($label): sandbox…');
        await ingestObs(await tools.execute('sandbox_run', sandboxArgs));
      }

      progress('Host verify ($label): dashboard goals…');
      await ingestObs(
        tools.checkDashboardGoals(
          sandboxArgs['changeRequest'] as String? ?? changeRequest,
        ),
      );

      if (!tools.canDeclareDone) {
        await emitNearGreenHint();
      } else {
        preferApplyEditOnly = false;
        preferAssetExtraction = false;
        nestedTemplateHintCount = 0;
      }
    }

    await runHostVerify(label: 'baseline', captureBaselineSyntax: true);

    while (turns < maxTurns) {
      if (identicalFailureCount >= maxIdenticalFailures) {
        progress(
          'Stopped: same failure repeated $identicalFailureCount times '
          '($lastFailureFingerprint)',
        );
        return finish(
          verified: false,
          message: remainingFindingsMessage(
            'Stuck on the same error $identicalFailureCount times.',
          ),
          draft: workingDraft(notes: 'Unverified — stuck on repeated failure.'),
        );
      }
      if (DateTime.now().difference(started) > wallClockLimit) {
        progress('Stopped: wall-clock budget (${wallClockLimit.inSeconds}s)');
        return finish(
          verified: false,
          message: remainingFindingsMessage(
            'Timed out after ${wallClockLimit.inSeconds}s.',
          ),
          draft: workingDraft(notes: 'Unverified — wall-clock limit.'),
        );
      }
      if (estimatedTokens > (budget * 0.92).floor()) {
        progress(
          'Stopped: estimated context near budget (~${_fmtK(estimatedTokens)})',
        );
        return finish(
          verified: false,
          message: remainingFindingsMessage('Context budget nearly full.'),
          draft: workingDraft(notes: 'Unverified — context budget.'),
        );
      }

      turns++;
      progress('── Turn $turns/$maxTurns: asking model…');
      final tokenCap = preferApplyEditOnly || consecutiveEmptyWriteFull > 0
          ? mutationTurnMaxTokens
          : 4096;
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
          maxTokens: tokenCap,
        );
      } on TimeoutException {
        heartbeat.cancel();
        progress('Model timed out on turn $turns');
        // Timeouts are not productive — refund the turn slot.
        turns--;
        messages.add(
          const LlmChatMessage(
            role: 'user',
            content:
                'Observation: previous model call timed out. Reply with one JSON action only.',
          ),
        );
        continue;
      } catch (e) {
        heartbeat.cancel();
        progress('Model error: $e');
        return finish(
          verified: false,
          message: 'Model call failed: $e',
          draft: workingDraft(notes: 'Unverified — model error.'),
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
        decoded = parseBroCodeActionJson(raw);
      } on FormatException catch (e) {
        progress('Could not parse action JSON: ${e.message}');
        final rawPreview = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
        progress(
          '  raw: ${rawPreview.length > 180 ? '${rawPreview.substring(0, 180)}…' : rawPreview}',
        );
        consecutiveEmptyWriteFull++;
        preferApplyEditOnly =
            consecutiveEmptyWriteFull >= maxEmptyWriteFullRecoveries;
        // Invalid JSON is not a productive turn — refund.
        turns--;
        final repair = LlmChatMessage(
          role: 'user',
          content: preferApplyEditOnly
              ? 'Invalid JSON (${e.message}). Return ONLY apply_edit JSON: '
                    '{"thought":"...","action":"apply_edit","args":{"old":"...","new":"..."}}'
              : 'Invalid JSON (${e.message}). Return ONLY one JSON object: '
                    '{"thought":"...","action":"apply_edit|write_full|read_script|done","args":{}}',
        );
        messages.add(repair);
        estimatedTokens += estimateTokensFromString(repair.content);
        onContextUpdate?.call(estimatedTokens, budget);
        continue;
      }

      final thought = (decoded['thought'] as String?)?.trim();
      if (thought != null && thought.isNotEmpty) {
        progress(
          'Thought: ${thought.length > 160 ? '${thought.substring(0, 160)}…' : thought}',
        );
      }

      final action = (decoded['action'] as String?)?.trim().toLowerCase() ?? '';
      final args = decoded['args'] is Map
          ? Map<String, dynamic>.from(decoded['args'] as Map)
          : <String, dynamic>{};
      args.putIfAbsent('changeRequest', () => changeRequest);

      final recoveredEmptyThought =
          thought == 'Recovered action from non-JSON model response.';
      final writeFullHasPayload =
          args['content'] != null ||
          args['script'] != null ||
          (args['scriptBase64'] as String?)?.trim().isNotEmpty == true ||
          (args['contentBase64'] as String?)?.trim().isNotEmpty == true;

      ToolObservation obs;

      if (preferAssetExtraction &&
          action == 'apply_edit' &&
          ((args['asset'] as String?)?.trim().isEmpty ?? true)) {
        progress('Rejected apply_edit on monolith — extract HTML to an asset');
        turns--;
        obs = ToolObservation(
          ok: false,
          tool: 'apply_edit',
          summary: 'Monolith apply_edit rejected — nested HTML template',
          detail:
              'Nested backticks / \${…} inside execute() HTML cannot be fixed '
              'reliably with script patches. Write the HTML to System.assets first.',
          nextHint:
              'Return write_full with {"asset":"<name>.html","content":"<full HTML>"} '
              'then thin execute that System.writeVault(..., System.assets[...], mime).',
          data: const {
            'skipIdenticalFailure': true,
            'refundTurn': true,
            'preferAssetExtraction': true,
          },
        );
        await ingestObs(obs);
        continue;
      }

      if (action == 'write_full' &&
          preferAssetExtraction &&
          (args['asset'] == null || (args['asset'] as String).trim().isEmpty) &&
          (args['content'] != null &&
              ((args['content'] as String).contains('<!DOCTYPE') ||
                  (args['content'] as String).length > 2000))) {
        progress(
          'Rejected write_full: prefer asset extraction requires thin script',
        );
        turns--;
        obs = ToolObservation(
          ok: false,
          tool: 'write_full',
          summary: 'write_full rejected — execute script must be thin',
          detail:
              'You are attempting to write a monolithic execute script with '
              'embedded HTML while preferAssetExtraction is active. '
              'The execute script must be thin.',
          nextHint:
              'Write the HTML to an asset first using write_full with "asset": "<name>.html". '
              'Then write a thin execute script that uses System.assets.',
          data: const {'skipIdenticalFailure': true, 'refundTurn': true},
        );
        await ingestObs(obs);
        continue;
      }

      final writeFullAssetTarget =
          (args['asset'] as String?)?.trim().isNotEmpty == true;
      if (action == 'write_full' &&
          !preferAssetExtraction &&
          // Asset-targeted write_full is allowed after repeated apply_edit misses.
          !(writeFullAssetTarget && tools.allowAssetWriteFullEscalation) &&
          // Never block host-needed thin script rewrite when integrity is red.
          !redGates().contains('platform integrity') &&
          (preferApplyEditOnly ||
              (tools.syntaxOkAfterLastMutate &&
                  !tools.canDeclareDone &&
                  redGates().every(
                    (g) =>
                        g == 'policy' || g == 'style' || g == 'dashboard goals',
                  )))) {
        progress('Rejected write_full: near-green — use apply_edit');
        turns--;
        obs = ToolObservation(
          ok: false,
          tool: 'write_full',
          summary: 'write_full rejected — near-green requires apply_edit',
          detail:
              'Syntax already OK; remaining gates: ${redGates().join(", ")}. '
              'A full rewrite risks nested-backtick breakage. Use apply_edit. '
              'After ${BroCodeAgentTools.maxApplyEditMissesBeforeWriteFull} '
              'apply_edit misses, write_full on a single asset is allowed.',
          nextHint:
              'Return {"action":"apply_edit","args":{"old":"…","new":"…"}} '
              '(optional "asset").',
          data: const {
            'skipIdenticalFailure': true,
            'refundTurn': true,
            'nearGreenReject': true,
          },
        );
        await ingestObs(obs);
        continue;
      }

      if (action == 'write_full' && !writeFullHasPayload) {
        consecutiveEmptyWriteFull++;
        preferApplyEditOnly =
            consecutiveEmptyWriteFull >= maxEmptyWriteFullRecoveries;
        progress(
          'Empty write_full${recoveredEmptyThought ? " (recovered)" : ""} — '
          'refunding turn ($consecutiveEmptyWriteFull/'
          '$maxEmptyWriteFullRecoveries)',
        );
        turns--;
        obs = ToolObservation(
          ok: false,
          tool: 'write_full',
          summary: 'Missing content / scriptBase64',
          detail:
              'write_full requires args.content, args.script, args.scriptBase64, '
              'or args.contentBase64. Empty/recovered calls with no payload are rejected.',
          nextHint: preferApplyEditOnly
              ? 'apply_edit ONLY: {"thought":"…","action":"apply_edit",'
                    '"args":{"old":"<unique snippet>","new":"<replacement>"}}. '
                    'Do not call write_full again without a payload.'
              : 'Return valid JSON write_full with scriptBase64, or prefer apply_edit. '
                    'Do not dump raw HTML/JS outside JSON.',
          data: const {
            'emptyWriteFull': true,
            'skipIdenticalFailure': true,
            'refundTurn': true,
          },
        );
        await ingestObs(obs);
        continue;
      }

      if (action == 'read_script' || action == 'read_asset') {
        consecutiveReads++;
        if (consecutiveReads > 2) {
          progress('Rejected $action: repeated reads without an edit');
          obs = ToolObservation(
            ok: false,
            tool: 'read_script',
            summary: 'Read budget exhausted before a mutation',
            detail:
                'The syntax observation already includes the failing line and excerpt.',
            nextHint: preferApplyEditOnly
                ? 'Act now: apply_edit only. Host re-verifies after edits.'
                : 'Act now: apply_edit or write_full. Host re-verifies after edits.',
          );
          await ingestObs(obs);
          continue;
        }
      } else {
        consecutiveReads = 0;
      }

      if (action == 'done') {
        progress('Model requested done — checking host gates…');
        if (!tools.canDeclareDone) {
          progress(
            'Rejected done: need syntax + sandbox + format + style + policy + '
            'integrity + dashboard goals OK after last edit '
            '(syntax=${tools.syntaxOkAfterLastMutate}, sandbox=${tools.sandboxOkAfterLastMutate}, '
            'format=${tools.formatOkAfterLastMutate}, style=${tools.styleOkAfterLastMutate}, '
            'policy=${tools.policyOkAfterLastMutate}, '
            'integrity=${tools.integrityOkAfterLastMutate}, '
            'goals=${tools.goalOkAfterLastMutate})',
          );
          obs = ToolObservation(
            ok: false,
            tool: 'done',
            summary: 'Host rejected done — gates not green',
            nextHint:
                'Fix syntax/style/policy/integrity/sandbox/goal findings. '
                'Host auto-repairs orphan HTML / half-thin execute when possible. '
                'Keep browser APIs inside HTML / System.assets only.',
          );
          await ingestObs(obs);
          continue;
        }

        final notes =
            (args['notes'] as String?)?.trim() ??
            thought ??
            'Coding agent verified in sandbox.';
        progress(
          'Verified: syntax + sandbox + format + style + policy + integrity + '
          'goals green — draft ready for APPLY',
        );
        final changedAssets = <String, String>{};
        workspace.assets.forEach((k, v) {
          changedAssets[k] = v;
        });
        await persistSnapshots();
        return finish(
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
        );
      }

      if (action.isEmpty) {
        progress('Empty action — prompting model again');
        turns--;
        messages.add(
          const LlmChatMessage(
            role: 'user',
            content: 'Missing action. Return a JSON action object.',
          ),
        );
        continue;
      }

      if (action == 'check_format' || action == 'apply_format') {
        progress('Tool → $action (host auto-format)…');
        obs = tools.ensureFormat();
      } else {
        progress('Tool → $action…');
        obs = await tools.execute(action, args);
      }
      await ingestObs(obs);

      if (action == 'write_full' && obs.ok) {
        final targetAsset = (args['asset'] as String?)?.trim();
        if (targetAsset != null &&
            targetAsset.isNotEmpty &&
            targetAsset.endsWith('.html') &&
            looksLikeNestedHtmlTemplateSyntaxFailure(
              script: tools.workspace.script,
              syntaxObservation:
                  lastSyntaxError ??
                  ToolObservation(
                    ok: false,
                    tool: 'validate_syntax',
                    summary: 'unknown',
                  ),
            )) {
          progress('Host auto-thin execute script after $targetAsset write');
          tools.workspace.script =
              BroCodePlatformIntegrity.buildThinPublishExecute(
                htmlAssetId: targetAsset,
                vaultKey: targetAsset,
                assets: tools.workspace.assets,
              );

          await ingestObs(
            ToolObservation(
              ok: true,
              tool: 'host_auto_thin_execute',
              summary: 'Auto-thinned execute script to use $targetAsset',
              detail: 'Execute script thinned by host (platform integrity).',
            ),
          );

          final postThinSyntax = await tools.execute('validate_syntax', {});
          await ingestObs(postThinSyntax);
          if (postThinSyntax.ok) {
            final postThinSandbox = await tools.execute('sandbox_run', {});
            await ingestObs(postThinSandbox);
          }
          snaps.capture(
            workspace: workspace,
            action: 'host_auto_thin_execute',
            summary: 'Auto-thinned execute after $targetAsset',
            turn: turns,
            gatesGreen: tools.canDeclareDone,
          );
          await persistSnapshots();
        }
      }

      // Empty write_full from tools path (defense in depth) — already handled above
      // when payload missing; if tool still returns empty marker, refund.
      if (!obs.ok && obs.data?['refundTurn'] == true) {
        turns--;
        consecutiveEmptyWriteFull++;
        preferApplyEditOnly =
            consecutiveEmptyWriteFull >= maxEmptyWriteFullRecoveries;
        continue;
      }

      if (obs.ok && (action == 'apply_edit' || action == 'write_full')) {
        lastFailureFingerprint = null;
        identicalFailureCount = 0;
        consecutiveEmptyWriteFull = 0;
        await runHostVerify(
          label: 'post-edit',
          runSandbox: true,
          sandboxArgs: args,
        );
        snaps.capture(
          workspace: workspace,
          action: action,
          summary: obs.summary,
          turn: turns,
          gatesGreen: tools.canDeclareDone,
        );
        await persistSnapshots();
      }

      _compactMessages(messages);
    }

    progress('Stopped: turn budget ($maxTurns)');
    return finish(
      verified: false,
      message: remainingFindingsMessage(
        'Agent used $maxTurns turns without a verified result.',
      ),
      draft: workingDraft(
        notes: 'Unverified working copy after $maxTurns turns.',
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
      ..add(
        const LlmChatMessage(
          role: 'user',
          content:
              'Observation: earlier turns compacted to save context. Continue from the recent observations.',
        ),
      )
      ..addAll(tail);
  }

  static String _shortObs(ToolObservation obs) =>
      '${obs.ok ? '✓' : '✗'} ${obs.tool}: ${obs.summary}';

  /// Fingerprint for stuck-loop detection (tool + summary + optional line).
  static String failureFingerprint(ToolObservation obs) {
    final line = obs.data?['line'];
    return '${obs.tool}|${obs.summary}|${line ?? ''}';
  }

  /// True when syntax failure is almost certainly nested backticks / `${…}`
  /// inside an HTML template literal in execute() (not a simple typo).
  static bool looksLikeNestedHtmlTemplateSyntaxFailure({
    required String script,
    required ToolObservation syntaxObservation,
  }) {
    if (syntaxObservation.ok || syntaxObservation.tool != 'validate_syntax') {
      return false;
    }
    final summary = syntaxObservation.summary.toLowerCase();
    final detail = syntaxObservation.detail;
    final lowerScript = script.toLowerCase();

    final hasHtmlTemplate =
        lowerScript.contains('<!doctype') ||
        (lowerScript.contains('const html') && lowerScript.contains('<html'));
    final hasBrowserApi =
        lowerScript.contains('document.') || lowerScript.contains('fetch(');
    if (!hasHtmlTemplate || !hasBrowserApi) return false;

    final nestedTokenHints =
        summary.contains('unexpected token') ||
        summary.contains("expecting ';'") ||
        summary.contains('expecting ";"') ||
        detail.contains(r'${') ||
        RegExp(r'const\s+\w+\s*=\s*`').hasMatch(detail) ||
        detail.contains('SELECT * FROM');
    return nestedTokenHints;
  }

  static String _fmtK(int tokens) {
    if (tokens >= 1000) {
      return '${(tokens / 1000).toStringAsFixed(tokens >= 10000 ? 0 : 1)}K';
    }
    return '$tokens';
  }

  static String _systemPrompt() =>
      '''
You are the Bro Code Coding Agent for Project Aur Bhai (on-device).
You improve ONE Javascript Bro Code unit using tools. Respond in English.
Each turn return ONLY raw JSON (no markdown):
{"thought":"brief plan","action":"<name>","args":{}}

Actions:
- read_script: args optional {line} or {startLine,endLine}
- read_asset: {id}
- apply_edit: {old,new} or {oldStringBase64,newStringBase64}; optional {asset,replaceAll}
- write_full: {scriptBase64} or {content}; optional {asset} — prefer apply_edit; limited uses
- validate_syntax: {} — optional; host re-checks after every edit
- sandbox_run: {} — optional; host runs sandbox after edits when syntax OK
- scan_policy: {} — optional; host runs due diligence after every edit
- check_format / apply_format: {} — host auto-normalizes whitespace (no LLM turn needed)
- check_style: {} — optional; host re-lints after every edit
- check_dashboard_goals: {} — optional; host checks HTML vs USER CHANGE REQUEST (map/PWA/DOM)
- done: {notes} — ONLY after host gates green: syntax + sandbox + format + style + policy + dashboard goals after last edit

${AgentBridgeSpec.bridgeSpecForLlm}

Rules:
- Prefer small apply_edit changes; do not thrash write_full.
- Prefer System.assets sidecars for dashboard HTML / manifest / service worker.
  Thin execute() should System.writeVault(key, System.assets["id"], mime).
  Do NOT nest multi-KB HTML inside execute() template strings when assets can hold it;
  nested backticks break QuickJS syntax and waste turns.
- PLATFORM (all Bro Codes): host checks orphan assets, half-thin execute (dead code
  after return / browser residue), and broken System.assets refs. Host may auto-rewrite
  a thin execute() publisher — do not fight that repair.
- Host dashboard goals check ONLY HTML that System.writeVault publishes (template
  variable or System.assets["id"] referenced by writeVault). Editing an unused
  sidecar does NOT pass — also wire execute() to publish that asset.
- When Assets are listed, edit those with apply_edit {"asset":"<id>",...} (HTML/PWA),
  and ensure writeVault still publishes that same asset id.
- When the change implies a dashboard/PWA and Assets are empty, extract HTML/manifest/SW
  into assets via write_full/apply_edit with {"asset":"<id>"} and leave a thin execute.
- write_full MUST include scriptBase64 or content in args. Never call write_full with empty args.
- A failed validate_syntax observation already includes the error excerpt. Edit
  that excerpt directly; do not repeatedly reread the script.
- At most two consecutive read actions are allowed before a mutation.
- After apply_edit or write_full, the host auto-formats, re-checks syntax/style/policy/
  platform integrity, runs sandbox when syntax is OK, then checks dashboard goals.
- If check_style, scan_policy, or check_dashboard_goals fails, apply_edit to clear findings;
  host re-checks. When near-green (one gate red), do NOT write_full on the main script
  (asset write_full allowed after repeated apply_edit misses).
- Keep browser APIs (document/fetch/window) inside HTML assets or templates only.
- When removing a chart/canvas, also remove JS that references the removed element ids.
- When asked for a map, use Leaflet + OpenStreetMap tiles (no Google API key) unless the
  user insists on Google Maps.
- When asked for a Progressive Web App / desktop-like mobile dashboard, include viewport,
  theme-color, web-app-capable meta, link rel=manifest, and service worker registration.
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
    final dashboardLikely = BroCodeAgentTools.changeImpliesDashboard(
      changeRequest,
    );
    if (workspace.assets.isNotEmpty) {
      buf.writeln('Assets: ${workspace.assets.keys.join(', ')}');
      buf.writeln(
        'When changing the dashboard/PWA, prefer apply_edit with '
        '{"asset":"<id>", "old":"…", "new":"…"}. Thin execute should publish via '
        'System.writeVault(key, System.assets["<id>"], mime). '
        'Do not rewrite the whole execute script for HTML-only changes.',
      );
    } else if (dashboardLikely) {
      buf.writeln(
        'No Assets listed yet. Prefer extracting dashboard HTML / manifest / service '
        'worker into System.assets (write_full or apply_edit with {"asset":"<id>.html"}) '
        'and a thin execute that publishes via System.writeVault. Avoid nesting multi-KB '
        'HTML inside execute() — nested backticks cause SyntaxError and policy thrash.',
      );
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
    buf.writeln(
      'Use the baseline host-verify observations first. '
      'Read only if an excerpt is insufficient, then apply_edit (preferred) or write_full. '
      'Host auto-formats and re-verifies (syntax, style, policy, sandbox, goals) after each edit; '
      'fix failures with apply_edit, then done when gates are green.',
    );
    return buf.toString();
  }
}

/// Parses one model tool action. Providers sometimes wrap otherwise-valid JSON
/// in prose or markdown despite JSON mode, so recover the first balanced object
/// instead of spending an entire coding-agent turn on a formatting mistake.
Map<String, dynamic> parseBroCodeActionJson(String raw) {
  var clean = raw.trim();
  if (clean.startsWith('```')) {
    clean = clean.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
    clean = clean.replaceFirst(RegExp(r'\s*```$'), '');
  }

  Object? decoded;
  try {
    decoded = jsonDecode(clean);
  } on FormatException {
    final candidate = _firstBalancedJsonObject(clean);
    if (candidate != null) {
      try {
        decoded = jsonDecode(candidate);
      } on FormatException {
        decoded = null;
      }
    }
    decoded ??= _fallbackActionFromText(clean);
    if (decoded == null) rethrow;
  }
  if (decoded is! Map) {
    throw const FormatException('Action JSON must be an object');
  }
  return Map<String, dynamic>.from(decoded);
}

Map<String, dynamic>? _fallbackActionFromText(String source) {
  final match = RegExp(
    r'\b(read_script|read_asset|apply_edit|write_full|validate_syntax|sandbox_run|scan_policy|check_format|apply_format|check_style|check_dashboard_goals|done)\b',
    caseSensitive: false,
  ).firstMatch(source);
  if (match == null) return null;

  final action = match.group(1)!.toLowerCase();
  final args = <String, dynamic>{};
  for (final key in ['line', 'lineNumber', 'startLine', 'endLine']) {
    final number = RegExp(
      '$key\\s*["\']?\\s*[:=]\\s*(\\d+)',
      caseSensitive: false,
    ).firstMatch(source);
    if (number != null) args[key] = int.parse(number.group(1)!);
  }
  final dashboard = RegExp(
    r'''expectDashboard\s*["']?\s*[:=]\s*(true|false)''',
    caseSensitive: false,
  ).firstMatch(source);
  if (dashboard != null) {
    args['expectDashboard'] = dashboard.group(1)!.toLowerCase() == 'true';
  }

  if (action == 'write_full') {
    final b64 = RegExp(
      r'''scriptBase64\s*["']?\s*[:=]\s*["']([A-Za-z0-9+/=\s]{32,})["']''',
      caseSensitive: false,
    ).firstMatch(source);
    if (b64 != null) {
      args['scriptBase64'] = b64.group(1)!.replaceAll(RegExp(r'\s+'), '');
    } else {
      final fence = RegExp(
        r'```(?:javascript|js)?\s*([\s\S]*?)```',
        caseSensitive: false,
      ).firstMatch(source);
      if (fence != null && fence.group(1)!.trim().isNotEmpty) {
        args['content'] = fence.group(1)!.trim();
      }
    }
    final asset = RegExp(
      r'''asset\s*["']?\s*[:=]\s*["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(source);
    if (asset != null) args['asset'] = asset.group(1);
  }

  return {
    'thought': 'Recovered action from non-JSON model response.',
    'action': action,
    'args': args,
  };
}

String? _firstBalancedJsonObject(String source) {
  for (var start = 0; start < source.length; start++) {
    if (source.codeUnitAt(start) != 0x7b) continue;
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < source.length; i++) {
      final code = source.codeUnitAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (code == 0x5c) {
          escaped = true;
        } else if (code == 0x22) {
          inString = false;
        }
        continue;
      }
      if (code == 0x22) {
        inString = true;
      } else if (code == 0x7b) {
        depth++;
      } else if (code == 0x7d) {
        depth--;
        if (depth == 0) return source.substring(start, i + 1);
      }
    }
  }
  return null;
}

final broCodeCodingAgentProvider = Provider<BroCodeCodingAgent>(
  (ref) => BroCodeCodingAgent(ref),
);
