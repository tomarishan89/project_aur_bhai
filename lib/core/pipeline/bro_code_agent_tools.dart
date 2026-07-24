import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/agent_verification_service.dart';
import '../services/js_bridge_service.dart';
import '../services/script_edits.dart';
import 'bro_code_capability_judge.dart';
import 'bro_code_dashboard_goal.dart';
import 'bro_code_platform_integrity.dart';
import 'bro_code_style_checker.dart';
import 'bro_code_workspace.dart';

/// Structured tool observation for the coding agent loop.
class ToolObservation {
  final bool ok;
  final String tool;
  final String summary;
  final String detail;
  final String? nextHint;
  final Map<String, dynamic>? data;

  const ToolObservation({
    required this.ok,
    required this.tool,
    required this.summary,
    this.detail = '',
    this.nextHint,
    this.data,
  });

  String toAgentMessage() {
    final buf = StringBuffer();
    buf.writeln('Observation ($tool): ${ok ? 'OK' : 'FAIL'} — $summary');
    if (detail.isNotEmpty) {
      buf.writeln(
        detail.length > 2500 ? '${detail.substring(0, 2500)}…' : detail,
      );
    }
    if (nextHint != null && nextHint!.isNotEmpty) {
      buf.writeln('Hint: $nextHint');
    }
    return buf.toString().trimRight();
  }

  Map<String, dynamic> toJson() => {
    'ok': ok,
    'tool': tool,
    'summary': summary,
    'detail': detail,
    if (nextHint != null) 'nextHint': nextHint,
    if (data != null) 'data': data,
  };
}

/// Host-side tools against a [BroCodeWorkspace].
class BroCodeAgentTools {
  final Ref _ref;
  final BroCodeWorkspace workspace;

  /// Set after a successful sandbox_run following the last mutate.
  bool syntaxOkAfterLastMutate = false;
  bool sandboxOkAfterLastMutate = false;
  bool formatOkAfterLastMutate = false;
  bool styleOkAfterLastMutate = false;
  bool policyOkAfterLastMutate = false;
  bool goalOkAfterLastMutate = true;
  bool integrityOkAfterLastMutate = true;
  int writeFullScriptCount = 0;
  int writeFullAssetCount = 0;
  int sandboxRunCount = 0;

  /// Consecutive apply_edit misses (exact + fuzzy). Resets on success.
  int applyEditMissCount = 0;

  /// After this many misses, host allows asset-targeted write_full even near-green.
  static const int maxApplyEditMissesBeforeWriteFull = 3;

  /// Last change request used for goal-aware HTML acceptance.
  String? lastChangeRequest;

  /// Last platform integrity scan (orphan assets / half-thin).
  BroCodePlatformIntegrityResult? lastIntegrityResult;

  /// Last sandbox execution trace (for capability judge).
  BroCodeExecutionTrace? lastExecutionTrace;

  /// Pluggable judge (heuristic today; LLM later).
  BroCodeCapabilityJudge capabilityJudge = HeuristicBroCodeCapabilityJudge();

  static const int maxWriteFullScriptPerRun = 2;
  static const int maxWriteFullAssetPerRun = 4;
  static const int maxSandboxRuns = 4;

  BroCodeAgentTools(this._ref, this.workspace);

  void _markMutated() {
    syntaxOkAfterLastMutate = false;
    sandboxOkAfterLastMutate = false;
    formatOkAfterLastMutate = false;
    styleOkAfterLastMutate = false;
    policyOkAfterLastMutate = false;
    goalOkAfterLastMutate = false;
    integrityOkAfterLastMutate = false;
  }

  bool get canDeclareDone =>
      syntaxOkAfterLastMutate &&
      sandboxOkAfterLastMutate &&
      formatOkAfterLastMutate &&
      styleOkAfterLastMutate &&
      policyOkAfterLastMutate &&
      integrityOkAfterLastMutate &&
      goalOkAfterLastMutate;

  bool get allowAssetWriteFullEscalation =>
      applyEditMissCount >= maxApplyEditMissesBeforeWriteFull;

