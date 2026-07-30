import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/llm/gemini_provider.dart';
import 'package:project_aur_bhai/core/services/llm/llm_capability_catalog.dart';
import 'package:project_aur_bhai/core/services/llm/openai_provider.dart';

void main() {
  group('LlmCapabilityCatalog', () {
    test('Gemini Flash allows minimal; Pro does not', () {
      final flash = LlmCapabilityCatalog.forModel(
        GeminiProvider.providerId,
        'gemini-3.5-flash',
      );
      expect(flash.thinkingLevels, contains('minimal'));
      expect(flash.defaultThinking, 'minimal');

      final pro = LlmCapabilityCatalog.forModel(
        GeminiProvider.providerId,
        'gemini-3.1-pro-preview',
      );
      expect(pro.thinkingLevels, isNot(contains('minimal')));
      expect(pro.defaultThinking, 'low');
    });

    test('clampThinking rejects minimal on Pro', () {
      expect(
        LlmCapabilityCatalog.clampThinking(
          GeminiProvider.providerId,
          'gemini-3.1-pro-preview',
          'minimal',
        ),
        'low',
      );
    });

    test('OpenAI has no thinking levels', () {
      final caps = LlmCapabilityCatalog.forModel(
        OpenAiProvider.chatGptId,
        'gpt-4o-mini',
      );
      expect(caps.supportsThinking, isFalse);
      expect(
        LlmCapabilityCatalog.clampThinking(
          OpenAiProvider.chatGptId,
          'gpt-4o-mini',
          'low',
        ),
        isNull,
      );
    });

    test('unknown Gemini model uses live/custom fallback with thinking', () {
      expect(
        LlmCapabilityCatalog.isKnownModel(
          GeminiProvider.providerId,
          'gemini-weird-custom',
        ),
        isFalse,
      );
      final caps = LlmCapabilityCatalog.forModel(
        GeminiProvider.providerId,
        'gemini-weird-custom',
      );
      expect(caps.knownInCatalog, isFalse);
      expect(caps.supportsThinking, isTrue);
    });
  });
}
