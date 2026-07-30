import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/llm/anthropic_provider.dart';
import 'package:project_aur_bhai/core/services/llm/gemini_provider.dart';
import 'package:project_aur_bhai/core/services/llm/llm_model_catalog.dart';
import 'package:project_aur_bhai/core/services/llm/llm_provider.dart';
import 'package:project_aur_bhai/core/services/llm/llm_provider_factory.dart';
import 'package:project_aur_bhai/core/services/llm/openai_provider.dart';
import 'package:project_aur_bhai/core/services/llm/openrouter_provider.dart';

const _dummyConfig = LlmProviderConfig(apiKey: 'test-key', model: 'test-model');

void main() {
  group('MS-LLM-AGNOSTIC — LlmProviderFactory', () {
    test('providerIds lists registered providers', () {
      expect(LlmProviderFactory.providerIds, [
        GeminiProvider.providerId,
        OpenAiProvider.chatGptId,
        AnthropicProvider.providerId,
        OpenRouterProvider.providerId,
        OpenRouterProvider.perplexityId,
        OpenRouterProvider.kimiId,
        OpenRouterProvider.deepseekId,
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
      expect(
        LlmProviderFactory.forProviderId(
          OpenRouterProvider.providerId,
          _dummyConfig,
        ),
        isA<OpenRouterProvider>(),
      );
      expect(
        LlmProviderFactory.forProviderId(
          OpenRouterProvider.perplexityId,
          _dummyConfig,
        ),
        isA<OpenRouterProvider>(),
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
        GeminiProvider.defaultModelId,
      );
      expect(
        LlmProviderFactory.defaultModelFor(OpenAiProvider.chatGptId),
        'gpt-4o-mini',
      );
      expect(
        LlmProviderFactory.defaultModelFor(AnthropicProvider.providerId),
        'claude-3-haiku',
      );
      expect(
        LlmProviderFactory.defaultModelFor(OpenRouterProvider.providerId),
        'google/gemini-3.5-flash',
      );
      expect(
        LlmProviderFactory.defaultModelFor(OpenRouterProvider.perplexityId),
        'perplexity/sonar',
      );
    });

    test('requiresCustomUrl only for Custom OpenAI', () {
      expect(
        LlmProviderFactory.requiresCustomUrl(GeminiProvider.providerId),
        false,
      );
      expect(
        LlmProviderFactory.requiresCustomUrl(OpenRouterProvider.providerId),
        false,
      );
      expect(
        LlmProviderFactory.requiresCustomUrl(OpenAiProvider.customId),
        true,
      );
    });

    test('migrateDeprecated upgrades old Gemini ids', () {
      expect(
        LlmModelCatalog.migrateDeprecated(
          GeminiProvider.providerId,
          'gemini-2.0-flash',
        ),
        GeminiProvider.defaultModelId,
      );
      expect(
        LlmModelCatalog.migrateDeprecated(
          GeminiProvider.providerId,
          'gemini-3.5-flash',
        ),
        isNull,
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

    test('OpenRouter: text only', () {
      final p = OpenRouterProvider(_dummyConfig);
      expect(p.supportsAudioInput, false);
      expect(p.supportsTts, false);
      expect(openRouterBackedProvider(OpenRouterProvider.kimiId), true);
    });

    test('capabilityNotice warns when voice audio unsupported', () {
      expect(
        LlmProviderFactory.capabilityNotice(GeminiProvider.providerId),
        isNull,
      );
      expect(
        LlmProviderFactory.capabilityNotice(OpenAiProvider.chatGptId),
        isNull,
      );
      final or = LlmProviderFactory.capabilityNotice(
        OpenRouterProvider.providerId,
      );
      expect(or, isNotNull);
      expect(or!, contains('Voice commands'));
      expect(or, contains('text-only'));
      final anth = LlmProviderFactory.capabilityNotice(
        AnthropicProvider.providerId,
      );
      expect(anth, isNotNull);
      expect(anth!, contains('Anthropic'));
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
