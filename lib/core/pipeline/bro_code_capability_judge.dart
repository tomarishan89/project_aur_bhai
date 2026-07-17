/// Generic Bro Code capability verification (design + stubs).
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

/// One side-effect captured during sandbox / dry-run execution.
class BroCodeExecutionEvent {
  final String kind; // writeVault | sendHTTP | log | querySQL | schedule | other
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

/// Pluggable judge: today a stub; tomorrow a fast LLM / heuristic matcher.
///
/// Contract for implementers:
/// - Input: raw [changeRequest] + [BroCodeExecutionTrace] (+ optional published HTML)
/// - Output: pass/fail with concrete unmet expectations the agent can fix
/// - Must NOT assume Locator, maps, or PWA — those are just possible intents
abstract class BroCodeCapabilityJudge {
  Future<BroCodeCapabilityJudgement> judge({
    required String changeRequest,
    required BroCodeExecutionTrace trace,
    Map<String, String> publishedAssets = const {},
  });
}

/// Heuristic placeholder until the LLM judge is wired to BYOK.
///
/// Does NOT claim feature fidelity. Passes when sandbox ran and produced at
/// least one vault HTML write for UI-ish requests, or any side effect for
/// non-UI requests. Real judging belongs in [LlmBroCodeCapabilityJudge].
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
    final wantsUi = req.contains('dashboard') ||
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
      return mime.contains('html') || key.endsWith('.html') || key.endsWith('.htm');
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

    return BroCodeCapabilityJudgement(
      ok: true,
      summary:
          'Heuristic pass (structural only) — LLM judge not yet wired for '
          'full intent fidelity',
      evidence: [
        'events=${trace.events.length}',
        'vaultHtmlWrites=${vaultHtml.length}',
      ],
    );
  }
}

/// Future: call a small BYOK model with a fixed judge prompt.
///
/// Prompt sketch (do not hardcode product features):
/// ```
/// USER ASKED: …
/// EXECUTION TRACE (JSON): …
/// PUBLISHED ASSETS (keys + truncated bodies): …
/// Question: Does the trace fulfill the ask? Reply JSON
/// {"ok":bool,"unmetExpectations":[…],"evidence":[…]}
/// ```
class LlmBroCodeCapabilityJudge implements BroCodeCapabilityJudge {
  // ignore: unused_field — reserved for BYOK wiring
  final Future<String> Function(String prompt)? _complete;

  LlmBroCodeCapabilityJudge({Future<String> Function(String prompt)? complete})
      : _complete = complete;

  @override
  Future<BroCodeCapabilityJudgement> judge({
    required String changeRequest,
    required BroCodeExecutionTrace trace,
    Map<String, String> publishedAssets = const {},
  }) async {
    if (_complete == null) {
      return HeuristicBroCodeCapabilityJudge().judge(
        changeRequest: changeRequest,
        trace: trace,
        publishedAssets: publishedAssets,
      );
    }
    // Full LLM path lands with MS-BROCODE-CAPABILITY-JUDGE.
    return HeuristicBroCodeCapabilityJudge().judge(
      changeRequest: changeRequest,
      trace: trace,
      publishedAssets: publishedAssets,
    );
  }
}
