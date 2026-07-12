import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/js_bridge_service.dart';
import 'agent_base.dart';

/// 4-tier trust classification for ecosystem agents.
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

/// Thin [AurBhaiAgent] wrapper that delegates execution to the QuickJS sandbox.
class JsAgentAdapter extends AurBhaiAgent {
  final Ref _ref;
  final String _name;
  final String _description;
  final Map<String, AgentParameter> _inputSchema;
  final String _script;

  /// Trust tier assigned at import/authoring time.
  final AgentSecurityClass securityClass;

  /// When the agent was first saved to the vault (ISO-8601).
  final DateTime? createdAt;

  /// When the agent was last refined/saved (ISO-8601).
  final DateTime? updatedAt;

  /// Raw JS source (exposed for lifecycle / export).
  String get script => _script;

  /// Optional sink for bridge step logs (wired by [VoiceHandshakeEngine]).
  void Function(String step)? bridgeLogSink;

  /// Last sandbox run details (vault HTML keys, error flag).
  AgentExecutionResult? lastExecutionResult;

  JsAgentAdapter({
    required this._ref,
    required this._name,
    required this._description,
    required this._inputSchema,
    required this._script,
    this.securityClass = AgentSecurityClass.c4Unverified,
    this.createdAt,
    this.updatedAt,
  });

  /// Execution is allowed only for Core (C1) or Verified (C2) agents.
  bool get canExecute =>
      securityClass == AgentSecurityClass.c1Core ||
      securityClass == AgentSecurityClass.c2Verified;

  @override
  String get name => _name;

  @override
  String get description => _description;

  @override
  Map<String, AgentParameter> get inputSchema => _inputSchema;

  @override
  Future<String> execute(Map<String, dynamic> parameters) async {
    if (!canExecute) {
      lastExecutionResult = AgentExecutionResult(
        message:
            '$_name is not verified yet (${securityClass.id}). Promote it to C2 from the Agents page after due diligence before running.',
        isError: true,
      );
      return lastExecutionResult!.message;
    }

    final bridge = _ref.read(jsBridgeServiceProvider);
    final result = await bridge.executeAgentScript(
      agentName: _name,
      script: _script,
      parameters: parameters,
      onStepLog: bridgeLogSink,
    );
    lastExecutionResult = result;
    return result.message;
  }
}
