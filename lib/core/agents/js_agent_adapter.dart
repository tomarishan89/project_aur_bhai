import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/js_bridge_service.dart';
import 'agent_base.dart';

/// 4-tier trust classification for Bro Code (Bhai log).
enum AgentSecurityClass {
  c1Core,
  c2Verified,
  c3DueDiligence,
  c4Unverified,
}

extension AgentSecurityClassX on AgentSecurityClass {
  String get id => switch (this) {
        AgentSecurityClass.c1Core => 'C1',
        AgentSecurityClass.c2Verified => 'C2',
        AgentSecurityClass.c3DueDiligence => 'C3',
        AgentSecurityClass.c4Unverified => 'C4',
      };

  String get label => switch (this) {
        AgentSecurityClass.c1Core => 'C1: Core',
        AgentSecurityClass.c2Verified => 'C2: Verified',
        AgentSecurityClass.c3DueDiligence => 'C3: Due Diligence',
        AgentSecurityClass.c4Unverified => 'C4: Unverified',
      };

  static AgentSecurityClass fromId(String? id) {
    switch (id?.toUpperCase()) {
      case 'C1':
        return AgentSecurityClass.c1Core;
      case 'C2':
        return AgentSecurityClass.c2Verified;
      case 'C3':
        return AgentSecurityClass.c3DueDiligence;
      case 'C4':
        return AgentSecurityClass.c4Unverified;
      default:
        return AgentSecurityClass.c4Unverified;
    }
  }
}

/// Thin [BroCode] wrapper that delegates execution to QuickJS.
class JsAgentAdapter extends BroCode {
  final Ref _ref;
  final String _name;
  final String _description;
  final Map<String, BroCodeParameter> _inputSchema;
  final String _script;
  final Map<String, String> _assets;

  /// Trust tier assigned at import/authoring time.
  final AgentSecurityClass securityClass;

  /// When the Bro Code was first saved to the vault (ISO-8601).
  final DateTime? createdAt;

  /// When last refined/saved (ISO-8601).
  final DateTime? updatedAt;

  /// Raw JS source (exposed for lifecycle / export).
  String get script => _script;

  /// Sidecar assets injected as `System.assets` at run time.
  Map<String, String> get assets => Map.unmodifiable(_assets);

  /// Optional sink for bridge step logs (wired by [VoiceHandshakeEngine]).
  void Function(String step)? bridgeLogSink;

  /// Last sandbox run details (vault HTML keys, error flag).
  AgentExecutionResult? lastExecutionResult;

  JsAgentAdapter({
    required this._ref,
    required String name,
    required this._description,
    required this._inputSchema,
    required this._script,
    Map<String, String> assets = const {},
    this.securityClass = AgentSecurityClass.c4Unverified,
    this.createdAt,
    this.updatedAt,
  })  : _name = name,
        _assets = Map<String, String>.from(assets);

  /// Production RUN allowed only for Core (C1) or Verified (C2).
  bool get canExecute =>
      securityClass == AgentSecurityClass.c1Core ||
      securityClass == AgentSecurityClass.c2Verified;

  /// Unverified Bro Code may still be exercised against the mock vault.
  bool get canTestInSandbox => true;

  @override
  String get name => _name;

  @override
  String get description => _description;

  @override
  Map<String, BroCodeParameter> get inputSchema => _inputSchema;

  @override
  Future<String> execute(Map<String, dynamic> parameters) async {
    if (!canExecute) {
      lastExecutionResult = AgentExecutionResult(
        message:
            '$_name is not verified yet (${securityClass.id}). Promote it to C2 from Bhai log after due diligence before running against the real vault. Use Test in Sandbox to exercise it safely.',
        isError: true,
      );
      return lastExecutionResult!.message;
    }

    return _run(parameters, sandboxMode: false);
  }

  /// Runs against the in-memory sandbox vault (never sovereign data).
  Future<String> executeInSandbox(Map<String, dynamic> parameters) async {
    return _run(parameters, sandboxMode: true);
  }

  Future<String> _run(
    Map<String, dynamic> parameters, {
    required bool sandboxMode,
  }) async {
    final bridge = _ref.read(jsBridgeServiceProvider);
    final result = await bridge.executeAgentScript(
      agentName: _name,
      script: _script,
      parameters: parameters,
      onStepLog: bridgeLogSink,
      sandboxMode: sandboxMode,
      assets: _assets,
    );
    lastExecutionResult = result;
    return result.message;
  }
}
