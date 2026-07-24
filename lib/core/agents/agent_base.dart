/// Defines a parameter description that a Bro Code expects.
class BroCodeParameter {
  final String type; // 'string', 'number', 'boolean'
  final String description;
  final bool required;

  const BroCodeParameter({
    required this.type,
    required this.description,
    this.required = true,
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    'description': description,
    'required': required,
  };
}

/// @Deprecated Use [BroCodeParameter]. Kept for gradual migration.
typedef AgentParameter = BroCodeParameter;

/// Abstract base for a user-generated Bro Code unit (JS/app codebase).
///
/// Product language: collectively **Bhai log**, individually a **Bro Code**.
/// Reserve the word **Agent** for internal AI workers (Coder / Tester / Deployer).
abstract class BroCode {
  String get name;
  String get description;

  /// Parameter schemas required to execute.
  Map<String, BroCodeParameter> get inputSchema;

  /// Executes and returns a TTS-friendly sentence.
  Future<String> execute(Map<String, dynamic> parameters);
}

/// @Deprecated Use [BroCode]. Kept for gradual migration.
typedef AurBhaiAgent = BroCode;
