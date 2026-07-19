import 'dart:convert';

import 'authoring_trace.dart';
import 'bro_code_agent_tools.dart';
import 'bro_code_workspace.dart';

/// One IMPROVE run (success or failure) within a session.
class BroCodeImproveAttempt {
  final int attemptNumber;
  final DateTime completedAt;
  final String changeRequest;
  final bool verified;
  final String outcomeMessage;
  final int turnsUsed;
  final int estimatedTokensUsed;
  final List<String> agentActivity;
  final String scriptBefore;
  final String scriptAfter;
  final Map<String, String> assetsAfter;
  final String? lastRunError;
  final List<String> dueDiligenceFindings;
  final ToolObservation? baselineSyntax;
  final ToolObservation? lastSyntaxError;
  final ToolObservation? lastSandboxError;
  final ToolObservation? lastFormatError;
  final ToolObservation? lastStyleError;
  final ToolObservation? lastPolicyError;
  final List<ToolObservation> failingObservations;

  const BroCodeImproveAttempt({
    required this.attemptNumber,
    required this.completedAt,
    required this.changeRequest,
    required this.verified,
    required this.outcomeMessage,
    this.turnsUsed = 0,
    this.estimatedTokensUsed = 0,
    this.agentActivity = const [],
    this.scriptBefore = '',
    this.scriptAfter = '',
    this.assetsAfter = const {},
    this.lastRunError,
    this.dueDiligenceFindings = const [],
    this.baselineSyntax,
    this.lastSyntaxError,
    this.lastSandboxError,
    this.lastFormatError,
    this.lastStyleError,
    this.lastPolicyError,
    this.failingObservations = const [],
  });

  Map<String, dynamic> toJson() => {
        'attemptNumber': attemptNumber,
        'completedAt': completedAt.toIso8601String(),
        'changeRequest': changeRequest,
        'verified': verified,
        'outcomeMessage': outcomeMessage,
        'turnsUsed': turnsUsed,
        'estimatedTokensUsed': estimatedTokensUsed,
        'agentActivity': agentActivity,
        'scriptBefore': scriptBefore,
        'scriptAfter': scriptAfter,
        if (assetsAfter.isNotEmpty) 'assetsAfter': assetsAfter,
        if (lastRunError != null) 'lastRunError': lastRunError,
        'dueDiligenceFindings': dueDiligenceFindings,
        'diagnostics': BroCodeFixtureReport.diagnosticsMap(
          baselineSyntax: baselineSyntax,
          lastSyntaxError: lastSyntaxError,
          lastSandboxError: lastSandboxError,
          lastFormatError: lastFormatError,
          lastStyleError: lastStyleError,
          lastPolicyError: lastPolicyError,
          failingObservations: failingObservations,
        ),
      };

