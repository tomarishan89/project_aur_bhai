/// App-function slots for multi-provider BYOK (MS-LLM-MULTI-SLOT).
enum LlmSlot {
  /// Fallback when a dedicated slot is empty.
  defaultSlot('default', 'Default (all functions)'),
  language('language', 'Language / voice parse'),
  intent('intent', 'Intent routing'),
  author('author', 'Bro Code authoring'),
  improve('improve', 'IMPROVE / coding agent'),
  capabilityJudge('judge', 'Capability judge'),
  tts('tts', 'Text-to-speech');

  final String id;
  final String label;
  const LlmSlot(this.id, this.label);

  static LlmSlot fromId(String? raw) {
    for (final s in LlmSlot.values) {
      if (s.id == raw) return s;
    }
    return LlmSlot.defaultSlot;
  }
}

class ByokSlotConfig {
  final String provider;
  final String apiKey;
  final String modelName;
  final String customUrl;

  const ByokSlotConfig({
    this.provider = 'Google Gemini',
    this.apiKey = '',
    this.modelName = 'gemini-2.0-flash',
    this.customUrl = '',
  });

  bool get hasKey => apiKey.trim().isNotEmpty;

  ByokSlotConfig copyWith({
    String? provider,
    String? apiKey,
    String? modelName,
    String? customUrl,
  }) =>
      ByokSlotConfig(
        provider: provider ?? this.provider,
        apiKey: apiKey ?? this.apiKey,
        modelName: modelName ?? this.modelName,
        customUrl: customUrl ?? this.customUrl,
      );

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'apiKey': apiKey,
        'modelName': modelName,
        'customUrl': customUrl,
      };

  factory ByokSlotConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ByokSlotConfig();
    return ByokSlotConfig(
      provider: json['provider'] as String? ?? 'Google Gemini',
      apiKey: json['apiKey'] as String? ?? '',
      modelName: json['modelName'] as String? ?? 'gemini-2.0-flash',
      customUrl: json['customUrl'] as String? ?? '',
    );
  }
}
