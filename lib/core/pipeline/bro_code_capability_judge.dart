/// Generic Bro Code capability verification.
///
/// PLATFORM NOTE — applies to EVERY Bro Code, not Locator alone:
/// Users may ask for dashboards, tweets, smart-device commands, notifications,
/// camera feeds, etc. Host checks must stay capability-agnostic:
///   1) Platform integrity (syntax, policy, orphan assets, half-thin wiring)
///   2) Sandbox execution trace (writeVault / sendHTTP / future bridges)
///   3) Capability judge: does the trace fulfill the user's change request?
///
/// Hardcoded feature regex (slider/datetime/Leaflet) is a transitional helper
/// inside [BroCodeDashboardGoalChecker] only. New capabilities must go through
/// this judge path, not new per-app regex gates.
library;

import 'dart:convert';

/// One side-effect captured during sandbox / dry-run execution.
class BroCodeExecutionEvent {
  final String
  kind; // writeVault | sendHTTP | log | querySQL | schedule | other
  final Map<String, dynamic> data;
  final String? summary;

  const BroCodeExecutionEvent({
    required this.kind,
    this.data = const {},
    this.summary,
  });

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'data': data,
    if (summary != null) 'summary': summary,
  };
}

/// Trace of sandbox side effects for capability judging.
class BroCodeExecutionTrace {
  final List<BroCodeExecutionEvent> events;
  final String? returnMessage;
  final bool ranOk;

  const BroCodeExecutionTrace({
    this.events = const [],
    this.returnMessage,
    this.ranOk = false,
  });

  List<BroCodeExecutionEvent> ofKind(String kind) =>
      events.where((e) => e.kind == kind).toList();

  Map<String, dynamic> toJson() => {
    'ranOk': ranOk,
    'returnMessage': returnMessage,
    'events': events.map((e) => e.toJson()).toList(),
  };
}

/// Outcome of comparing user intent to an execution trace.
class BroCodeCapabilityJudgement {
  final bool ok;
  final String summary;
  final List<String> unmetExpectations;
  final List<String> evidence;

  const BroCodeCapabilityJudgement({
    required this.ok,
    required this.summary,
    this.unmetExpectations = const [],
    this.evidence = const [],
  });
}

/// Pluggable judge: heuristic + optional LLM (BYOK judge slot).
abstract class BroCodeCapabilityJudge {
  Future<BroCodeCapabilityJudgement> judge({
    required String changeRequest,
    required BroCodeExecutionTrace trace,
    Map<String, String> publishedAssets = const {},
  });
}

/// Fail-closed structural heuristic.
class HeuristicBroCodeCapabilityJudge implements BroCodeCapabilityJudge {
  @override
  Future<BroCodeCapabilityJudgement> judge({
    required String changeRequest,
    required BroCodeExecutionTrace trace,
    Map<String, String> publishedAssets = const {},
  }) async {
    if (!trace.ranOk) {
      return const BroCodeCapabilityJudgement(
        ok: false,
        summary: 'Sandbox did not complete successfully',
        unmetExpectations: ['Sandbox must run without error'],
      );
    }
    final req = changeRequest.toLowerCase();
    final wantsUi =
        req.contains('dashboard') ||
        req.contains('html') ||
        req.contains('map') ||
        req.contains('chart') ||
        req.contains('slider') ||
        req.contains('datetime') ||
        req.contains('pwa') ||
        req.contains('ui');
    final vaultHtml = trace.ofKind('writeVault').where((e) {
      final mime = (e.data['mimeType'] as String?)?.toLowerCase() ?? '';
      final key = (e.data['key'] as String?)?.toLowerCase() ?? '';
      return mime.contains('html') ||
          key.endsWith('.html') ||
          key.endsWith('.htm');
    }).toList();

    if (wantsUi && vaultHtml.isEmpty && publishedAssets.isEmpty) {
      return const BroCodeCapabilityJudgement(
        ok: false,
        summary: 'UI change request but no HTML vault write in trace',
        unmetExpectations: [
          'Publish HTML via System.writeVault(..., "text/html")',
        ],
      );
    }

    if (trace.events.isEmpty && publishedAssets.isEmpty) {
      return const BroCodeCapabilityJudgement(
        ok: false,
        summary: 'No sandbox side effects observed (fail-closed)',
        unmetExpectations: [
          'Produce at least one System bridge side effect (writeVault, sendHTTP, …)',
        ],
      );
    }

    return BroCodeCapabilityJudgement(
      ok: true,
      summary: 'Heuristic pass (structural)',
      evidence: [
        'events=${trace.events.length}',
        'vaultHtmlWrites=${vaultHtml.length}',
      ],
    );
  }
}

/// BYOK LLM judge — fixed JSON rubric; falls back to heuristic on parse failure.
class LlmBroCodeCapabilityJudge implements BroCodeCapabilityJudge {
  final Future<String> Function(String prompt)? _complete;

  LlmBroCodeCapabilityJudge({Future<String> Function(String prompt)? complete})
    : _complete = complete;

  @override
  Future<BroCodeCapabilityJudgement> judge({
    required String changeRequest,
    required BroCodeExecutionTrace trace,
    Map<String, String> publishedAssets = const {},
  }) async {
    final heuristic = HeuristicBroCodeCapabilityJudge();
    if (_complete == null) {
      return heuristic.judge(
        changeRequest: changeRequest,
        trace: trace,
        publishedAssets: publishedAssets,
      );
    }

    // Still fail-closed on empty traces before spending tokens.
    if (!trace.ranOk || (trace.events.isEmpty && publishedAssets.isEmpty)) {
      return heuristic.judge(
        changeRequest: changeRequest,
        trace: trace,
        publishedAssets: publishedAssets,
      );
    }

    final assetPreview = publishedAssets.entries
        .take(4)
        .map((e) {
          final body = e.value.length > 400
              ? '${e.value.substring(0, 400)}…'
              : e.value;
          return '${e.key}: $body';
        })
        .join('\n---\n');

    final prompt =
        '''
You are a Bro Code capability judge. Reply with ONLY JSON:
{"ok":bool,"summary":string,"unmetExpectations":[string],"evidence":[string]}

USER ASKED:
$changeRequest

EXECUTION TRACE (JSON):
${jsonEncode(trace.toJson())}

PUBLISHED ASSETS (truncated):
$assetPreview

Does the trace fulfill the ask? Be strict: no credit for unrelated side effects.
''';

    try {
      final raw = await _complete(prompt);
      final start = raw.indexOf('{');
      final end = raw.lastIndexOf('}');
      if (start < 0 || end <= start) {
        return heuristic.judge(
          changeRequest: changeRequest,
          trace: trace,
          publishedAssets: publishedAssets,
        );
      }
      final json =
          jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;
      return BroCodeCapabilityJudgement(
        ok: json['ok'] == true,
        summary: json['summary']?.toString() ?? 'LLM judge',
        unmetExpectations:
            (json['unmetExpectations'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        evidence:
            (json['evidence'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
      );
    } catch (_) {
      return heuristic.judge(
        changeRequest: changeRequest,
        trace: trace,
        publishedAssets: publishedAssets,
      );
    }
  }
}