  /// Host-only: normalize whitespace without counting as an LLM mutation.
  ToolObservation ensureFormat() {
    final result = BroCodeStyleChecker.format(workspace.script);
    if (!result.changed) {
      formatOkAfterLastMutate = true;
      return ToolObservation(
        ok: true,
        tool: 'check_format',
        summary: 'Format OK',
        detail: result.findings.isEmpty
            ? 'No format issues.'
            : result.findings.map((f) => '• $f').join('\n'),
        data: {'findings': result.findings.map((f) => f.toJson()).toList()},
      );
    }
    workspace.script = result.formattedScript;
    formatOkAfterLastMutate = true;
    return ToolObservation(
      ok: true,
      tool: 'apply_format',
      summary: 'Host auto-applied format (${result.findings.length} fix(es))',
      detail: result.findings.map((f) => '• $f').join('\n'),
      nextHint:
          'Format normalized by host; syntax/style/policy checks run automatically after edits.',
      data: {
        'findings': result.findings.map((f) => f.toJson()).toList(),
        'autoApplied': true,
      },
    );
  }

  Future<ToolObservation> execute(
    String action,
    Map<String, dynamic> args,
  ) async {
    switch (action) {
      case 'read_script':
        return _readScript(args);
      case 'read_asset':
        return _readAsset(args);
      case 'apply_edit':
        return _applyEdit(args);
      case 'write_full':
        return _writeFull(args);
      case 'validate_syntax':
        return _validateSyntax();
      case 'sandbox_run':
        return _sandboxRun(args);
      case 'scan_policy':
        return _scanPolicy();
      case 'check_format':
        return _checkFormat();
      case 'apply_format':
        return _applyFormat();
      case 'check_style':
        return _checkStyle();
      case 'check_dashboard_goals':
        return checkDashboardGoals(
          args['changeRequest'] as String? ?? lastChangeRequest,
        );
      case 'check_platform_integrity':
        return checkPlatformIntegrity();
      default:
        return ToolObservation(
          ok: false,
          tool: action,
          summary: 'Unknown action "$action"',
          nextHint:
              'Use one of: read_script, read_asset, apply_edit, write_full, '
              'validate_syntax, sandbox_run, scan_policy, check_format, '
              'apply_format, check_style, check_dashboard_goals, '
              'check_platform_integrity, done',
        );
    }
  }

  /// Orphan assets, half-thin execute, broken System.assets refs.
  ///
  /// Platform-generic — not Locator-specific.
  ToolObservation checkPlatformIntegrity() {
    final result = BroCodePlatformIntegrity.check(
      script: workspace.script,
      assets: workspace.assets,
    );
    lastIntegrityResult = result;
    integrityOkAfterLastMutate = result.ok;
    if (result.ok) {
      return const ToolObservation(
        ok: true,
        tool: 'check_platform_integrity',
        summary: 'Platform integrity OK',
        nextHint: 'Host re-checks after edits.',
      );
    }
    return ToolObservation(
      ok: false,
      tool: 'check_platform_integrity',
      summary:
          'Platform integrity failed (${result.findings.length} finding(s))',
      detail: result.findings.map((f) => '• $f').join('\n'),
      nextHint: BroCodePlatformIntegrity.canAutoRepair(result)
          ? 'Host can auto-repair with a thin execute() publisher for '
                '${result.suggestedPublishAssetId}. Prefer that over apply_edit thrash.'
          : 'Wire System.assets + writeVault, or remove unused assets. '
                'Do not leave dead code after return.',
      data: {
        'findings': result.findings,
        'orphanAssetIds': result.orphanAssetIds,
        'halfThinScript': result.halfThinScript,
        'suggestedPublishAssetId': result.suggestedPublishAssetId,
        'canAutoRepair': BroCodePlatformIntegrity.canAutoRepair(result),
      },
    );
  }

  /// Replace execute() with a thin publisher for [htmlAssetId].
  ToolObservation applyThinPublishRepair({String? htmlAssetId}) {
    final id =
        htmlAssetId ??
        lastIntegrityResult?.suggestedPublishAssetId ??
        workspace.assets.keys.cast<String?>().firstWhere(
          (k) =>
              k != null &&
              (k.toLowerCase().endsWith('.html') ||
                  k.toLowerCase().endsWith('.htm')),
          orElse: () => null,
        );
    if (id == null || id.isEmpty) {
      return const ToolObservation(
        ok: false,
        tool: 'host_auto_thin_repair',
        summary: 'No HTML asset available for thin publish repair',
      );
    }
    final resolved =
        BroCodePlatformIntegrity.resolveAssetKey(workspace.assets, id) ?? id;
    workspace.script = BroCodePlatformIntegrity.buildThinPublishExecute(
      htmlAssetId: resolved,
      vaultKey: resolved,
      assets: workspace.assets,
    );
    _markMutated();
    applyEditMissCount = 0;
    return ToolObservation(
      ok: true,
      tool: 'host_auto_thin_repair',
      summary: 'Host rewrote thin execute() to publish $resolved',
      detail:
          'Platform integrity repair: execute() now only loads System.assets '
          'and System.writeVault. Sidecar HTML unchanged.',
      nextHint: 'Host will re-verify syntax/sandbox/goals.',
      data: {'htmlAssetId': resolved},
    );
  }

