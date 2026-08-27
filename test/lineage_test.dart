import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:project_aur_bhai/core/agents/agent_base.dart';
import 'package:project_aur_bhai/core/agents/js_agent_adapter.dart';
import 'package:project_aur_bhai/core/models/lineage_entry.dart';
import 'package:project_aur_bhai/core/services/agent_service.dart';
import 'package:project_aur_bhai/core/services/bhai_code_origin.dart';
import 'package:project_aur_bhai/core/services/byok_service.dart';
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

  group('LineageEntry & Handle Tests', () {
    test('LineageEntry serializes and deserializes correctly', () {
      final now = DateTime.now();
      final entry = LineageEntry(
        author: '@alice',
        version: '1.2.0',
        timestamp: now,
        note: 'Added dark mode support',
      );

      final json = entry.toJson();
      expect(json['author'], '@alice');
      expect(json['version'], '1.2.0');
      expect(json['note'], 'Added dark mode support');

      final reconstructed = LineageEntry.fromJson(json);
      expect(reconstructed.author, '@alice');
      expect(reconstructed.displayHandle, '@alice');
      expect(reconstructed.version, '1.2.0');
      expect(reconstructed.note, 'Added dark mode support');
    });

    test('Handle formatting ensures @ prefix', () {
      expect(BhaiCodeOrigin.formatHandle('ishan'), '@ishan');
      expect(BhaiCodeOrigin.formatHandle('@ishan'), '@ishan');
      expect(BhaiCodeOrigin.formatHandle('  @core  '), '@core');
      expect(BhaiCodeOrigin.formatHandle(''), '@you');
    });

    test('BhaiCodeOrigin handle helpers identify core and self', () {
      expect(BhaiCodeOrigin.isCore('@core'), isTrue);
      expect(BhaiCodeOrigin.isCore('core'), isTrue);
      expect(BhaiCodeOrigin.isCore('@alice'), isFalse);

      expect(BhaiCodeOrigin.isSelf('@you'), isTrue);
      expect(BhaiCodeOrigin.isSelf('@ishan', myHandle: '@ishan'), isTrue);
      expect(BhaiCodeOrigin.isSelf('@ishan', myHandle: '@bob'), isFalse);
    });

    test('Marketplace seed listings have @core author and lineage', () {
      for (final listing in MarketplaceCatalog.seedListings) {
        expect(listing.author, '@core');
        expect(listing.displayHandle, '@core');
        expect(listing.lineage, isNotEmpty);
        expect(listing.lineage.first.author, '@core');
      }
    });
  });

  group('JsAgentRegistry Multi-Hop Lineage Lifecycle', () {
    test('Saving new agent initializes lineage array with author handle', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final bus = container.read(telemetryBusProvider);
      await bus.initialize();
      final registry = container.read(jsAgentRegistryProvider);

      const name = 'LineageHero';
      const script = 'async function execute(p) { return "hero"; }';

      await registry.deleteAgent(name);

      // Save initial agent as @alice
      final adapter = await registry.saveAndRegisterAgent(
        name: name,
        description: 'A hero agent for lineage testing',
        inputSchema: {},
        script: script,
        author: '@alice',
        changeNote: 'Initial hero creation',
      );

      expect(adapter.author, '@alice');
      expect(adapter.originalAuthor, '@alice');
      expect(adapter.displayHandle(), '@alice');
      expect(adapter.remixCount, 0);
      expect(adapter.lineage.length, 1);
      expect(adapter.lineage.first.author, '@alice');
      expect(adapter.lineage.first.version, '1.0.0');

      // Export bundle check
      final bundle = await registry.exportAgentBundle(name);
      expect(bundle, isNotNull);
      expect(bundle!['author'], '@alice');
      expect(bundle['originalAuthor'], '@alice');
      expect(bundle['lineage'], isNotEmpty);
      expect((bundle['lineage'] as List).length, 1);

      // Now remix the agent as @bob
      final remixed = await registry.saveAndRegisterAgent(
        name: name,
        description: 'A hero agent remixed with turbo power',
        inputSchema: {},
        script: 'async function execute(p) { return "turbo hero"; }',
        author: '@bob',
        changeNote: 'Added turbo power boost',
      );

      expect(remixed.author, '@bob');
      expect(remixed.originalAuthor, '@alice');
      expect(remixed.remixCount, 1);
      expect(remixed.lineage.length, 2);
      expect(remixed.lineage[0].author, '@alice');
      expect(remixed.lineage[1].author, '@bob');
      expect(remixed.lineage[1].version, '1.1.0');
      expect(remixed.lineage[1].note, 'Added turbo power boost');

      // Now remix the agent a second time as @charlie
      final multiHop = await registry.saveAndRegisterAgent(
        name: name,
        description: 'A hero agent multi-hop remixed with shield',
        inputSchema: {},
        script: 'async function execute(p) { return "turbo shield hero"; }',
        author: '@charlie',
        changeNote: 'Added energy shield',
      );

      expect(multiHop.author, '@charlie');
      expect(multiHop.originalAuthor, '@alice');
      expect(multiHop.remixCount, 2);
      expect(multiHop.lineage.length, 3);
      expect(multiHop.lineage[0].author, '@alice');
      expect(multiHop.lineage[1].author, '@bob');
      expect(multiHop.lineage[2].author, '@charlie');
      expect(multiHop.lineage[2].version, '1.2.0');

      // Verify that reloading from vault preserves the complete lineage chain
      await registry.loadAndRegisterAgents();
      final reloaded = container.read(agentServiceProvider).findAgent(name) as JsAgentAdapter;
      expect(reloaded.author, '@charlie');
      expect(reloaded.originalAuthor, '@alice');
      expect(reloaded.lineage.length, 3);
      expect(reloaded.lineage[0].author, '@alice');
      expect(reloaded.lineage[1].author, '@bob');
      expect(reloaded.lineage[2].author, '@charlie');
    });
  });
}
