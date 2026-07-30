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

  /// Gemini thinking level when supported (e.g. minimal / low / medium / high).
  final String? thinkingLevel;

  /// Max output tokens for completions; null ⇒ provider/call-site default.
  final int? maxOutputTokens;

  const ByokSlotConfig({
    this.provider = 'Google Gemini',
    this.apiKey = '',
    this.modelName = 'gemini-3.5-flash',
    this.customUrl = '',
    this.thinkingLevel,
    this.maxOutputTokens,
  });

  bool get hasKey => apiKey.trim().isNotEmpty;

  ByokSlotConfig copyWith({
    String? provider,
    String? apiKey,
    String? modelName,
    String? customUrl,
    String? thinkingLevel,
    int? maxOutputTokens,
    bool clearThinkingLevel = false,
    bool clearMaxOutputTokens = false,
  }) => ByokSlotConfig(
    provider: provider ?? this.provider,
    apiKey: apiKey ?? this.apiKey,
    modelName: modelName ?? this.modelName,
    customUrl: customUrl ?? this.customUrl,
    thinkingLevel: clearThinkingLevel
        ? null
        : (thinkingLevel ?? this.thinkingLevel),
    maxOutputTokens: clearMaxOutputTokens
        ? null
        : (maxOutputTokens ?? this.maxOutputTokens),
  );

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'apiKey': apiKey,
    'modelName': modelName,
    'customUrl': customUrl,
    if (thinkingLevel != null) 'thinkingLevel': thinkingLevel,
    if (maxOutputTokens != null) 'maxOutputTokens': maxOutputTokens,
  };

  factory ByokSlotConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ByokSlotConfig();
    final maxRaw = json['maxOutputTokens'];
    return ByokSlotConfig(
      provider: json['provider'] as String? ?? 'Google Gemini',
      apiKey: json['apiKey'] as String? ?? '',
      modelName: json['modelName'] as String? ?? 'gemini-3.5-flash',
      customUrl: json['customUrl'] as String? ?? '',
      thinkingLevel: json['thinkingLevel'] as String?,
      maxOutputTokens: maxRaw is int
          ? maxRaw
          : (maxRaw is num ? maxRaw.toInt() : null),
    );
  }
}
