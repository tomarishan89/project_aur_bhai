import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/config/wake_handshake_config.dart';
import 'package:project_aur_bhai/core/services/wake_model_library.dart';

void main() {
  test('catalog excludes trademark assistants', () {
    final ids = WakeHandshakeConfig.wakeCatalog.map((s) => s.id).toList();
    expect(ids, contains('hey_mycroft'));
    expect(ids, contains('hey_rhasspy'));
    expect(ids, isNot(contains('alexa')));
    expect(ids, isNot(contains('hey_jarvis')));
    expect(WakeHandshakeConfig.defaultWakeModelId, 'hey_mycroft');
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
  });

  test('bundled model cannot be deleted', () async {
    final lib = WakeModelLibrary();
    await expectLater(lib.delete('hey_mycroft'), throwsA(isA<StateError>()));
  });

  test('hey_rhasspy is downloadable not bundled', () {
    final spec = WakeHandshakeConfig.specForId('hey_rhasspy')!;
    expect(spec.bundled, isFalse);
    expect(spec.downloadUrl, isNotNull);
  });
}
