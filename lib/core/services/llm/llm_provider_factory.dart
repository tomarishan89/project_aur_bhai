import '../byok_service.dart';
import 'anthropic_provider.dart';
import 'gemini_provider.dart';
import 'llm_provider.dart';
import 'llm_slot.dart';
import 'openai_provider.dart';

/// Single source of truth for registered BYOK providers (MS-LLM-AGNOSTIC).
class LlmProviderFactory {
  LlmProviderFactory._();

  /// All provider ids shown in the Settings dropdown, in display order.
  static const List<String> providerIds = [
    GeminiProvider.providerId,
    OpenAiProvider.chatGptId,
    AnthropicProvider.providerId,
    OpenAiProvider.customId,
  ];

  /// Builds a concrete [LlmProvider] from the active [ByokService] config.
  static LlmProvider forConfig(ByokService byok, {LlmSlot slot = LlmSlot.defaultSlot}) {
    final slotCfg = byok.configForSlot(slot);
    final config = LlmProviderConfig(
      apiKey: slotCfg.apiKey,
      model: slotCfg.modelName,
      customUrl: slotCfg.customUrl,
    );
    return forProviderId(slotCfg.provider, config);
  }

  /// Builds a provider by its Settings dropdown id (useful for UI defaults).
  static LlmProvider forProviderId(String providerId, LlmProviderConfig config) {
    switch (providerId) {
      case GeminiProvider.providerId:
        return GeminiProvider(config);
      case OpenAiProvider.chatGptId:
        return OpenAiProvider(config);
      case OpenAiProvider.customId:
        return OpenAiProvider(config, isCustom: true);
      case AnthropicProvider.providerId:
        return AnthropicProvider(config);
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
}
