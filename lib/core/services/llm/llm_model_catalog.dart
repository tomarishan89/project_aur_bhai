import 'anthropic_provider.dart';
import 'gemini_provider.dart';
import 'openai_provider.dart';
import 'openrouter_provider.dart';

/// One selectable model in Settings.
class LlmModelOption {
  final String id;
  final String label;

  const LlmModelOption({required this.id, required this.label});
}

const kLlmModelCustomId = '__custom__';

/// Static shortlists for direct providers + helpers for deprecated migration.
class LlmModelCatalog {
  LlmModelCatalog._();

  static const customOption = LlmModelOption(
    id: kLlmModelCustomId,
    label: 'Custom…',
  );

  static List<LlmModelOption> staticOptionsFor(String providerId) {
    switch (providerId) {
      case GeminiProvider.providerId:
        return const [
          LlmModelOption(id: 'gemini-3.6-flash', label: 'Gemini 3.6 Flash'),
          LlmModelOption(id: 'gemini-3.5-flash', label: 'Gemini 3.5 Flash'),
          LlmModelOption(
            id: 'gemini-3.5-flash-lite',
            label: 'Gemini 3.5 Flash-Lite',
          ),
          LlmModelOption(
            id: 'gemini-3.1-pro-preview',
            label: 'Gemini 3.1 Pro (preview)',
          ),
          LlmModelOption(id: 'gemini-2.5-flash', label: 'Gemini 2.5 Flash'),
          LlmModelOption(id: 'gemini-2.5-pro', label: 'Gemini 2.5 Pro'),
          customOption,
        ];
      case OpenAiProvider.chatGptId:
        return const [
          LlmModelOption(id: 'gpt-4o-mini', label: 'GPT-4o mini'),
          LlmModelOption(id: 'gpt-4o', label: 'GPT-4o'),
          LlmModelOption(id: 'gpt-4.1-mini', label: 'GPT-4.1 mini'),
          LlmModelOption(id: 'o4-mini', label: 'o4-mini'),
          customOption,
        ];
      case AnthropicProvider.providerId:
        return const [
          LlmModelOption(
            id: 'claude-3-5-haiku-latest',
            label: 'Claude 3.5 Haiku',
          ),
          LlmModelOption(id: 'claude-3-haiku-20240307', label: 'Claude 3 Haiku'),
          LlmModelOption(
            id: 'claude-sonnet-4-20250514',
            label: 'Claude Sonnet 4',
          ),
          customOption,
        ];
      case OpenAiProvider.customId:
        return const [customOption];
      default:
        // OpenRouter-backed: live list fills options; always keep Custom.
        return const [customOption];
    }
  }

  static bool usesLiveOpenRouterList(String providerId) =>
      openRouterBackedProvider(providerId);

  static String? vendorPrefixFor(String providerId) {
    switch (providerId) {
      case OpenRouterProvider.perplexityId:
        return 'perplexity/';
      case OpenRouterProvider.kimiId:
        return 'moonshotai/';
      case OpenRouterProvider.deepseekId:
        return 'deepseek/';
      case OpenRouterProvider.providerId:
        return null;
      default:
        return null;
    }
  }

  /// Returns replacement model id if [modelId] is known-deprecated.
  static String? migrateDeprecated(String providerId, String modelId) {
    final m = modelId.trim();
    if (m.isEmpty) return null;
    const deadGemini = {
      'gemini-2.0-flash',
      'gemini-2.0-flash-001',
      'gemini-2.0-flash-lite',
      'gemini-1.5-flash',
      'gemini-1.5-flash-latest',
      'gemini-1.5-pro',
      'gemini-1.5-pro-latest',
      'gemini-pro',
    };
    if (providerId == GeminiProvider.providerId && deadGemini.contains(m)) {
      return GeminiProvider.defaultModelId;
    }
    return null;
  }

  /// Dropdown value: catalog id or [kLlmModelCustomId].
  static String selectionFor(String providerId, String currentModel) {
    final options = staticOptionsFor(providerId);
    for (final o in options) {
      if (o.id == currentModel) return o.id;
    }
    if (currentModel.trim().isEmpty) {
      return options.firstWhere((o) => o.id != kLlmModelCustomId, orElse: () => customOption).id;
    }
    return kLlmModelCustomId;
  }
}
