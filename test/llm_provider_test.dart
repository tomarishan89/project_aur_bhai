import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/llm/anthropic_provider.dart';
import 'package:project_aur_bhai/core/services/llm/gemini_provider.dart';
import 'package:project_aur_bhai/core/services/llm/llm_provider.dart';
import 'package:project_aur_bhai/core/services/llm/llm_provider_factory.dart';
import 'package:project_aur_bhai/core/services/llm/openai_provider.dart';

const _dummyConfig = LlmProviderConfig(apiKey: 'test-key', model: 'test-model');

void main() {
  group('MS-LLM-AGNOSTIC — LlmProviderFactory', () {
    test('providerIds lists all four registered providers', () {
      expect(LlmProviderFactory.providerIds, [
        GeminiProvider.providerId,
        OpenAiProvider.chatGptId,
        AnthropicProvider.providerId,
        OpenAiProvider.customId,
      ]);
    });

    test('forProviderId returns correct concrete types', () {
      expect(
        LlmProviderFactory.forProviderId(
          GeminiProvider.providerId,
          _dummyConfig,
        ),
        isA<GeminiProvider>(),
      );
      expect(
        LlmProviderFactory.forProviderId(
          OpenAiProvider.chatGptId,
          _dummyConfig,
        ),
        isA<OpenAiProvider>(),
      );
      expect(
        LlmProviderFactory.forProviderId(OpenAiProvider.customId, _dummyConfig),
        isA<OpenAiProvider>(),
      );
      expect(
        LlmProviderFactory.forProviderId(
          AnthropicProvider.providerId,
          _dummyConfig,
        ),
        isA<AnthropicProvider>(),
      );
    });

    test('unknown provider id throws', () {
      expect(
        () => LlmProviderFactory.forProviderId('Unknown Corp', _dummyConfig),
        throwsArgumentError,
      );
    });

    test('defaultModelFor returns provider-specific defaults', () {
      expect(
        LlmProviderFactory.defaultModelFor(GeminiProvider.providerId),
        'gemini-2.0-flash',
      );
      expect(
        LlmProviderFactory.defaultModelFor(OpenAiProvider.chatGptId),
        'gpt-4o-mini',
      );
      expect(
        LlmProviderFactory.defaultModelFor(AnthropicProvider.providerId),
        'claude-3-haiku',
      );
    });

    test('requiresCustomUrl only for Custom OpenAI', () {
      expect(
        LlmProviderFactory.requiresCustomUrl(GeminiProvider.providerId),
        false,
      );
      expect(
        LlmProviderFactory.requiresCustomUrl(OpenAiProvider.chatGptId),
        false,
      );
      expect(
        LlmProviderFactory.requiresCustomUrl(AnthropicProvider.providerId),
        false,
      );
      expect(
        LlmProviderFactory.requiresCustomUrl(OpenAiProvider.customId),
        true,
      );
    });
  });

  group('MS-LLM-AGNOSTIC — capability flags', () {
    test('Gemini: audio-direct, no TTS', () {
      final p = GeminiProvider(_dummyConfig);
      expect(p.supportsAudioInput, true);
      expect(p.prefersAudioDirect, true);
      expect(p.supportsTts, false);
    });

    test('OpenAI ChatGPT: transcribe + TTS, not audio-direct', () {
      final p = OpenAiProvider(_dummyConfig);
      expect(p.supportsAudioInput, true);
      expect(p.prefersAudioDirect, false);
      expect(p.supportsTts, true);
    });

    test('Anthropic: text only', () {
      final p = AnthropicProvider(_dummyConfig);
      expect(p.supportsAudioInput, false);
      expect(p.prefersAudioDirect, false);
      expect(p.supportsTts, false);
    });
  });

  group('MS-LLM-AGNOSTIC — unsupported methods throw', () {
    test('Gemini synthesizeSpeech throws', () {
      final p = GeminiProvider(_dummyConfig);
      expect(
        () => p.synthesizeSpeech(text: 'hi', voice: 'onyx'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('Gemini transcribe throws (uses audio-direct instead)', () {
      final p = GeminiProvider(_dummyConfig);
      expect(
        () => p.transcribe(File('nonexistent.m4a')),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('Anthropic completeWithAudio throws', () {
      final p = AnthropicProvider(_dummyConfig);
      expect(
        () =>
            p.completeWithAudio(prompt: 'test', audio: File('nonexistent.m4a')),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('Anthropic transcribe throws', () {
      final p = AnthropicProvider(_dummyConfig);
      expect(
        () => p.transcribe(File('nonexistent.m4a')),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}
