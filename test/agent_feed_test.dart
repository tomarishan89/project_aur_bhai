import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/agent_feed_service.dart';
import 'package:project_aur_bhai/core/services/agent_verification_service.dart';
import 'package:project_aur_bhai/core/services/js_agent_registry.dart';
import 'package:project_aur_bhai/core/services/marketplace_catalog.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('feed push / read / consume inbox', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(telemetryBusProvider).initialize();
    final feed = container.read(agentFeedServiceProvider);

    await feed.push(agentName: 'Accountant', text: 'spent 500 cash');
    await feed.push(agentName: 'Accountant', text: 'spent 50 tip');

    final unread = await feed.readInbox('Accountant', unreadOnly: true);
    expect(unread.length, 2);

    final n = await feed.consume('Accountant');
    expect(n, 2);
    expect(await feed.readInbox('Accountant', unreadOnly: true), isEmpty);
  });

  test('marketplace pickup installs at C4', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(telemetryBusProvider).initialize();
    final catalog = container.read(marketplaceCatalogProvider);
    final registry = container.read(jsAgentRegistryProvider);
    final listing = catalog.listings().firstWhere(
      (l) => l.name == 'Accountant',
    );
    // Shared FFI DB may already contain a prior pickup — make the test idempotent.
    await registry.deleteAgent('Accountant');
    expect(await catalog.pickup(listing), isTrue);
    expect(await catalog.pickup(listing), isFalse);

    final bundle = await registry.exportAgentBundle('Accountant');
    expect(bundle, isNotNull);
    expect((bundle!['schema'] as Map)['securityClass'], 'C4');
    expect((bundle['schema'] as Map)['source'], 'pool');
  });

  test('force-promote with deviceAuthenticated skips C3', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final bus = container.read(telemetryBusProvider);
    await bus.initialize();
    final registry = container.read(jsAgentRegistryProvider);
    final verification = container.read(agentVerificationProvider);

    const name = 'ForceMe';
    const script = 'eval("bad"); async function execute(p){ return "x"; }';
    await bus.writeVaultData(
      registry.vaultKeyFor(name),
      script,
      mimeType: 'application/javascript',
    );
    await bus.writeVaultData(
      registry.schemaKeyFor(name),
      '{"name":"ForceMe","securityClass":"C4"}',
      mimeType: 'application/json',
    );

    final scan = verification.scanScript(script);
    expect(scan.flagged, isTrue);

    final ok = await verification.promoteToVerified(
      registry: registry,
      agentName: name,
      deviceAuthenticated: true,
      priorScan: scan,
    );
    expect(ok, isTrue);
    final end = await registry.exportAgentBundle(name);
    expect((end?['schema'] as Map)['securityClass'], 'C2');
  });
}
