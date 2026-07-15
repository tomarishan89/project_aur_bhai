import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'llm_provider.dart';

/// Google Gemini BYOK provider.
///
/// Supports audio-direct multimodal intent parsing (manifest §2.3) and
/// text completion with optional JSON mode. No TTS.
class GeminiProvider extends LlmProvider {
  static const providerId = 'Google Gemini';

  final LlmProviderConfig config;

  GeminiProvider(this.config);

  @override
  String get id => providerId;

  @override
  String get defaultModel => 'gemini-2.0-flash';

  @override
  bool get requiresCustomUrl => false;

  @override
  bool get supportsAudioInput => true;

  @override
  bool get prefersAudioDirect => true;

  @override
  bool get supportsTts => false;

  @override
  Future<String> complete({
    required String prompt,
    bool jsonMode = false,
    Duration timeout = const Duration(seconds: 20),
    int maxTokens = 4000,
  }) async {
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/${config.model}:generateContent?key=${config.apiKey}',
    );
    final response = await http.post(
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
        'generationConfig': {
          'maxOutputTokens': maxTokens,
          if (jsonMode) 'responseMimeType': 'application/json',
        },
      }),
    ).timeout(timeout);

    if (response.statusCode != 200) {
      throw Exception('Gemini status ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['candidates'][0]['content']['parts'][0]['text'] as String;
  }

  @override
  Future<String> completeChat({
    required List<LlmChatMessage> messages,
    bool jsonMode = false,
    Duration timeout = const Duration(seconds: 20),
    int maxTokens = 4000,
  }) async {
    final contents = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = (m.role == 'assistant' || m.role == 'model') ? 'model' : 'user';
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
    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': contents,
        'generationConfig': {
          'maxOutputTokens': maxTokens,
          if (jsonMode) 'responseMimeType': 'application/json',
        },
      }),
    ).timeout(timeout);

    if (response.statusCode != 200) {
      throw Exception('Gemini status ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['candidates'][0]['content']['parts'][0]['text'] as String;
  }

  @override
  Future<String> completeWithAudio({
    required String prompt,
    required File audio,
    bool jsonMode = false,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final bytes = await audio.readAsBytes();
    final base64Audio = base64Encode(bytes);

    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/${config.model}:generateContent?key=${config.apiKey}',
    );
    final response = await http.post(
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
        if (jsonMode)
          'generationConfig': {'responseMimeType': 'application/json'},
      }),
    ).timeout(timeout);

    if (response.statusCode != 200) {
      throw Exception('Gemini audio status ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['candidates'][0]['content']['parts'][0]['text'] as String;
  }
}
