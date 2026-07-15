import 'dart:convert';

import 'bro_code_workspace.dart';

/// v1 diagnostic package when IMPROVE fails — for clipboard / future dev-centre upload.
class BroCodeFixtureReport {
  static const int reportVersion = 1;

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
  });

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
          if (lastRunError != null) 'lastRunError': lastRunError,
          'dueDiligenceFindings': dueDiligenceFindings,
          'agentActivity': agentActivity,
          'failureMessage': failureMessage,
          'turnsUsed': turnsUsed,
          'estimatedTokensUsed': estimatedTokensUsed,
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
    };
  }
}