  factory BroCodeImproveAttempt.fromJson(Map<String, dynamic> json) {
    return BroCodeImproveAttempt(
      attemptNumber: json['attemptNumber'] as int? ?? 0,
      completedAt: DateTime.tryParse(json['completedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      changeRequest: json['changeRequest'] as String? ?? '',
      verified: json['verified'] as bool? ?? false,
      outcomeMessage: json['outcomeMessage'] as String? ?? '',
      turnsUsed: json['turnsUsed'] as int? ?? 0,
      estimatedTokensUsed: json['estimatedTokensUsed'] as int? ?? 0,
      agentActivity: (json['agentActivity'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      scriptBefore: json['scriptBefore'] as String? ?? '',
      scriptAfter: json['scriptAfter'] as String? ?? '',
      assetsAfter: _stringMap(json['assetsAfter']),
      lastRunError: json['lastRunError'] as String?,
      dueDiligenceFindings: (json['dueDiligenceFindings'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }
}

Map<String, String> _stringMap(Object? raw) {
  if (raw is! Map) return {};
  return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
}

/// Durable IMPROVE history for one Bro Code unit (sovereign vault).
class BroCodeImproveSession {
  static const int sessionVersion = 2;
  static const String vaultKeyPrefix = 'improve-session:';
  static const String vaultMime = 'application/json';

  /// Soft cap — drop oldest attempts when exceeding this count.
  static const int maxPersistedAttempts = 5;

  /// Show "session is large" helper when at least this many attempts exist.
  static const int largeSessionHintAt = 4;

  final String agentName;
  final DateTime startedAt;
  final List<BroCodeImproveAttempt> attempts;

  BroCodeImproveSession({
    required this.agentName,
    required this.startedAt,
    List<BroCodeImproveAttempt>? attempts,
  }) : attempts = attempts ?? [];

  static String vaultKeyFor(String agentName) =>
      '$vaultKeyPrefix${agentName.trim()}';

  BroCodeImproveAttempt? get lastAttempt =>
      attempts.isEmpty ? null : attempts.last;

  bool get isLarge => attempts.length >= largeSessionHintAt;

  String? get lastWorkingScript {
    for (var i = attempts.length - 1; i >= 0; i--) {
      final s = attempts[i].scriptAfter.trim();
      if (s.isNotEmpty) return attempts[i].scriptAfter;
    }
    return null;
  }

  /// Appends [attempt], trimming oldest entries beyond [maxPersistedAttempts].
  /// Returns how many attempts were dropped (0 if none).
  int addAttempt(BroCodeImproveAttempt attempt) {
    attempts.add(attempt);
    return trimToMaxAttempts();
  }

  /// Drop oldest attempts until length ≤ [maxPersistedAttempts].
  /// Returns the number of dropped attempts.
  int trimToMaxAttempts({int max = maxPersistedAttempts}) {
    if (attempts.length <= max) return 0;
    final drop = attempts.length - max;
    attempts.removeRange(0, drop);
    return drop;
  }

  /// Empty session for the same agent (Start fresh).
  BroCodeImproveSession freshCopy() => BroCodeImproveSession(
        agentName: agentName,
        startedAt: DateTime.now(),
      );

  List<String> distinctChangeRequests() {
    final seen = <String>{};
    final out = <String>[];
    for (final a in attempts) {
      final t = a.changeRequest.trim();
      if (t.isEmpty) continue;
      if (seen.add(t)) out.add(t);
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
        'sessionVersion': sessionVersion,
        'agentName': agentName,
        'startedAt': startedAt.toIso8601String(),
        'changeRequests': distinctChangeRequests(),
        'attempts': attempts.map((a) => a.toJson()).toList(),
      };

  factory BroCodeImproveSession.fromJson(Map<String, dynamic> json) {
    final attemptsRaw = json['attempts'];
    final attempts = <BroCodeImproveAttempt>[];
    if (attemptsRaw is List) {
      for (final item in attemptsRaw) {
        if (item is Map) {
          attempts.add(
            BroCodeImproveAttempt.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    final session = BroCodeImproveSession(
      agentName: json['agentName'] as String? ?? 'Unnamed',
      startedAt: DateTime.tryParse(json['startedAt'] as String? ?? '') ??
          DateTime.now(),
      attempts: attempts,
    );
    session.trimToMaxAttempts();
    return session;
  }

  String toJsonString({bool pretty = true}) {
    if (pretty) {
      return const JsonEncoder.withIndent('  ').convert(toJson());
    }
    return jsonEncode(toJson());
  }
}

/// Diagnostic package when IMPROVE fails — clipboard / future dev-centre upload.
///
/// [reportVersion] 1: single attempt (legacy).
/// [reportVersion] 3: includes optional [authoringTrace] (frozen AUTHOR form).
class BroCodeFixtureReport {
  static const int reportVersion = 3;

  final DateTime exportedAt;
  final String appVersion;
  final BroCodeWorkspace workspace;
  final String changeRequest;
  final String? lastRunError;
  final List<String> dueDiligenceFindings;
  final List<String> agentActivity;
  final String failureMessage;
  final int turnsUsed;
  final int estimatedTokensUsed;
  final bool? expectSyntaxOk;
  final bool? expectSandboxOk;
  final ToolObservation? baselineSyntax;
  final ToolObservation? lastSyntaxError;
  final ToolObservation? lastSandboxError;
  final ToolObservation? lastFormatError;
  final ToolObservation? lastStyleError;
  final ToolObservation? lastPolicyError;
  final List<ToolObservation> failingObservations;
  final BroCodeImproveSession? session;
  final int? attemptNumber;
  final bool? verified;
  final AuthoringTrace? authoringTrace;
  final String? authoringTraceMissingReason;

  const BroCodeFixtureReport({
    required this.exportedAt,
    required this.appVersion,
    required this.workspace,
    required this.changeRequest,
    this.lastRunError,
    this.dueDiligenceFindings = const [],
    this.agentActivity = const [],
    required this.failureMessage,
    this.turnsUsed = 0,
    this.estimatedTokensUsed = 0,
    this.expectSyntaxOk,
    this.expectSandboxOk,
    this.baselineSyntax,
    this.lastSyntaxError,
    this.lastSandboxError,
    this.lastFormatError,
    this.lastStyleError,
    this.lastPolicyError,
    this.failingObservations = const [],
    this.session,
    this.attemptNumber,
    this.verified,
    this.authoringTrace,
    this.authoringTraceMissingReason,
  });

  static String _boundedDetail(String detail) =>
      detail.length > 2500 ? '${detail.substring(0, 2500)}…' : detail;

  static Map<String, dynamic>? _syntaxDiagnosticJson(ToolObservation? obs) {
    if (obs == null) return null;
    final data = obs.data;
    return {
      'message': obs.summary,
      if (data?['line'] != null) 'line': data!['line'],
      if (data?['column'] != null) 'column': data!['column'],
      if (obs.detail.isNotEmpty) 'excerpt': _boundedDetail(obs.detail),
    };
  }

  static Map<String, dynamic>? _sandboxDiagnosticJson(ToolObservation? obs) {
    if (obs == null) return null;
    return {
      'message': obs.summary,
      if (obs.detail.isNotEmpty) 'detail': _boundedDetail(obs.detail),
    };
  }

  static Map<String, dynamic>? _codedDiagnosticJson(ToolObservation? obs) {
    if (obs == null) return null;
    final findings = obs.data?['findings'];
    return {
      'message': obs.summary,
      if (obs.detail.isNotEmpty) 'detail': _boundedDetail(obs.detail),
      if (findings is List) 'findings': findings,
    };
  }

  static Map<String, dynamic> diagnosticsMap({
    ToolObservation? baselineSyntax,
    ToolObservation? lastSyntaxError,
    ToolObservation? lastSandboxError,
    ToolObservation? lastFormatError,
    ToolObservation? lastStyleError,
    ToolObservation? lastPolicyError,
    List<ToolObservation> failingObservations = const [],
  }) {
    final baseline = _syntaxDiagnosticJson(baselineSyntax);
    final lastSyntax = _syntaxDiagnosticJson(lastSyntaxError);
    final lastSandbox = _sandboxDiagnosticJson(lastSandboxError);
    final lastFormat = _codedDiagnosticJson(lastFormatError);
    final lastStyle = _codedDiagnosticJson(lastStyleError);
    final lastPolicy = _codedDiagnosticJson(lastPolicyError);
    return {
      'baselineSyntaxError': ?baseline,
      'lastSyntaxError': ?lastSyntax,
      'lastSandboxError': ?lastSandbox,
      'lastFormatError': ?lastFormat,
      'lastStyleError': ?lastStyle,
      'lastPolicyError': ?lastPolicy,
      'failingObservations':
          failingObservations.map((o) => o.toJson()).toList(),
    };
  }

  Map<String, dynamic> _diagnosticsJson() => diagnosticsMap(
        baselineSyntax: baselineSyntax,
        lastSyntaxError: lastSyntaxError,
        lastSandboxError: lastSandboxError,
        lastFormatError: lastFormatError,
        lastStyleError: lastStyleError,
        lastPolicyError: lastPolicyError,
        failingObservations: failingObservations,
      );

  Map<String, dynamic> toJson() => {
        'reportVersion': reportVersion,
        'exportedAt': exportedAt.toIso8601String(),
        'appVersion': appVersion,
        'broCode': {
          'name': workspace.name,
          'script': workspace.script,
          'schema': {
            'name': workspace.name,
            'description': workspace.description,
            'inputSchema': workspace.inputSchema,
          },
          if (workspace.assets.isNotEmpty) 'assets': workspace.assets,
        },
        'improve': {
          'changeRequest': changeRequest,
          if (attemptNumber != null) 'attemptNumber': attemptNumber,
          if (verified != null) 'verified': verified,
          if (lastRunError != null) 'lastRunError': lastRunError,
          'dueDiligenceFindings': dueDiligenceFindings,
          'agentActivity': agentActivity,
          'failureMessage': failureMessage,
          'turnsUsed': turnsUsed,
          'estimatedTokensUsed': estimatedTokensUsed,
          'diagnostics': _diagnosticsJson(),
        },
        if (session != null) 'session': session!.toJson(),
        if (authoringTrace != null)
          'authoringTrace': authoringTrace!.sanitized().toJson()
        else if (authoringTraceMissingReason != null)
          'authoringTrace': {
            'traceVersion': AuthoringTrace.traceVersion,
            'missing': true,
            'reason': authoringTraceMissingReason,
          },
        'fixture': {
          if (expectSyntaxOk != null) 'expectSyntaxOk': expectSyntaxOk,
          if (expectSandboxOk != null) 'expectSandboxOk': expectSandboxOk,
          'improveGoal': changeRequest,
          'tags': ['repro', 'improve-failed'],
        },
      };

  String toJsonString({bool pretty = true}) {
    if (pretty) {
      return const JsonEncoder.withIndent('  ').convert(toJson());
    }
    return jsonEncode(toJson());
  }

  /// Converts a saved report into a committed `*.bundle.json` shape.
  static Map<String, dynamic> reportToBundleJson(Map<String, dynamic> report) {
    final bro = report['broCode'] as Map<String, dynamic>? ?? {};
    final fixture = report['fixture'] as Map<String, dynamic>? ?? {};
    final improve = report['improve'] as Map<String, dynamic>? ?? {};
    final session = report['session'];
    final authoringTrace = report['authoringTrace'];
    return {
      'name': bro['name'],
      'script': bro['script'],
      'schema': bro['schema'],
      if (bro['assets'] != null) 'assets': bro['assets'],
      'fixture': {
        ...fixture,
        if (!fixture.containsKey('improveGoal') &&
            improve['changeRequest'] != null)
          'improveGoal': improve['changeRequest'],
      },
      'session': ?session,
      'authoringTrace': ?authoringTrace,
    };
  }
}
