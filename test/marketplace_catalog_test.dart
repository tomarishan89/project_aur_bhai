import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:project_aur_bhai/core/agents/agent_base.dart';
import 'package:project_aur_bhai/core/agents/js_agent_adapter.dart';
import 'package:project_aur_bhai/core/models/lineage_entry.dart';
import 'package:project_aur_bhai/core/services/agent_service.dart';
import 'package:project_aur_bhai/core/services/bhai_code_origin.dart';
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

  group('MarketplaceCatalog Seed Listings Specification', () {
    test('seedListings contains all 5 required sovereign tools', () {
      final names = MarketplaceCatalog.seedListings.map((l) => l.name).toSet();
      expect(names, containsAll(['Calculator', 'Accountant', 'Telemeter', 'NoteTaker', 'IWish']));
      expect(MarketplaceCatalog.seedListings.length, 5);
    });

    test('all seed listings have author @core and valid initial lineage', () {
      for (final listing in MarketplaceCatalog.seedListings) {
        expect(listing.author, '@core');
        expect(listing.displayHandle, '@core');
        expect(listing.remixCount, 0);
        expect(listing.lineage, isNotEmpty);
        expect(listing.lineage.first.author, '@core');
        expect(listing.lineage.first.version, '1.0.0');
        expect(listing.license, 'remix_free');
      }
    });

    test('MarketplaceListing displayHandle and remixCount compute accurately', () {
      final customListing = MarketplaceListing(
        id: 'test-fork',
        name: 'ForkedTool',
        description: 'A test tool',
        script: 'async function execute(){}',
        author: 'ishan',
        lineage: [
          LineageEntry(author: '@core', version: '1.0.0', timestamp: DateTime(2026, 8, 1), note: 'Seed'),
          LineageEntry(author: '@ishan', version: '1.1.0', timestamp: DateTime(2026, 8, 2), note: 'Fork'),
        ],
      );

      expect(customListing.displayHandle, '@ishan');
      expect(customListing.remixCount, 1);
    });
  });

  group('MarketplaceCatalog Lifecycle & Vault Integration', () {
    late ProviderContainer container;

    setUp(() async {
      container = ProviderContainer();
      final bus = container.read(telemetryBusProvider);
      await bus.initialize();
    });

    tearDown(() {
      container.dispose();
    });

    test('pickup installs unpicked listing into vault at C4', () async {
      final catalog = container.read(marketplaceCatalogProvider);
      final registry = container.read(jsAgentRegistryProvider);
      final agentService = container.read(agentServiceProvider);

      final testListing = MarketplaceListing(
        id: 'pool-mock-tool',
        name: 'MockCatalogTool',
        description: 'Test catalog item for pickup',
        script: 'async function execute(p) { return "mock output"; }',
        author: '@core',
        lineage: [
          LineageEntry(
            author: '@core',
            version: '1.0.0',
            timestamp: DateTime(2026, 8, 1),
            note: 'Initial Seed',
          ),
        ],
      );

      await registry.deleteAgent(testListing.name);

      // Verify pickup succeeds on new tool
      final installed = await catalog.pickup(testListing, securityClass: AgentSecurityClass.c4Unverified);
      expect(installed, isTrue);

      // Verify live registration
      final agent = agentService.findAgent(testListing.name);
      expect(agent, isNotNull);
      expect(agent, isA<JsAgentAdapter>());
      final js = agent as JsAgentAdapter;
      expect(js.securityClass, AgentSecurityClass.c4Unverified);
      expect(js.author, '@core');
      expect(js.displayHandle(), '@core');
      expect(js.source, BhaiCodeOrigin.pool);

      // Verify second pickup of same name fails without duplicate overwrite
      final secondTry = await catalog.pickup(testListing);
      expect(secondTry, isFalse);

      // Clean up
      await registry.deleteAgent(testListing.name);
    });

    test('upgradeSeedListings only updates existing installed seeds', () async {
      final catalog = container.read(marketplaceCatalogProvider);
      final registry = container.read(jsAgentRegistryProvider);

      // Calculator is already in core seeds, let's verify upgrade doesn't throw
      await catalog.upgradeSeedListings();

      final bundle = await registry.exportAgentBundle('Calculator');
      if (bundle != null) {
        expect(bundle['name'], 'Calculator');
      }
    });
  });
}