  /// Semantic HTML acceptance: dangling DOM, chart removal, map, PWA.
  ToolObservation checkDashboardGoals(String? changeRequest) {
    final change = (changeRequest ?? lastChangeRequest ?? '').trim();
    lastChangeRequest = change.isEmpty ? lastChangeRequest : change;
    if (change.isEmpty) {
      goalOkAfterLastMutate = true;
      return const ToolObservation(
        ok: true,
        tool: 'check_dashboard_goals',
        summary: 'No change request — dashboard goals skipped',
      );
    }

    final result = BroCodeDashboardGoalChecker.checkAgainstChangeRequest(
      changeRequest: change,
      script: workspace.script,
      assets: workspace.assets,
    );
    goalOkAfterLastMutate = result.ok;
    if (result.ok) {
      return const ToolObservation(
        ok: true,
        tool: 'check_dashboard_goals',
        summary: 'Dashboard goals OK',
        nextHint: 'Action done when all host gates are green.',
      );
    }
    return ToolObservation(
      ok: false,
      tool: 'check_dashboard_goals',
      summary: 'Dashboard goals failed (${result.findings.length} finding(s))',
      detail: result.findings.map((f) => '• $f').join('\n'),
      nextHint:
          'Edit the HTML that System.writeVault publishes (template or '
          'System.assets["id"] wired in execute). Orphan sidecar edits do not count. '
          'Satisfy the change request (datetime/slider/map/PWA/DOM) there. '
          'Host re-checks after edits.',
      data: {'findings': result.findings},
    );
  }

  ToolObservation _readScript(Map<String, dynamic> args) {
    final line = args['line'] as int? ?? args['lineNumber'] as int?;
    final start = args['startLine'] as int?;
    final end = args['endLine'] as int?;
    if (line != null) {
      return ToolObservation(
        ok: true,
        tool: 'read_script',
        summary:
            'Excerpt around line $line (${workspace.scriptCharCount} chars total)',
        detail: workspace.excerptAroundLine(line),
      );
    }
    if (start != null && end != null) {
      final lines = workspace.script.split('\n');
      final s = (start - 1).clamp(0, lines.length);
      final e = end.clamp(0, lines.length);
      final slice = lines
          .sublist(s, e)
          .asMap()
          .entries
          .map((e) {
            return '${(e.key + s + 1).toString().padLeft(4)}| ${e.value}';
          })
          .join('\n');
      return ToolObservation(
        ok: true,
        tool: 'read_script',
        summary: 'Lines $start-$end',
        detail: slice,
      );
    }
    final preview = workspace.script.length > 6000
        ? '${workspace.script.substring(0, 6000)}\n… [truncated; use line ranges]'
        : workspace.script;
    return ToolObservation(
      ok: true,
      tool: 'read_script',
      summary: 'Full/preview script (${workspace.scriptCharCount} chars)',
      detail: preview,
      nextHint: workspace.script.length > 6000
          ? 'Script is large — prefer read_script with startLine/endLine or line.'
          : null,
    );
  }

  ToolObservation _readAsset(Map<String, dynamic> args) {
    final id = (args['id'] as String? ?? args['asset'] as String?)?.trim();
    if (id == null || id.isEmpty) {
      return ToolObservation(
        ok: false,
        tool: 'read_asset',
        summary: 'Missing asset id',
        detail: 'Known: ${workspace.assets.keys.join(', ')}',
      );
    }
    final resolved = BroCodePlatformIntegrity.resolveAssetKey(
      workspace.assets,
      id,
    );
    if (resolved == null) {
      return ToolObservation(
        ok: false,
        tool: 'read_asset',
        summary: 'Unknown asset "$id"',
        detail: 'Known: ${workspace.assets.keys.join(', ')}',
      );
    }
    final content = workspace.assets[resolved]!;
    return ToolObservation(
      ok: true,
      tool: 'read_asset',
      summary: 'Asset $resolved (${content.length} chars)',
      detail: content.length > 4000
          ? '${content.substring(0, 4000)}…'
          : content,
    );
  }

