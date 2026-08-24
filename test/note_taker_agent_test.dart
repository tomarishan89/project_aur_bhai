import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/js_agent_registry.dart';
import 'package:project_aur_bhai/core/services/marketplace_catalog.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('NoteTaker Asset Bundle Integrity', () {
    test('script.js and dashboard.html contain required functionality', () {
      final scriptFile = File('assets/bro_code/note_taker/script.js');
      final dashboardFile = File('assets/bro_code/note_taker/dashboard.html');

      expect(
        scriptFile.existsSync(),
        isTrue,
        reason: 'assets/bro_code/note_taker/script.js must exist',
      );
      expect(
        dashboardFile.existsSync(),
        isTrue,
        reason: 'assets/bro_code/note_taker/dashboard.html must exist',
      );

      final script = scriptFile.readAsStringSync();
      final dashboard = dashboardFile.readAsStringSync();

      // Verify Script capabilities
      expect(script, contains('parseTags'));
      expect(script, contains('notes_ledger.json'));
      expect(script, contains('cleanNoteText'));
      expect(script, contains('extractTitleAndBody'));

      // Verify Dashboard capabilities
      expect(dashboard, contains('Note Taker — Sovereign Thought'));
      expect(dashboard, contains('tag-chips-container'));
      expect(dashboard, contains('exportMarkdown'));
      expect(dashboard, contains('exportJSON'));
      expect(dashboard, contains('date-from'));
      expect(dashboard, contains('date-to'));
    });
  });

  group('Marketplace Catalog NoteTaker Listing', () {
    test('catalog contains NoteTaker seed listing with C4 pickup', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(telemetryBusProvider).initialize();

      final catalog = container.read(marketplaceCatalogProvider);
      final registry = container.read(jsAgentRegistryProvider);

      final listings = catalog.listings();
      final noteTaker = listings.firstWhere(
        (l) => l.name == 'NoteTaker',
        orElse: () => throw Exception('NoteTaker not in seedListings'),
      );

      expect(noteTaker.id, 'pool-notetaker');
      expect(noteTaker.assetBundleDir, 'assets/bro_code/note_taker');

      await registry.deleteAgent('NoteTaker');
      expect(await catalog.pickup(noteTaker), isTrue);

      final bundle = await registry.exportAgentBundle('NoteTaker');
      expect(bundle, isNotNull);
      expect((bundle!['schema'] as Map)['securityClass'], 'C4');
      expect((bundle['schema'] as Map)['source'], 'pool');
    });
  });
}
