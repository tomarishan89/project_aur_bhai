import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/agent_verification_service.dart';
import '../services/js_bridge_service.dart';
import '../services/script_edits.dart';
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
      buf.writeln(detail.length > 2500 ? '${detail.substring(0, 2500)}…' : detail);
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
  int writeFullCount = 0;
  int sandboxRunCount = 0;

  static const int maxWriteFullPerRun = 2;
  static const int maxSandboxRuns = 4;

  BroCodeAgentTools(this._ref, this.workspace);

  void _markMutated() {
    syntaxOkAfterLastMutate = false;
    sandboxOkAfterLastMutate = false;
  }

  bool get canDeclareDone =>
      syntaxOkAfterLastMutate && sandboxOkAfterLastMutate;

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
      default:
        return ToolObservation(
          ok: false,
          tool: action,
          summary: 'Unknown action "$action"',
          nextHint:
              'Use one of: read_script, read_asset, apply_edit, write_full, validate_syntax, sandbox_run, scan_policy, done',
        );
    }
  }

  ToolObservation _readScript(Map<String, dynamic> args) {
    final line = args['line'] as int? ?? args['lineNumber'] as int?;
    final start = args['startLine'] as int?;
    final end = args['endLine'] as int?;
    if (line != null) {
      return ToolObservation(
        ok: true,
        tool: 'read_script',
        summary: 'Excerpt around line $line (${workspace.scriptCharCount} chars total)',
        detail: workspace.excerptAroundLine(line),
      );
    }
    if (start != null && end != null) {
      final lines = workspace.script.split('\n');
      final s = (start - 1).clamp(0, lines.length);
      final e = end.clamp(0, lines.length);
      final slice = lines.sublist(s, e).asMap().entries.map((e) {
        return '${(e.key + s + 1).toString().padLeft(4)}| ${e.value}';
      }).join('\n');
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
    final content = workspace.assets[id];
    if (content == null) {
      return ToolObservation(
        ok: false,
        tool: 'read_asset',
        summary: 'Unknown asset "$id"',
        detail: 'Known: ${workspace.assets.keys.join(', ')}',
      );
    }
    return ToolObservation(
      ok: true,
      tool: 'read_asset',
      summary: 'Asset $id (${content.length} chars)',
      detail: content.length > 4000 ? '${content.substring(0, 4000)}…' : content,
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
        oldStr = utf8.decode(base64Decode(oldB64.replaceAll(RegExp(r'\s+'), '')));
      }
      if (newB64 != null && newB64.trim().isNotEmpty) {
        newStr = utf8.decode(base64Decode(newB64.replaceAll(RegExp(r'\s+'), '')));
      }
    } catch (e) {
      return ToolObservation(
        ok: false,
        tool: 'apply_edit',
        summary: 'Invalid Base64 in edit',
        detail: '$e',
        nextHint: 'EDIT_NOT_FOUND-style: resend exact UTF-8 in old/new or Base64.',
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
        final existing = workspace.assets[target];
        if (existing == null) {
          return ToolObservation(
            ok: false,
            tool: 'apply_edit',
            summary: 'Unknown asset "$target"',
          );
        }
        workspace.assets[target] = applyScriptEdits(existing, [
          ScriptEdit(
            oldString: oldStr,
            newString: newStr,
            replaceAll: replaceAll,
            asset: target,
          ),
        ]);
      }
      _markMutated();
      return ToolObservation(
        ok: true,
        tool: 'apply_edit',
        summary: 'Edit applied${target != null ? ' to asset $target' : ''}',
        detail: 'Script now ${workspace.scriptCharCount} chars. Run validate_syntax next.',
        nextHint: 'Call validate_syntax, then sandbox_run before done.',
      );
    } catch (e) {
      return ToolObservation(
        ok: false,
        tool: 'apply_edit',
        summary: scriptEditFailureMessage(e),
        detail: '$e',
        nextHint:
            'EDIT_NOT_FOUND or ambiguous — read_script around the region, use a longer unique old snippet.',
      );
    }
  }

  ToolObservation _writeFull(Map<String, dynamic> args) {
    if (writeFullCount >= maxWriteFullPerRun) {
      return ToolObservation(
        ok: false,
        tool: 'write_full',
        summary: 'write_full budget exhausted ($maxWriteFullPerRun per run)',
        nextHint: 'Use apply_edit for further changes.',
      );
    }
    final target = (args['asset'] as String?)?.trim();
    String? content = args['content'] as String? ?? args['script'] as String?;
    final b64 = args['contentBase64'] as String? ?? args['scriptBase64'] as String?;
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
      return const ToolObservation(
        ok: false,
        tool: 'write_full',
        summary: 'Missing content / scriptBase64',
      );
    }
    if (target == null || target.isEmpty) {
      workspace.script = content;
    } else {
      workspace.assets[target] = content;
    }
    writeFullCount++;
    _markMutated();
    return ToolObservation(
      ok: true,
      tool: 'write_full',
      summary: 'Full write applied (${content.length} chars)',
      detail: 'validate_syntax then sandbox_run required before done.',
      nextHint: 'Prefer apply_edit next time when possible.',
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
    final detail = loc != null
        ? workspace.excerptAroundLine(loc.line)
        : msg;
    return ToolObservation(
      ok: false,
      tool: 'validate_syntax',
      summary: msg,
      detail: detail,
      nextHint: 'SYNTAX — fix with apply_edit near the marked line.',
      data: loc != null
          ? {'line': loc.line, 'column': loc.column}
          : null,
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
    final expectDashboard = args['expectDashboard'] as bool? ??
        changeImpliesDashboard(args['changeRequest'] as String?);

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
    );

    final htmlKeys = execution.vaultHtmlKeysWritten;
    final dashboardOk = !expectDashboard || htmlKeys.isNotEmpty;
    final passed = !execution.isError && dashboardOk;
    sandboxOkAfterLastMutate = passed;

    if (!passed) {
      return ToolObservation(
        ok: false,
        tool: 'sandbox_run',
        summary: expectDashboard && htmlKeys.isEmpty && !execution.isError
            ? 'Smoke ran but wrote no HTML dashboard (expected for this change)'
            : 'Sandbox failed: ${execution.message}',
        detail: [
          execution.message,
          if (logs.isNotEmpty) 'Bridge:\n${logs.take(12).join('\n')}',
        ].join('\n'),
        nextHint: 'Fix with apply_edit / write_full, then validate_syntax + sandbox_run.',
        data: {
          'htmlKeys': htmlKeys,
          'sandboxRunCount': sandboxRunCount,
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
        if (logs.isNotEmpty) 'Bridge:\n${logs.take(8).join('\n')}',
      ].join('\n'),
      nextHint: 'You may action done if no further changes needed.',
      data: {'htmlKeys': htmlKeys},
    );
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
    final scan =
        _ref.read(agentVerificationProvider).scanScript(workspace.script);
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
          : 'DOM_OUTSIDE_SANDBOX / similar — keep browser APIs inside HTML template strings only.',
    );
  }

  static bool changeImpliesDashboard(String? change) {
    if (change == null) return false;
    final c = change.toLowerCase();
    return c.contains('dashboard') ||
        c.contains('html') ||
        c.contains('chart') ||
        c.contains('telemetry graph') ||
        c.contains('locator');
  }
}
