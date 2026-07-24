import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'llm_provider.dart';

/// OpenAI-compatible BYOK provider (ChatGPT + Custom OpenAI endpoints).
class OpenAiProvider extends LlmProvider {
  static const chatGptId = 'OpenAI ChatGPT';
  static const customId = 'Custom OpenAI';

  final LlmProviderConfig config;

  /// When true, [config.customUrl] is used as the chat completions endpoint.
  final bool isCustom;

  OpenAiProvider(this.config, {this.isCustom = false});

  @override
  String get id => isCustom ? customId : chatGptId;

  @override
  String get defaultModel => 'gpt-4o-mini';

  @override
  bool get requiresCustomUrl => isCustom;

  @override
  bool get supportsAudioInput => true;

  @override
  bool get prefersAudioDirect => false;

  @override
  bool get supportsTts => true;

  String get _chatCompletionsUrl {
    if (isCustom && config.customUrl.isNotEmpty) return config.customUrl;
    return 'https://api.openai.com/v1/chat/completions';
  }

  String get _transcriptionsUrl {
    if (isCustom && config.customUrl.isNotEmpty) {
      return config.customUrl.replaceAll(
        '/chat/completions',
        '/audio/transcriptions',
      );
    }
    return 'https://api.openai.com/v1/audio/transcriptions';
  }

  String get _speechUrl {
    if (isCustom && config.customUrl.isNotEmpty) {
      return config.customUrl.replaceAll('/chat/completions', '/audio/speech');
    }
    return 'https://api.openai.com/v1/audio/speech';
  }

  @override
  Future<String> complete({
    required String prompt,
    bool jsonMode = false,
    Duration timeout = const Duration(seconds: 20),
    int maxTokens = 4000,
  }) async {
    final url = Uri.parse(_chatCompletionsUrl);
    final response = await http
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${config.apiKey}',
          },
          body: jsonEncode({
            'model': config.model,
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
            'max_tokens': maxTokens,
            if (jsonMode) 'response_format': {'type': 'json_object'},
          }),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw Exception('OpenAI status ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['choices'][0]['message']['content'] as String;
  }

  @override
  Future<String> transcribe(
    File audio, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final uri = Uri.parse(_transcriptionsUrl);
    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll({'Authorization': 'Bearer ${config.apiKey}'})
      ..fields['model'] = 'whisper-1'
      ..files.add(await http.MultipartFile.fromPath('file', audio.path));

    final response = await request.send().timeout(timeout);
    if (response.statusCode != 200) {
      throw Exception('Whisper status ${response.statusCode}');
    }
    final respStr = await response.stream.bytesToString();
    final decoded = jsonDecode(respStr) as Map<String, dynamic>;
    return decoded['text'] as String;
  }

  @override
  Future<List<int>> synthesizeSpeech({
    required String text,
    required String voice,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final uri = Uri.parse(_speechUrl);
    final response = await http
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer ${config.apiKey}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': 'tts-1',
            'input': text,
            'voice': voice,
            'response_format': 'aac',
          }),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw Exception('OpenAI TTS status ${response.statusCode}');
    }
    return response.bodyBytes;
  }
}
