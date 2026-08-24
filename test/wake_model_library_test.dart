import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/config/wake_handshake_config.dart';
import 'package:project_aur_bhai/core/services/wake_model_library.dart';

void main() {
  test('catalog order Jarvis then Rhasspy then Mycroft', () {
    final ids = WakeHandshakeConfig.wakeCatalog.map((s) => s.id).toList();
    expect(ids, ['hey_jarvis', 'hey_rhasspy', 'hey_mycroft']);
    expect(ids, isNot(contains('alexa')));
    expect(WakeHandshakeConfig.defaultWakeModelId, 'hey_jarvis');
  });

  test('normalize migrates old Porcupine ids to default', () {
    expect(
      WakeHandshakeConfig.normalizeWakeModelId('PORCUPINE'),
      WakeHandshakeConfig.defaultWakeModelId,
    );
    expect(
      WakeHandshakeConfig.normalizeWakeModelId('hey_rhasspy'),
      'hey_rhasspy',
    );
    expect(
      WakeHandshakeConfig.normalizeWakeModelId('hey_mycroft'),
      'hey_mycroft',
    );
  });

  test('bundled Jarvis cannot be deleted', () async {
    final lib = WakeModelLibrary();
    await expectLater(lib.delete('hey_jarvis'), throwsA(isA<StateError>()));
  });

  test('Rhasspy and Mycroft are downloadable not bundled', () {
    final rhasspy = WakeHandshakeConfig.specForId('hey_rhasspy')!;
    expect(rhasspy.bundled, isFalse);
    expect(rhasspy.downloadUrl, isNotNull);

    final mycroft = WakeHandshakeConfig.specForId('hey_mycroft')!;
    expect(mycroft.bundled, isFalse);
    expect(mycroft.downloadUrl, isNotNull);
    expect(mycroft.assetPath, isNull);
  });
}
