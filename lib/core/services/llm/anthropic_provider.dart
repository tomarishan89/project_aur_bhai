import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_provider.dart';

/// Anthropic Claude BYOK provider — text completion only.
class AnthropicProvider extends LlmProvider {
  static const providerId = 'Anthropic Claude';

  final LlmProviderConfig config;

  AnthropicProvider(this.config);

  @override
  String get id => providerId;

  @override
  String get defaultModel => 'claude-3-haiku';

  @override
  bool get requiresCustomUrl => false;

  @override
  bool get supportsAudioInput => false;

  @override
  bool get prefersAudioDirect => false;

  @override
  bool get supportsTts => false;

  @override
  Future<String> complete({
    required String prompt,
    bool jsonMode = false,
    Duration timeout = const Duration(seconds: 20),
    int maxTokens = 4000,
  }) async {
    final url = Uri.parse('https://api.anthropic.com/v1/messages');
    final response = await http.post(
      url,
      headers: {
        'x-api-key': config.apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': config.model,
        'max_tokens': maxTokens,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      }),
    ).timeout(timeout);

    if (response.statusCode != 200) {
      throw Exception('Anthropic status ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['content'][0]['text'] as String;
  }
}