  ToolObservation _applyEdit(Map<String, dynamic> args) {
    final target = (args['asset'] as String?)?.trim();
    final oldB64 = args['oldStringBase64'] as String?;
    final newB64 = args['newStringBase64'] as String?;
    String? oldStr = args['old'] as String? ?? args['oldString'] as String?;
    String? newStr = args['new'] as String? ?? args['newString'] as String?;
    try {
      if (oldB64 != null && oldB64.trim().isNotEmpty) {
        oldStr = utf8.decode(
          base64Decode(oldB64.replaceAll(RegExp(r'\s+'), '')),
        );
      }
      if (newB64 != null && newB64.trim().isNotEmpty) {
        newStr = utf8.decode(
          base64Decode(newB64.replaceAll(RegExp(r'\s+'), '')),
        );
      }
    } catch (e) {
      return ToolObservation(
        ok: false,
        tool: 'apply_edit',
        summary: 'Invalid Base64 in edit',
        detail: '$e',
        nextHint:
            'EDIT_NOT_FOUND-style: resend exact UTF-8 in old/new or Base64.',
      );
    }
    if (oldStr == null || newStr == null) {
      return const ToolObservation(
        ok: false,
        tool: 'apply_edit',
        summary: 'Need old and new (or Base64 fields)',
        nextHint: 'Pass old/new unique snippets from read_script.',
      );
    }
    final replaceAll = args['replaceAll'] as bool? ?? false;
    try {
      if (target == null || target.isEmpty) {
        workspace.script = applyScriptEdits(workspace.script, [
          ScriptEdit(
            oldString: oldStr,
            newString: newStr,
            replaceAll: replaceAll,
          ),
        ]);
      } else {
        final resolved = BroCodePlatformIntegrity.resolveAssetKey(
          workspace.assets,
          target,
        );
        if (resolved == null) {
          applyEditMissCount++;
          return ToolObservation(
            ok: false,
            tool: 'apply_edit',
            summary: 'Unknown asset "$target"',
            detail: workspace.assets.isEmpty
                ? 'No assets in workspace.'
                : 'Known: ${workspace.assets.keys.join(", ")}',
            nextHint: allowAssetWriteFullEscalation
                ? 'apply_edit missed $applyEditMissCount times — use write_full '
                      '{"asset":"<exact id>","content":"…"} for this asset.'
                : 'Use an exact asset id from the Assets list (case may differ).',
            data: {
              'applyEditMissCount': applyEditMissCount,
              'allowAssetWriteFullEscalation': allowAssetWriteFullEscalation,
            },
          );
        }
        final existing = workspace.assets[resolved]!;
        workspace.assets[resolved] = applyScriptEdits(existing, [
          ScriptEdit(
            oldString: oldStr,
            newString: newStr,
            replaceAll: replaceAll,
            asset: resolved,
          ),
        ]);
      }
      _markMutated();
      applyEditMissCount = 0;
      return ToolObservation(
        ok: true,
        tool: 'apply_edit',
        summary: 'Edit applied${target != null ? ' to asset $target' : ''}',
        detail:
            'Script now ${workspace.scriptCharCount} chars. Host will re-verify format, syntax, style, and sandbox.',
        nextHint:
            'Host re-verifies after this edit. Fix any style/syntax findings with apply_edit.',
      );
    } catch (e) {
      applyEditMissCount++;
      return ToolObservation(
        ok: false,
        tool: 'apply_edit',
        summary: scriptEditFailureMessage(e),
        detail: '$e',
        nextHint:
            allowAssetWriteFullEscalation && target != null && target.isNotEmpty
            ? 'apply_edit missed $applyEditMissCount times — use write_full '
                  'with {"asset":"$target","content":"…"} (near-green lifted for assets).'
            : 'EDIT_NOT_FOUND — host also tried whitespace-fuzzy match. '
                  'read_script/read_asset and use a longer unique old snippet.',
        data: {
          'applyEditMissCount': applyEditMissCount,
          'allowAssetWriteFullEscalation': allowAssetWriteFullEscalation,
          'skipIdenticalFailure':
              applyEditMissCount < maxApplyEditMissesBeforeWriteFull,
        },
      );
    }
  }

