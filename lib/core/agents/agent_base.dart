import 'dart:async';

/// Defines a parameter description that an agent expects.
class AgentParameter {
  final String type; // 'string', 'number', 'boolean'
  final String description;
  final bool required;

  const AgentParameter({
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

/// Abstract base class for all Project Aur Bhai Agents.
abstract class AurBhaiAgent {
  String get name;
  String get description;
  
  /// Exposes the parameter schemas required by the agent to execute.
  Map<String, AgentParameter> get inputSchema;

  /// Executes the agent using the parsed arguments.
  /// The returned String should be a fully formatted, human-readable sentence,
  /// as this is what the TTS engine will speak back to the user.
  /// (e.g., "Calculator agent says, the answer is 6.")
  Future<String> execute(Map<String, dynamic> parameters);
}
