import 'dart:convert';

import '../config/app_config.dart';

/// One user-visible authoring turn (typed or spoken).
class AuthoringTurn {
  final String role; // user | assistant | system_ui
  final String text;
  final DateTime at;
  final String? phase;
  final String? provider;
  final String? modelId;
  final String? llmSlot;

  const AuthoringTurn({
    required this.role,
    required this.text,
    required this.at,
    this.phase,
    this.provider,
    this.modelId,
    this.llmSlot,
  });

  Map<String, dynamic> toJson() => {
    'role': role,
    'text': text,
    'at': at.toIso8601String(),
    if (phase != null) 'phase': phase,
    if (provider != null) 'provider': provider,
    if (modelId != null) 'modelId': modelId,
    if (llmSlot != null) 'llmSlot': llmSlot,
  };

  factory AuthoringTurn.fromJson(Map<String, dynamic> json) => AuthoringTurn(
    role: json['role'] as String? ?? 'user',
    text: json['text'] as String? ?? '',
    at:
        DateTime.tryParse(json['at'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    phase: json['phase'] as String?,
    provider: json['provider'] as String?,
    modelId: json['modelId'] as String?,
    llmSlot: json['llmSlot'] as String?,
  );
}

/// Frozen App Spec form interactions for a Bro Code (S15).
class AuthoringTrace {
  static const int traceVersion = 1;

  final int version;
  final String? agentName;
  final String? provider;
  final String? modelId;
  final String llmSlot;
  final List<AuthoringTurn> turns;
  final Map<String, dynamic>? appSpecAtBuild;
  final String? buildOutcome; // built | cancelled | null
  final bool truncated;

  const AuthoringTrace({
    this.version = traceVersion,
    this.agentName,
    this.provider,
    this.modelId,
    this.llmSlot = 'author',
    this.turns = const [],
    this.appSpecAtBuild,
    this.buildOutcome,
    this.truncated = false,
  });

  static String vaultKeyFor(String agentName) =>
      '${AppConfig.authoringTraceVaultPrefix}$agentName';

  Map<String, dynamic> toJson() => {
    'traceVersion': version,
    if (agentName != null) 'agentName': agentName,
    if (provider != null) 'provider': provider,
    if (modelId != null) 'modelId': modelId,
    'llmSlot': llmSlot,
    'turns': turns.map((t) => t.toJson()).toList(),
    if (appSpecAtBuild != null) 'appSpecAtBuild': appSpecAtBuild,
    if (buildOutcome != null) 'buildOutcome': buildOutcome,
    'truncated': truncated,
  };

  factory AuthoringTrace.fromJson(Map<String, dynamic> json) {
    final rawTurns = (json['turns'] as List?) ?? const [];
    return AuthoringTrace(
      version: json['traceVersion'] as int? ?? traceVersion,
      agentName: json['agentName'] as String?,
      provider: json['provider'] as String?,
      modelId: json['modelId'] as String?,
      llmSlot: json['llmSlot'] as String? ?? 'author',
      turns: rawTurns
          .whereType<Map>()
          .map((e) => AuthoringTurn.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      appSpecAtBuild: json['appSpecAtBuild'] is Map
          ? Map<String, dynamic>.from(json['appSpecAtBuild'] as Map)
          : null,
      buildOutcome: json['buildOutcome'] as String?,
      truncated: json['truncated'] as bool? ?? false,
    );
  }

  String toJsonString({bool pretty = true}) {
    if (pretty) {
      return const JsonEncoder.withIndent('  ').convert(toJson());
    }
    return jsonEncode(toJson());
  }

  /// Redact secrets and cap size for Issue / fixture egress.
  AuthoringTrace sanitized() {
    var truncated = this.truncated;
    final capped = <AuthoringTurn>[];
    final maxTurns = AppConfig.authoringTraceMaxTurns;
    final maxChars = AppConfig.authoringTraceMaxCharsPerTurn;
    final source = turns.length > maxTurns
        ? [
            ...turns.take(maxTurns ~/ 2),
            ...turns.skip(turns.length - (maxTurns - maxTurns ~/ 2)),
          ]
        : turns;
    if (turns.length > maxTurns) truncated = true;

    for (final t in source) {
      var text = _redactSecrets(t.text);
      if (text.length > maxChars) {
        text = '${text.substring(0, maxChars)}…';
        truncated = true;
      }
      capped.add(
        AuthoringTurn(
          role: t.role,
          text: text,
          at: t.at,
          phase: t.phase,
          provider: t.provider,
          modelId: t.modelId,
          llmSlot: t.llmSlot,
        ),
      );
    }
    return AuthoringTrace(
      version: version,
      agentName: agentName,
      provider: provider,
      modelId: modelId,
      llmSlot: llmSlot,
      turns: capped,
      appSpecAtBuild: appSpecAtBuild,
      buildOutcome: buildOutcome,
      truncated: truncated,
    );
  }

  static final _secretRe = RegExp(
    r'(api[_-]?key|authorization|bearer|token|pat)\s*[:=]\s*\S+',
    caseSensitive: false,
  );

  static String _redactSecrets(String raw) =>
      raw.replaceAllMapped(_secretRe, (m) => '${m.group(1)}=***');
}
