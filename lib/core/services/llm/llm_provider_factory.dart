import '../byok_service.dart';
import 'anthropic_provider.dart';
import 'gemini_provider.dart';
import 'llm_provider.dart';
import 'llm_slot.dart';
import 'openai_provider.dart';
import 'openrouter_provider.dart';

/// Single source of truth for registered BYOK providers (MS-LLM-AGNOSTIC).
class LlmProviderFactory {
  LlmProviderFactory._();

  /// All provider ids shown in the Settings dropdown, in display order.
  static const List<String> providerIds = [
    GeminiProvider.providerId,
    OpenAiProvider.chatGptId,
    AnthropicProvider.providerId,
    OpenRouterProvider.providerId,
    OpenRouterProvider.perplexityId,
    OpenRouterProvider.kimiId,
    OpenRouterProvider.deepseekId,
    OpenAiProvider.customId,
  ];

  /// Builds a concrete [LlmProvider] from the active [ByokService] config.
  static LlmProvider forConfig(
    ByokService byok, {
    LlmSlot slot = LlmSlot.defaultSlot,
  }) {
    final slotCfg = byok.configForSlot(slot);
    final config = LlmProviderConfig(
      apiKey: slotCfg.apiKey,
      model: slotCfg.modelName,
      customUrl: slotCfg.customUrl,
      thinkingLevel: slotCfg.thinkingLevel,
      maxOutputTokens: slotCfg.maxOutputTokens,
    );
    return forProviderId(slotCfg.provider, config);
  }

  /// Builds a provider by its Settings dropdown id (useful for UI defaults).
  static LlmProvider forProviderId(
    String providerId,
    LlmProviderConfig config,
  ) {
    switch (providerId) {
      case GeminiProvider.providerId:
        return GeminiProvider(config);
      case OpenAiProvider.chatGptId:
        return OpenAiProvider(config);
      case OpenAiProvider.customId:
        return OpenAiProvider(config, isCustom: true);
      case AnthropicProvider.providerId:
        return AnthropicProvider(config);
      case OpenRouterProvider.providerId:
        return OpenRouterProvider(config);
      case OpenRouterProvider.perplexityId:
        return OpenRouterProvider(
          config,
          displayId: OpenRouterProvider.perplexityId,
          vendorPrefix: 'perplexity/',
        );
      case OpenRouterProvider.kimiId:
        return OpenRouterProvider(
          config,
          displayId: OpenRouterProvider.kimiId,
          vendorPrefix: 'moonshotai/',
        );
      case OpenRouterProvider.deepseekId:
        return OpenRouterProvider(
          config,
          displayId: OpenRouterProvider.deepseekId,
          vendorPrefix: 'deepseek/',
        );
      default:
        throw ArgumentError('Unknown LLM provider: $providerId');
    }
  }

  /// Default model name for a provider id (Settings dropdown helper).
  static String defaultModelFor(String providerId) {
    return forProviderId(
      providerId,
      const LlmProviderConfig(apiKey: '', model: ''),
    ).defaultModel;
  }

  /// Whether the Settings UI should show a custom URL field.
  static bool requiresCustomUrl(String providerId) {
    return forProviderId(
      providerId,
      const LlmProviderConfig(apiKey: '', model: ''),
    ).requiresCustomUrl;
  }

  /// Hint under the API key field.
  static String apiKeyHint(String providerId) {
    if (openRouterBackedProvider(providerId)) {
      return 'OpenRouter API key (openrouter.ai)';
    }
    switch (providerId) {
      case GeminiProvider.providerId:
        return 'Google AI Studio / Gemini API key';
      case OpenAiProvider.chatGptId:
        return 'OpenAI API key';
      case AnthropicProvider.providerId:
        return 'Anthropic API key';
      case OpenAiProvider.customId:
        return 'Provider API key';
      default:
        return 'API key';
    }
  }

  /// Whether voice/mic command audio can be sent to this provider.
  static bool supportsVoiceAudio(String providerId) {
    return forProviderId(
      providerId,
      const LlmProviderConfig(apiKey: '', model: ''),
    ).supportsAudioInput;
  }

  /// Non-null when Settings should warn about provider limits.
  static String? capabilityNotice(String providerId) {
    if (supportsVoiceAudio(providerId)) return null;
    if (openRouterBackedProvider(providerId)) {
      return 'Voice commands need Gemini or OpenAI. '
          '$providerId (via OpenRouter) is text-only — spoken “Hey Mycroft” '
          'turns will not work with this as the Language/default provider. '
          'Use text, or turn on per-function slots and set Language to Gemini/OpenAI.';
    }
    if (providerId == AnthropicProvider.providerId) {
      return 'Voice commands need Gemini or OpenAI. '
          'Anthropic is text-only — spoken turns will not work with this as '
          'the Language/default provider.';
    }
    if (providerId == OpenAiProvider.customId) {
      return 'Custom OpenAI endpoints may not support voice. '
          'If spoken commands fail, use Gemini or OpenAI ChatGPT for Language.';
    }
    return 'This provider may not support voice audio. '
        'Use Gemini or OpenAI for spoken commands.';
  }
}
