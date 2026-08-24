import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/config/app_config.dart';
import 'package:project_aur_bhai/core/config/wake_handshake_config.dart';
import 'package:project_aur_bhai/core/services/byok_service.dart';
import 'package:project_aur_bhai/core/services/default_mere_bhai.dart';
import 'package:project_aur_bhai/core/services/llm_service.dart';
import 'package:project_aur_bhai/core/services/secure_secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('tap ack migrates from legacy responseMode', () async {
    SharedPreferences.setMockInitialValues({'byok_resp_mode': 'System Sound'});
    final byok = ByokService(secretStore: MemorySecureSecretStore());
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(byok.tapResponseMode, WakeHandshakeConfig.tapSound);
    expect(byok.holdResponseMode, WakeHandshakeConfig.holdHaptic);
  });

  test('updateConfig persists tap and hold independently', () async {
    final byok = ByokService(secretStore: MemorySecureSecretStore());
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await byok.updateConfig(
      provider: 'Google Gemini',
      apiKey: '',
      modelName: 'gemini-2.0-flash',
      customUrl: '',
      tapResponseMode: WakeHandshakeConfig.tapSpoken,
      holdResponseMode: WakeHandshakeConfig.holdBeep,
      responseWord: 'Haan bhai',
    );
    expect(byok.tapResponseMode, WakeHandshakeConfig.tapSpoken);
    expect(byok.holdResponseMode, WakeHandshakeConfig.holdBeep);
    expect(byok.responseMode, byok.tapResponseMode);
  });

  test('free wake catalog prefers Jarvis and excludes Alexa', () {
    final ids = WakeHandshakeConfig.wakeCatalog.map((s) => s.id).toList();
    expect(ids.first, 'hey_jarvis');
    expect(ids, contains('hey_rhasspy'));
    expect(ids, contains('hey_mycroft'));
    expect(ids, isNot(contains('alexa')));
    expect(WakeHandshakeConfig.defaultWakeModelId, 'hey_jarvis');
    expect(AppConfig.wakeWordInterimBuiltIn, 'Hey Jarvis');
  });

  test('hold ack modes never include Spoken Word', () {
    expect(
      WakeHandshakeConfig.holdAckModes,
      isNot(contains(WakeHandshakeConfig.tapSpoken)),
    );
  });

  test('media controls to Aur Bhai defaults on and round-trips', () async {
    final byok = ByokService(secretStore: MemorySecureSecretStore());
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(byok.mediaControlsToAurBhai, isTrue);

    await byok.setMediaControlsToAurBhai(false);
    expect(byok.mediaControlsToAurBhai, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('media_controls_to_aur_bhai'), isFalse);

    final byok2 = ByokService(secretStore: MemorySecureSecretStore());
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(byok2.mediaControlsToAurBhai, isFalse);

    await byok2.setMediaControlsToAurBhai(true);
    expect(byok2.mediaControlsToAurBhai, isTrue);
  });

  test('default Mere Bhai text prefix and turn routing', () async {
    final svc = DefaultMereBhaiService();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await svc.setDefault('Locator');

    expect(svc.applyTextPrefix('show map'), 'Ask Locator: show map');
    expect(svc.applyTextPrefix('Ask Calculator: 2+2'), 'Ask Calculator: 2+2');
    expect(
      DefaultMereBhaiService.hasExplicitAskTell('Tell Locator hi'),
      isTrue,
    );

    final direct = TurnParsedResponse(
      intent: AgentIntent.direct,
      transcription: 'show map',
      confirmation: 'ok',
    );
    final routed = svc.applyToTurn(direct);
    expect(routed.intent, AgentIntent.execute);
    expect(routed.targetAgent, 'Locator');

    final author = TurnParsedResponse(
      intent: AgentIntent.author,
      transcription: 'build a timer',
      confirmation: 'ok',
    );
    expect(svc.applyToTurn(author).intent, AgentIntent.author);
  });
}
