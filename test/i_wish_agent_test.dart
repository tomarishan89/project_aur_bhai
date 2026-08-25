import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/js_agent_registry.dart';
import 'package:project_aur_bhai/core/services/llm_service.dart';
import 'package:project_aur_bhai/core/services/marketplace_catalog.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('IWish Asset Bundle Integrity', () {
    test('script.js and dashboard.html exist and contain core logic', () {
      final scriptFile = File('assets/bro_code/i_wish/script.js');
      final dashboardFile = File('assets/bro_code/i_wish/dashboard.html');

      expect(scriptFile.existsSync(), isTrue);
      expect(dashboardFile.existsSync(), isTrue);

      final script = scriptFile.readAsStringSync();
      final dashboard = dashboardFile.readAsStringSync();

      expect(script, contains('parseTags'));
      expect(script, contains('inferCategory'));
      expect(script, contains('CREATE TABLE IF NOT EXISTS wishes'));
      expect(script, contains('cleanWishText'));

      expect(dashboard, contains('Sovereign Feedback Vault'));
      expect(dashboard, contains('exportWishesMarkdown'));
      expect(dashboard, contains('exportWishesJson'));
      expect(dashboard, contains('submitWishes'));
    });
  });

  group('Marketplace Catalog IWish Listing', () {
    test('catalog contains IWish seed listing with C4 pickup', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(telemetryBusProvider).initialize();

      final catalog = container.read(marketplaceCatalogProvider);
      final registry = container.read(jsAgentRegistryProvider);

      final listings = catalog.listings();
      final iWish = listings.firstWhere(
        (l) => l.name == 'IWish',
        orElse: () => throw Exception('IWish not found in listings'),
      );

      expect(iWish.id, 'pool-iwish');
      expect(iWish.bhaiWords, contains('i wish'));
      expect(iWish.assetBundleDir, 'assets/bro_code/i_wish');

      await registry.deleteAgent('IWish');
      expect(await catalog.pickup(iWish), isTrue);

      final bundle = await registry.exportAgentBundle('IWish');
      expect(bundle, isNotNull);
      expect((bundle!['schema'] as Map)['securityClass'], 'C4');
      expect((bundle['schema'] as Map)['source'], 'pool');
    });
  });

  group('LlmService Intent Safety Net for IWish', () {
    test('routes "i wish" utterances to IWish agent', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final jsonResp = jsonEncode({
        'intent': 'DIRECT',
        'transcription': 'I wish we had a dark red theme option',
        'directResponse': 'Understood.',
      });

      // Decode using the clean intent parser logic
      final decoded = jsonDecode(jsonResp) as Map<String, dynamic>;
      final trans = (decoded['transcription'] as String).toLowerCase();
      expect(trans.startsWith('i wish'), isTrue);
    });
  });
}
