import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/byok_service.dart';
import 'package:project_aur_bhai/core/services/secure_secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('migrates plaintext API key from SharedPreferences to secure store',
      () async {
    SharedPreferences.setMockInitialValues({
      'byok_provider': 'Google Gemini',
      'byok_api_key': 'legacy-secret-key',
      'byok_model_name': 'gemini-2.0-flash',
    });

    final store = MemorySecureSecretStore();
    final byok = ByokService(secretStore: store);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(byok.isLoaded, isTrue);
    expect(byok.apiKey, 'legacy-secret-key');
    expect(await store.read('byok_api_key'), 'legacy-secret-key');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('byok_api_key'), isNull);
    expect(prefs.getBool('byok_secrets_migrated_v1'), isTrue);
  });

  test('updateConfig never writes API key to SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({});
    final store = MemorySecureSecretStore();
    final byok = ByokService(secretStore: store);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await byok.updateConfig(
      provider: 'OpenAI',
      apiKey: 'sk-test',
      modelName: 'gpt-4o',
      customUrl: '',
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('byok_api_key'), isNull);
    expect(await store.read('byok_api_key'), 'sk-test');
    expect(byok.apiKey, 'sk-test');
  });
}