  ToolObservation _writeFull(Map<String, dynamic> args) {
    final target = (args['asset'] as String?)?.trim();
    final isAsset = target != null && target.isNotEmpty;

    if (isAsset) {
      if (writeFullAssetCount >= maxWriteFullAssetPerRun) {
        return ToolObservation(
          ok: false,
          tool: 'write_full',
          summary:
              'write_full asset budget exhausted ($maxWriteFullAssetPerRun per run)',
          nextHint: 'Use apply_edit with "asset" for further changes.',
        );
      }
    } else {
      if (writeFullScriptCount >= maxWriteFullScriptPerRun) {
        return ToolObservation(
          ok: false,
          tool: 'write_full',
          summary:
              'write_full script budget exhausted ($maxWriteFullScriptPerRun per run)',
          nextHint: 'Use apply_edit for further changes.',
        );
      }
    }
    String? content = args['content'] as String? ?? args['script'] as String?;
    final b64 =
        args['contentBase64'] as String? ?? args['scriptBase64'] as String?;
    try {
      if (b64 != null && b64.trim().isNotEmpty) {
        content = utf8.decode(base64Decode(b64.replaceAll(RegExp(r'\s+'), '')));
      }
    } catch (e) {
      return ToolObservation(
        ok: false,
        tool: 'write_full',
        summary: 'Invalid Base64 content',
        detail: '$e',
      );
    }
    if (content == null || content.isEmpty) {
      final assetHint = workspace.assets.isNotEmpty
          ? ' Prefer apply_edit with {"asset":"${workspace.assets.keys.first}",...} '
                'on listed Assets instead of rewrite_full.'
          : ' Prefer apply_edit with a small unique old/new snippet.';
      return ToolObservation(
        ok: false,
        tool: 'write_full',
        summary: 'Missing content / scriptBase64',
        detail:
            'write_full requires args.content, args.script, args.scriptBase64, '
            'or args.contentBase64. Empty/recovered calls with no payload are rejected.',
        nextHint:
            'Return valid JSON: {"thought":"…","action":"write_full",'
            '"args":{"scriptBase64":"<base64 of full source>"}} OR use apply_edit.'
            '$assetHint Do not dump raw HTML/JS outside JSON.',
        data: const {
          'emptyWriteFull': true,
          'skipIdenticalFailure': true,
          'refundTurn': true,
        },
      );
    }
    if (!isAsset) {
      workspace.script = content;
    } else {
      workspace.assets[target] = content;
    }
    if (isAsset) {
      writeFullAssetCount++;
    } else {
      writeFullScriptCount++;
    }
    _markMutated();
    return ToolObservation(
      ok: true,
      tool: 'write_full',
      summary: 'Full write applied (${content.length} chars)',
      detail:
          'Host will re-verify format, syntax, style, and sandbox after this write.',
      nextHint: 'Prefer apply_edit next time when possible.',
    );
  }

  ToolObservation _checkFormat() {
    final result = BroCodeStyleChecker.format(workspace.script);
    if (!result.changed) {
      formatOkAfterLastMutate = true;
      return ToolObservation(
        ok: true,
        tool: 'check_format',
        summary: 'Format OK',
        detail: result.findings.isEmpty
            ? 'No format issues.'
            : result.findings.map((f) => '• $f').join('\n'),
        data: {'findings': result.findings.map((f) => f.toJson()).toList()},
      );
    }
    formatOkAfterLastMutate = false;
    final previewLines = result.findings.take(12).map((f) => '• $f').join('\n');
    return ToolObservation(
      ok: false,
      tool: 'check_format',
      summary: 'Format drift (${result.findings.length} issue(s))',
      detail: previewLines.isEmpty
          ? 'Script differs from normalized form (CRLF/trailing WS/EOF newline).'
          : previewLines,
      data: {
        'findings': result.findings.map((f) => f.toJson()).toList(),
        'changed': true,
      },
    );
  }

  ToolObservation _applyFormat() => ensureFormat();

