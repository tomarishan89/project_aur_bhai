import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/js_agent_registry.dart';
import 'package:project_aur_bhai/core/services/model_studio/ambient_capture_service.dart';
import 'package:project_aur_bhai/core/services/model_studio/bro_code_ml_meta.dart';
import 'package:project_aur_bhai/core/services/model_studio/fine_telemetry_buffer.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('fine buffer compresses and ambient confirm/reject', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(telemetryBusProvider).initialize();
    final ambient = container.read(ambientCaptureProvider);

    for (var i = 0; i < 3; i++) {
      ambient.ingestSample(
        latitude: 12.9716 + i * 0.0001,
        longitude: 77.5946,
        accelerometerZ: 9.8 + i,
        compassDirection: 10,
      );
    }
    expect(ambient.buffer.length, 3);
    final encoded = ambient.buffer.encodeSnapshot();
    expect(encoded.startsWith('['), isTrue);

    final cand = await ambient.propose(
      agentName: 'PotholeProbe',
      proposedLabel: 'positive',
    );
    expect(ambient.pending.length, 1);
    await ambient.decide(cand.id, confirm: true);
    expect(ambient.pending, isEmpty);
  });

  test('ML meta merge + persist on schema', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final bus = container.read(telemetryBusProvider);
    await bus.initialize();
    final registry = container.read(jsAgentRegistryProvider);

    const name = 'MlMetaAgent';
    await bus.writeVaultData(
      registry.vaultKeyFor(name),
      'async function execute(p){ return "ok"; }',
      mimeType: 'application/javascript',
    );
    await bus.writeVaultData(
      registry.schemaKeyFor(name),
      '{"name":"MlMetaAgent","securityClass":"C4"}',
      mimeType: 'application/json',
    );

    final meta = BroCodeMlMeta(
      usesModel: true,
      maturity: 'collecting',
      labelSchema: const {
        'labels': ['positive', 'negative'],
      },
      capturePolicy: const {'mode': 'ambient'},
      fineWindow: const Duration(seconds: 45),
    );
    expect(await registry.updateMlMeta(name, meta), isTrue);
    final loaded = await registry.readMlMeta(name);
    expect(loaded?.usesModel, isTrue);
    expect(loaded?.maturity, 'collecting');

    final merged = BroCodeMlMeta.mergeIntoSchema({'name': name}, meta);
    expect(merged['ml'], isA<Map>());
  });

  test('fine buffer window trims old samples', () {
    final buf = FineTelemetryBuffer(window: const Duration(seconds: 1));
    buf.push(FineTelemetrySample(
      at: DateTime.now().toUtc().subtract(const Duration(seconds: 5)),
      latitude: 1,
      longitude: 2,
      accelerometerZ: 3,
      compassDirection: 4,
    ));
    buf.push(FineTelemetrySample(
      at: DateTime.now().toUtc(),
      latitude: 1,
      longitude: 2,
      accelerometerZ: 3,
      compassDirection: 4,
    ));
    expect(buf.length, 1);
  });
}
