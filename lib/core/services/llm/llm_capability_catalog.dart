import 'anthropic_provider.dart';
import 'gemini_provider.dart';
import 'llm_model_catalog.dart';
import 'openai_provider.dart';
import 'openrouter_provider.dart';

/// Generation knobs supported for a provider+model pair.
class LlmModelCapabilities {
  /// Allowed thinking levels (Gemini); null ⇒ thinking UI hidden.
  final List<String>? thinkingLevels;

  /// Default when unset / invalid.
  final String? defaultThinking;

  final int maxTokensDefault;
  final int maxTokensMax;

  /// True when this entry came from the static map (not a live/custom fallback).
  final bool knownInCatalog;

  const LlmModelCapabilities({
    this.thinkingLevels,
    this.defaultThinking,
    this.maxTokensDefault = 4000,
    this.maxTokensMax = 65536,
    this.knownInCatalog = true,
  });

  bool get supportsThinking =>
      thinkingLevels != null && thinkingLevels!.isNotEmpty;
}

/// Static multi-provider capability map. Live metadata only for unknown/Custom.
class LlmCapabilityCatalog {
  LlmCapabilityCatalog._();

  static const flashThinking = ['minimal', 'low', 'medium', 'high'];
  static const proThinking = ['low', 'medium', 'high'];

  static const _tokensOnly = LlmModelCapabilities(
    thinkingLevels: null,
    defaultThinking: null,
    maxTokensDefault: 4000,
    maxTokensMax: 128000,
  );

  static const _geminiFlash = LlmModelCapabilities(
    thinkingLevels: flashThinking,
    defaultThinking: 'minimal',
    maxTokensDefault: 4000,
    maxTokensMax: 65536,
  );

  static const _geminiPro = LlmModelCapabilities(
    thinkingLevels: proThinking,
    defaultThinking: 'low',
    maxTokensDefault: 4000,
    maxTokensMax: 65536,
  );

  /// Capabilities for a known model, or a conservative fallback if unknown.
  static LlmModelCapabilities forModel(String providerId, String modelId) {
    final m = modelId.trim();
    if (m.isEmpty || m == kLlmModelCustomId) {
      return _unknownFallback(providerId);
    }

    final exact = _exact[providerId]?[m];
    if (exact != null) return exact;

    // Family heuristics for Gemini ids we list or user types.
    if (providerId == GeminiProvider.providerId) {
      if (m.contains('-pro')) {
        return const LlmModelCapabilities(
          thinkingLevels: proThinking,
          defaultThinking: 'low',
          maxTokensDefault: 4000,
          maxTokensMax: 65536,
          knownInCatalog: false,
        );
      }
      if (m.contains('flash') || m.contains('gemini-')) {
        return const LlmModelCapabilities(
          thinkingLevels: flashThinking,
          defaultThinking: 'minimal',
          maxTokensDefault: 4000,
          maxTokensMax: 65536,
          knownInCatalog: false,
        );
      }
    }

    // OpenRouter: max-tokens only in v1 (no Gemini thinkingConfig on OR chat API).
    if (openRouterBackedProvider(providerId) ||
        providerId == OpenRouterProvider.providerId) {
      return _tokensOnly;
    }

    return _unknownFallback(providerId);
  }

  /// Whether [modelId] is in the static shortlist / known exact map.
  static bool isKnownModel(String providerId, String modelId) {
    final m = modelId.trim();
    if (m.isEmpty || m == kLlmModelCustomId) return false;
    if (_exact[providerId]?.containsKey(m) == true) return true;
    final staticOpts = LlmModelCatalog.staticOptionsFor(providerId);
    for (final o in staticOpts) {
      if (o.id == m && o.id != kLlmModelCustomId) return true;
    }
    return false;
  }

  /// Clamp stored thinking to an allowed value (or default / null).
  static String? clampThinking(
    String providerId,
    String modelId,
    String? raw,
  ) {
    final caps = forModel(providerId, modelId);
    if (!caps.supportsThinking) return null;
    final levels = caps.thinkingLevels!;
    final t = raw?.trim();
    if (t != null && levels.contains(t)) return t;
    return caps.defaultThinking;
  }

  static int clampMaxTokens(
    String providerId,
    String modelId,
    int? raw, {
    int? liveMax,
  }) {
    final caps = forModel(providerId, modelId);
    final max = liveMax != null && liveMax > 0
        ? (liveMax < caps.maxTokensMax ? liveMax : caps.maxTokensMax)
        : caps.maxTokensMax;
    final v = raw ?? caps.maxTokensDefault;
    if (v < 256) return 256;
    if (v > max) return max;
    return v;
  }

  static LlmModelCapabilities _unknownFallback(String providerId) {
    if (providerId == GeminiProvider.providerId) {
      return const LlmModelCapabilities(
        thinkingLevels: flashThinking,
        defaultThinking: 'minimal',
        maxTokensDefault: 4000,
        maxTokensMax: 65536,
        knownInCatalog: false,
      );
    }
    return const LlmModelCapabilities(
      thinkingLevels: null,
      defaultThinking: null,
      maxTokensDefault: 4000,
      maxTokensMax: 128000,
      knownInCatalog: false,
    );
  }

  static final Map<String, Map<String, LlmModelCapabilities>> _exact = {
    GeminiProvider.providerId: {
      'gemini-3.6-flash': _geminiFlash,
      'gemini-3.5-flash': _geminiFlash,
      'gemini-3.5-flash-lite': _geminiFlash,
      'gemini-3.1-pro-preview': _geminiPro,
      'gemini-2.5-flash': _geminiFlash,
      'gemini-2.5-pro': _geminiPro,
    },
    OpenAiProvider.chatGptId: {
      'gpt-4o-mini': _tokensOnly,
      'gpt-4o': _tokensOnly,
      'gpt-4.1-mini': _tokensOnly,
      'o4-mini': _tokensOnly,
    },
    AnthropicProvider.providerId: {
      'claude-3-5-haiku-latest': _tokensOnly,
      'claude-3-haiku-20240307': _tokensOnly,
      'claude-sonnet-4-20250514': _tokensOnly,
      'claude-3-haiku': _tokensOnly,
    },
    OpenRouterProvider.providerId: {
      'google/gemini-3.5-flash': _tokensOnly,
      'perplexity/sonar': _tokensOnly,
      'moonshotai/kimi-k2.5': _tokensOnly,
      'deepseek/deepseek-v4-flash': _tokensOnly,
    },
    OpenRouterProvider.perplexityId: {
      'perplexity/sonar': _tokensOnly,
    },
    OpenRouterProvider.kimiId: {
      'moonshotai/kimi-k2.5': _tokensOnly,
    },
    OpenRouterProvider.deepseekId: {
      'deepseek/deepseek-v4-flash': _tokensOnly,
    },
  };
}