  ToolObservation _checkStyle() {
    final result = BroCodeStyleChecker.checkStyle(workspace.script);
    if (result.ok) {
      styleOkAfterLastMutate = true;
      final warnings = result.findings
          .where((f) => f.severity == BroCodeStyleSeverity.warning)
          .toList();
      return ToolObservation(
        ok: true,
        tool: 'check_style',
        summary: warnings.isEmpty
            ? 'Style OK'
            : 'Style OK (${warnings.length} warning(s))',
        detail: result.findings.isEmpty
            ? 'No style findings.'
            : result.findings.map((f) => '• $f').join('\n'),
        nextHint:
            'Host re-lints after edits. Action done when syntax/sandbox gates are green.',
        data: {'findings': result.findings.map((f) => f.toJson()).toList()},
      );
    }
    styleOkAfterLastMutate = false;
    final blocking = result.blocking;
    return ToolObservation(
      ok: false,
      tool: 'check_style',
      summary: 'Style failed (${blocking.length} blocking issue(s))',
      detail: result.findings.map((f) => '• $f').join('\n'),
      nextHint:
          'Fix with apply_edit using line/code hints. Host re-lints after your edit.',
      data: {'findings': result.findings.map((f) => f.toJson()).toList()},
    );
  }

  ToolObservation _validateSyntax() {
    final bridge = _ref.read(jsBridgeServiceProvider);
    final check = bridge.validateScriptSyntax(workspace.script);
    if (check.ok) {
      syntaxOkAfterLastMutate = true;
      return const ToolObservation(
        ok: true,
        tool: 'validate_syntax',
        summary: 'QuickJS syntax OK',
        nextHint: 'Run sandbox_run to verify behavior.',
      );
    }
    syntaxOkAfterLastMutate = false;
    final msg = check.message ?? 'syntax error';
    final loc = parseScriptErrorLocation(msg);
    final detail = loc != null ? workspace.excerptAroundLine(loc.line) : msg;
    return ToolObservation(
      ok: false,
      tool: 'validate_syntax',
      summary: msg,
      detail: detail,
      nextHint: 'SYNTAX — fix with apply_edit near the marked line.',
      data: loc != null ? {'line': loc.line, 'column': loc.column} : null,
    );
  }

