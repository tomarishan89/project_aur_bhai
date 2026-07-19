import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/byok_service.dart';
import 'package:project_aur_bhai/core/services/llm/llm_provider_factory.dart';
import 'package:project_aur_bhai/core/services/llm/llm_slot.dart';
import 'package:project_aur_bhai/core/services/secure_secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('single-provider mode ignores dedicated slots', () async {
    final byok = ByokService(secretStore: MemorySecureSecretStore());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await byok.updateConfig(
      provider: 'Google Gemini',
      apiKey: 'default-key',
      modelName: 'gemini-2.0-flash',
      customUrl: '',
    );
    await byok.setMultiSlotEnabled(false);
    await byok.updateSlot(
      LlmSlot.author,
      const ByokSlotConfig(
        provider: 'Anthropic Claude',
        apiKey: 'author-only',
        modelName: 'claude-sonnet',
      ),
    );
    // Multi-slot off → always legacy single key.
    expect(byok.configForSlot(LlmSlot.author).apiKey, 'default-key');
  });

  test('multi-slot fallback + dedicated routing', () async {
    final byok = ByokService(secretStore: MemorySecureSecretStore());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await byok.updateConfig(
      provider: 'Google Gemini',
      apiKey: 'default-key',
      modelName: 'gemini-2.0-flash',
      customUrl: '',
    );
    await byok.setMultiSlotEnabled(true);
    await byok.updateSlot(
      LlmSlot.defaultSlot,
      const ByokSlotConfig(
        provider: 'Google Gemini',
        apiKey: 'default-key',
        modelName: 'gemini-2.0-flash',
      ),
    );
    await byok.updateSlot(
      LlmSlot.improve,
      const ByokSlotConfig(
        provider: 'Anthropic Claude',
        apiKey: 'improve-key',
        modelName: 'claude-sonnet',
      ),
    );

    expect(byok.configForSlot(LlmSlot.author).apiKey, 'default-key');
    expect(byok.configForSlot(LlmSlot.improve).apiKey, 'improve-key');
    expect(byok.configForSlot(LlmSlot.improve).provider, 'Anthropic Claude');

    final improve = LlmProviderFactory.forConfig(byok, slot: LlmSlot.improve);
    final author = LlmProviderFactory.forConfig(byok, slot: LlmSlot.author);
    expect(improve.id, isNot(equals(author.id)));
  });

  test('migration seeds default slot from legacy key', () async {
    final store = MemorySecureSecretStore();
    await store.write('byok_api_key', 'legacy-secret');
    SharedPreferences.setMockInitialValues({
      'byok_provider': 'OpenAI ChatGPT',
      'byok_model_name': 'gpt-4o-mini',
      'byok_custom_url': '',
      'byok_secrets_migrated_v1': true,
    });
    final byok = ByokService(secretStore: store);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(byok.apiKey, 'legacy-secret');
    await byok.setMultiSlotEnabled(true);
    expect(byok.configForSlot(LlmSlot.defaultSlot).apiKey, 'legacy-secret');
  });
}
