import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_http_errors.dart';
import 'llm_provider.dart';

/// OpenRouter OpenAI-compatible chat provider.
///
/// Also used for Perplexity / Kimi / DeepSeek presets (same API key + endpoint;
/// model IDs are OpenRouter slugs like `perplexity/sonar`).
class OpenRouterProvider extends LlmProvider {
  static const providerId = 'OpenRouter';
  static const perplexityId = 'Perplexity';
  static const kimiId = 'Kimi';
  static const deepseekId = 'DeepSeek';

  static const chatCompletionsUrl =
      'https://openrouter.ai/api/v1/chat/completions';
  static const modelsUrl = 'https://openrouter.ai/api/v1/models';

  final LlmProviderConfig config;

  /// Settings dropdown label.
  final String displayId;

  /// When set, model pickers filter to this OpenRouter id prefix.
  final String? vendorPrefix;

  OpenRouterProvider(
    this.config, {
    this.displayId = providerId,
    this.vendorPrefix,
  });

  @override
  String get id => displayId;

  @override
  String get defaultModel {
    switch (displayId) {
      case perplexityId:
        return 'perplexity/sonar';
      case kimiId:
        return 'moonshotai/kimi-k2.5';
      case deepseekId:
        return 'deepseek/deepseek-v4-flash';
      default:
        return 'google/gemini-3.5-flash';
    }
  }

  @override
  bool get requiresCustomUrl => false;

  @override
  bool get supportsAudioInput => false;

  @override
  bool get prefersAudioDirect => false;

  @override
  bool get supportsTts => false;

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer ${config.apiKey}',
    'HTTP-Referer': 'https://aur-bhai.app',
    'X-Title': 'Aur Bhai',
  };

  @override
  Future<String> complete({
    required String prompt,
    bool jsonMode = false,
    Duration timeout = const Duration(seconds: 20),
    int maxTokens = 4000,
  }) async {
    final response = await http
        .post(
          Uri.parse(chatCompletionsUrl),
          headers: _headers,
          body: jsonEncode({
            'model': config.model,
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
            'max_tokens': config.maxOutputTokens ?? maxTokens,
            if (jsonMode) 'response_format': {'type': 'json_object'},
          }),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw Exception(llmHttpError('OpenRouter', response));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['choices'][0]['message']['content'] as String;
  }

  @override
  Future<String> completeChat({
    required List<LlmChatMessage> messages,
    bool jsonMode = false,
    Duration timeout = const Duration(seconds: 20),
    int maxTokens = 4000,
  }) async {
    final mapped = messages
        .map(
          (m) => {
            'role': (m.role == 'model') ? 'assistant' : m.role,
            'content': m.content,
          },
        )
        .toList();
    final response = await http
        .post(
          Uri.parse(chatCompletionsUrl),
          headers: _headers,
          body: jsonEncode({
            'model': config.model,
            'messages': mapped,
            'max_tokens': config.maxOutputTokens ?? maxTokens,
            if (jsonMode) 'response_format': {'type': 'json_object'},
          }),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw Exception(llmHttpError('OpenRouter', response));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['choices'][0]['message']['content'] as String;
  }
}

/// True when Settings should prompt for an OpenRouter API key.
bool openRouterBackedProvider(String providerId) {
  return providerId == OpenRouterProvider.providerId ||
      providerId == OpenRouterProvider.perplexityId ||
      providerId == OpenRouterProvider.kimiId ||
      providerId == OpenRouterProvider.deepseekId;
}