  Future<ToolObservation> _sandboxRun(Map<String, dynamic> args) async {
    if (sandboxRunCount >= maxSandboxRuns) {
      return ToolObservation(
        ok: false,
        tool: 'sandbox_run',
        summary: 'sandbox_run budget exhausted ($maxSandboxRuns per run)',
      );
    }
    if (!syntaxOkAfterLastMutate) {
      final syn = _validateSyntax();
      if (!syn.ok) return syn;
    }

    sandboxRunCount++;
    final expectHtmlKeys = _parseExpectHtmlKeys(args['expectHtmlKeys']);
    final expectDashboard =
        args['expectDashboard'] as bool? ??
        (expectHtmlKeys.isNotEmpty ||
            changeImpliesDashboard(args['changeRequest'] as String?));

    final params = args['parameters'] is Map
        ? Map<String, dynamic>.from(args['parameters'] as Map)
        : _smokeParamsFromSchema(workspace.inputSchema);

    final bridge = _ref.read(jsBridgeServiceProvider);
    final logs = <String>[];
    final execution = await bridge.executeAgentScript(
      agentName: workspace.name,
      script: workspace.script,
      parameters: params,
      onStepLog: logs.add,
      sandboxMode: true,
      assets: Map<String, String>.from(workspace.assets),
    );

    final htmlKeys = execution.vaultHtmlKeysWritten;
    lastExecutionTrace = execution.trace;
    final missingKeys = expectHtmlKeys
        .where((k) => !htmlKeys.contains(k))
        .toList();
    final keysOk = missingKeys.isEmpty;
    final dashboardOk = !expectDashboard || htmlKeys.isNotEmpty;
    // Structural capability judge — fail-closed when changeRequest is set.
    BroCodeCapabilityJudgement? judgeHint;
    final change = (args['changeRequest'] as String? ?? lastChangeRequest ?? '')
        .trim();
    if (change.isNotEmpty && !execution.isError) {
      judgeHint = await capabilityJudge.judge(
        changeRequest: change,
        trace: execution.trace,
        publishedAssets: {
          for (final k in htmlKeys)
            if (workspace.assets.containsKey(k)) k: workspace.assets[k]!,
        },
      );
    }
    final judgeOk = judgeHint == null || judgeHint.ok;
    final passed = !execution.isError && dashboardOk && keysOk && judgeOk;
    sandboxOkAfterLastMutate = passed;

    if (!passed) {
      final goalDetail = <String>[
        if (expectDashboard && htmlKeys.isEmpty)
          'Expected an HTML dashboard vault write for this change (e.g. System.writeVault("….html", …)).',
        if (missingKeys.isNotEmpty)
          'Missing expected HTML key(s): ${missingKeys.join(', ')}. Wrote: ${htmlKeys.isEmpty ? '(none)' : htmlKeys.join(', ')}.',
        if (judgeHint != null && !judgeHint.ok)
          'Capability judge failed: ${judgeHint.summary}',
      ];
      return ToolObservation(
        ok: false,
        tool: 'sandbox_run',
        summary: missingKeys.isNotEmpty
            ? 'Sandbox missing expected HTML key(s): ${missingKeys.join(', ')}'
            : judgeHint != null && !judgeHint.ok
            ? 'Capability judge rejected: ${judgeHint.summary}'
            : expectDashboard && htmlKeys.isEmpty && !execution.isError
            ? 'Smoke ran but wrote no HTML dashboard (expected for this change)'
            : 'Sandbox failed: ${execution.message}',
        detail: [
          execution.message,
          ...goalDetail,
          if (judgeHint != null && !judgeHint.ok)
            'Capability judge: ${judgeHint.summary}',
          if (logs.isNotEmpty) 'Bridge:\n${logs.take(12).join('\n')}',
        ].join('\n'),
        nextHint:
            'Fix with apply_edit / write_full. Host re-verifies format, syntax, style, policy, and sandbox after edits.',
        data: {
          'htmlKeys': htmlKeys,
          if (expectHtmlKeys.isNotEmpty) 'expectHtmlKeys': expectHtmlKeys,
          if (missingKeys.isNotEmpty) 'missingHtmlKeys': missingKeys,
          'sandboxRunCount': sandboxRunCount,
          'executionTrace': execution.trace.toJson(),
          if (judgeHint != null)
            'capabilityJudge': {
              'ok': judgeHint.ok,
              'summary': judgeHint.summary,
              'unmetExpectations': judgeHint.unmetExpectations,
            },
        },
      );
    }

    return ToolObservation(
      ok: true,
      tool: 'sandbox_run',
      summary: 'Sandbox PASSED',
      detail: [
        execution.message,
        if (htmlKeys.isNotEmpty) 'HTML keys: ${htmlKeys.join(', ')}',
        if (expectHtmlKeys.isNotEmpty)
          'Expected HTML keys present: ${expectHtmlKeys.join(', ')}',
        if (judgeHint != null) 'Capability judge: ${judgeHint.summary}',
        if (logs.isNotEmpty) 'Bridge:\n${logs.take(8).join('\n')}',
      ].join('\n'),
      nextHint: 'Action done when all host gates are green.',
      data: {
        'htmlKeys': htmlKeys,
        if (expectHtmlKeys.isNotEmpty) 'expectHtmlKeys': expectHtmlKeys,
        'sandboxRunCount': sandboxRunCount,
        'executionTrace': execution.trace.toJson(),
        if (judgeHint != null)
          'capabilityJudge': {
            'ok': judgeHint.ok,
            'summary': judgeHint.summary,
            'unmetExpectations': judgeHint.unmetExpectations,
          },
      },
    );
  }

  static List<String> _parseExpectHtmlKeys(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static Map<String, dynamic> _smokeParamsFromSchema(
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

  ToolObservation _scanPolicy() {
    final scan = _ref
        .read(agentVerificationProvider)
        .scanScript(workspace.script);
    policyOkAfterLastMutate = scan.passed;
    return ToolObservation(
      ok: scan.passed,
      tool: 'scan_policy',
      summary: scan.passed
          ? 'Due diligence clean'
          : 'Due diligence flagged ${scan.findings.length} issue(s)',
      detail: scan.findings.isEmpty
          ? 'No findings'
          : scan.findings.map((f) => '• $f').join('\n'),
      nextHint: scan.passed
          ? null
          : 'Keep browser APIs inside HTML template strings only; fix with apply_edit. Host re-scans after edits.',
      data: {'findings': scan.findings.map((f) => f.toJson()).toList()},
    );
  }

  static bool changeImpliesDashboard(String? change) {
    if (change == null) return false;
    final c = change.toLowerCase();
    return c.contains('dashboard') ||
        c.contains('html') ||
        c.contains('chart') ||
        c.contains('graph') ||
        c.contains('canvas') ||
        c.contains('map') ||
        c.contains('leaflet') ||
        c.contains('pwa') ||
        c.contains('progressive') ||
        c.contains('telemetry graph') ||
        c.contains('locator');
  }
}
