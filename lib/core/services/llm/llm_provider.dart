import 'dart:io';

/// Snapshot of BYOK credentials passed into a provider instance.
class LlmProviderConfig {
  final String apiKey;
  final String model;
  final String customUrl;

  const LlmProviderConfig({
    required this.apiKey,
    required this.model,
    this.customUrl = '',
  });
}

/// Abstract BYOK LLM provider (MS-LLM-AGNOSTIC).
abstract class LlmProvider {
  /// Stable identifier matching the Settings dropdown value.
  String get id;

  /// Default model name suggested when the user selects this provider.
  String get defaultModel;

  /// Whether the Settings UI should expose a custom endpoint URL field.
  bool get requiresCustomUrl;

  /// Whether this provider can accept audio input at all.
  bool get supportsAudioInput;

  /// When true, audio + prompt are sent in a single multimodal call
  /// (Gemini audio-direct per manifest §2.3). When false, audio is
  /// transcribed first and the text path is used (OpenAI Whisper).
  bool get prefersAudioDirect;

  /// Whether this provider can synthesize speech (TTS).
  bool get supportsTts;

  /// Text completion — returns raw model text.
  Future<String> complete({
    required String prompt,
    bool jsonMode = false,
    Duration timeout = const Duration(seconds: 20),
    int maxTokens = 4000,
  });

  /// Multimodal completion (audio + text prompt in one call).
  /// Only callable when [supportsAudioInput] && [prefersAudioDirect].
  Future<String> completeWithAudio({
    required String prompt,
    required File audio,
    bool jsonMode = false,
    Duration timeout = const Duration(seconds: 20),
  }) {
    throw UnsupportedError('$id does not support audio-direct completion.');
  }

  /// Transcribe audio to plain text (Whisper-style).
  /// Only callable when [supportsAudioInput] && !prefersAudioDirect].
  Future<String> transcribe(
    File audio, {
    Duration timeout = const Duration(seconds: 15),
  }) {
    throw UnsupportedError('$id does not support audio transcription.');
  }

  /// Synthesize speech bytes (e.g. AAC/M4A).
  /// Only callable when [supportsTts].
  Future<List<int>> synthesizeSpeech({
    required String text,
    required String voice,
    Duration timeout = const Duration(seconds: 20),
  }) {
    throw UnsupportedError('$id does not support text-to-speech.');
  }
}
