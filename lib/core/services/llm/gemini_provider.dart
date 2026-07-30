import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'llm_capability_catalog.dart';
import 'llm_http_errors.dart';
import 'llm_provider.dart';

/// Google Gemini BYOK provider.
///
/// Supports audio-direct multimodal intent parsing (manifest §2.3) and
/// text completion with optional JSON mode. No TTS.
class GeminiProvider extends LlmProvider {
  static const providerId = 'Google Gemini';
  static const defaultModelId = 'gemini-3.5-flash';

  final LlmProviderConfig config;

  GeminiProvider(this.config);

  @override
  String get id => providerId;

  @override
  String get defaultModel => defaultModelId;

  @override
  bool get requiresCustomUrl => false;

  @override
  bool get supportsAudioInput => true;

  @override
  bool get prefersAudioDirect => true;

  @override
  bool get supportsTts => false;

  String get _thinkingLevel =>
      LlmCapabilityCatalog.clampThinking(
        providerId,
        config.model,
        config.thinkingLevel,
      ) ??
      LlmCapabilityCatalog.forModel(providerId, config.model).defaultThinking ??
      'minimal';

  int _effectiveMaxTokens(int maxTokens) =>
      config.maxOutputTokens ?? maxTokens;

  Map<String, dynamic> _generationConfig({
    required int maxTokens,
    required bool jsonMode,
  }) {
    final thinking = _thinkingLevel;
    return {
      'maxOutputTokens': _effectiveMaxTokens(maxTokens),
      if (jsonMode) 'responseMimeType': 'application/json',
      'thinkingConfig': {'thinkingLevel': thinking},
    };
  }

  @override
  Future<String> complete({
    required String prompt,
    bool jsonMode = false,
    Duration timeout = const Duration(seconds: 45),
    int maxTokens = 4000,
  }) async {
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/${config.model}:generateContent?key=${config.apiKey}',
    );
    final response = await http
        .post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': prompt},
                ],
              },
            ],
            'generationConfig': _generationConfig(
              maxTokens: maxTokens,
              jsonMode: jsonMode,
            ),
          }),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw Exception(llmHttpError('Gemini', response));
    }

    final bodyStr = response.body;
    if (bodyStr.trim().isEmpty) {
      throw Exception('Gemini returned an empty response');
    }

    final data = jsonDecode(bodyStr) as Map<String, dynamic>;

    if (!data.containsKey('candidates') ||
        (data['candidates'] as List).isEmpty) {
      throw Exception(
        'Gemini returned no candidates. Body: ${bodyStr.length > 100 ? bodyStr.substring(0, 100) : bodyStr}',
      );
    }

    return data['candidates'][0]['content']['parts'][0]['text'] as String;
  }

  @override
  Future<String> completeChat({
    required List<LlmChatMessage> messages,
    bool jsonMode = false,
    Duration timeout = const Duration(seconds: 45),
    int maxTokens = 4000,
  }) async {
    final contents = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = (m.role == 'assistant' || m.role == 'model')
          ? 'model'
          : 'user';
      contents.add({
        'role': role,
        'parts': [
          {'text': m.content},
        ],
      });
    }
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/${config.model}:generateContent?key=${config.apiKey}',
    );
    final response = await http
        .post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': contents,
            'generationConfig': _generationConfig(
              maxTokens: maxTokens,
              jsonMode: jsonMode,
            ),
          }),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw Exception(llmHttpError('Gemini', response));
    }

    final bodyStr = response.body;
    if (bodyStr.trim().isEmpty) {
      throw Exception('Gemini returned an empty response');
    }

    final data = jsonDecode(bodyStr) as Map<String, dynamic>;
    if (!data.containsKey('candidates') ||
        (data['candidates'] as List).isEmpty) {
      throw Exception(
        'Gemini returned no candidates. Body: ${bodyStr.length > 100 ? bodyStr.substring(0, 100) : bodyStr}',
      );
    }

    return data['candidates'][0]['content']['parts'][0]['text'] as String;
  }

  @override
  Future<String> completeWithAudio({
    required String prompt,
    required File audio,
    bool jsonMode = false,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final bytes = await audio.readAsBytes();
    final base64Audio = base64Encode(bytes);

    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/${config.model}:generateContent?key=${config.apiKey}',
    );
    final response = await http
        .post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': prompt},
                  {
                    'inlineData': {
                      'mimeType': 'audio/mp4',
                      'data': base64Audio,
                    },
                  },
                ],
              },
            ],
            'generationConfig': {
              if (jsonMode) 'responseMimeType': 'application/json',
              'thinkingConfig': {'thinkingLevel': _thinkingLevel},
            },
          }),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw Exception(llmHttpError('Gemini audio', response));
    }

    final bodyStr = response.body;
    if (bodyStr.trim().isEmpty) {
      throw Exception('Gemini returned an empty response');
    }

    final data = jsonDecode(bodyStr) as Map<String, dynamic>;
    if (!data.containsKey('candidates') ||
        (data['candidates'] as List).isEmpty) {
      throw Exception(
        'Gemini returned no candidates. Body: ${bodyStr.length > 100 ? bodyStr.substring(0, 100) : bodyStr}',
      );
    }
    return data['candidates'][0]['content']['parts'][0]['text'] as String;
  }
}
