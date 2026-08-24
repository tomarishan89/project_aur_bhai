import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agents/agent_base.dart';
import '../agents/js_agent_adapter.dart';
import 'bhai_code_access.dart';
import 'bhai_code_origin.dart';
import 'js_agent_registry.dart';
import 'js_bridge_service.dart';
import 'telemetry_bus.dart';

/// Local Sabke Bhai pool listing (seed catalog; Friend Circle is remote).
class MarketplaceListing {
  final String id;
  final String name;
  final String description;
  final String script;
  final Map<String, dynamic> inputSchema;
  final String license;
  final String author;
  final BhaiCodeAccess access;
  final Map<String, String> vaultAssets;
  final String? assetBundleDir;

  const MarketplaceListing({
    required this.id,
    required this.name,
    required this.description,
    required this.script,
    this.inputSchema = const {},
    this.license = 'remix_free',
    this.author = '',
    this.access = BhaiCodeAccess.defaults,
    this.vaultAssets = const {},
    this.assetBundleDir,
  });
}

/// Seed catalog of pick-upable Bhai Code (shown under Sabke Bhai).
class MarketplaceCatalog {
  MarketplaceCatalog(this._ref);

  final Ref _ref;

  static final List<MarketplaceListing> seedListings = [
    MarketplaceListing(
      id: 'pool-accountant',
      name: 'Accountant',
      description:
          'Sovereign expenditure logger & PWA dashboard. Multi-item voice feed, spend Q&A, and category charts.',
      license: 'remix_free',
      script: '',
      assetBundleDir: 'assets/bro_code/accountant',
      inputSchema: {
        'text': {'type': 'string', 'description': 'Expense statement or question'},
        'action': {'type': 'string', 'description': 'Action such as "dashboard"'},
      },
    ),
    MarketplaceListing(
      id: 'pool-telemeter',
      name: 'Telemeter',
      description:
          'Sovereign PWA telemetry dashboard for live motion, map, and CSV/GeoJSON exports.',
      license: 'remix_free',
      script: '',
      assetBundleDir: 'assets/bro_code/telemeter',
    ),
  ];

  List<MarketplaceListing> listings() => List.unmodifiable(seedListings);

  /// Install listing into vault at C4 and register. Returns false if name taken.
  Future<bool> pickup(
    MarketplaceListing listing, {
    AgentSecurityClass securityClass = AgentSecurityClass.c4Unverified,
  }) async {
    final registry = _ref.read(jsAgentRegistryProvider);
    final existing = await registry.exportAgentBundle(listing.name);
    if (existing != null) return false;

    await _installListing(registry, listing, securityClass: securityClass);
    return true;
  }

  /// Silently upgrade any installed seed-catalog agent whose script has changed or asset is missing.
  Future<void> upgradeSeedListings() async {
    final registry = _ref.read(jsAgentRegistryProvider);
    final telemetry = _ref.read(telemetryBusProvider);
    for (final listing in seedListings) {
      final bundle = await registry.exportAgentBundle(listing.name);
      if (bundle == null) {
        await _installListing(registry, listing);
        continue;
      }
      final storedScript = bundle['script'] as String? ?? '';
      final vaultAsset = await telemetry.readVaultData('telemeter.html');
      if (storedScript != listing.script || vaultAsset == null) {
        await _installListing(registry, listing);
      }
    }
  }

  Future<void> _installListing(
    JsAgentRegistry registry,
    MarketplaceListing listing, {
    AgentSecurityClass securityClass = AgentSecurityClass.c4Unverified,
  }) async {
    final schema = <String, BroCodeParameter>{};
    listing.inputSchema.forEach((key, value) {
      if (value is Map) {
        schema[key] = BroCodeParameter(
          type: value['type']?.toString() ?? 'string',
          description: value['description']?.toString() ?? '',
        );
      }
    });

    var finalScript = listing.script;
    var finalAssets = Map<String, String>.from(listing.vaultAssets);
    
    if (listing.assetBundleDir != null) {
      try {
        final scriptJs = await rootBundle.loadString('${listing.assetBundleDir}/script.js');
        final dashboardHtml = await rootBundle.loadString('${listing.assetBundleDir}/dashboard.html');
        finalScript = scriptJs;
        finalAssets['telemeter.html'] = dashboardHtml;
        finalAssets['dashboard.html'] = dashboardHtml;
      } catch (e) {
        debugPrint('[MarketplaceCatalog] Error loading bundle assets for ${listing.name}: $e');
      }
    }

    await registry.saveAndRegisterAgent(
      name: listing.name,
      description: '${listing.description} [marketplace:${listing.id}]',
      script: finalScript,
      inputSchema: schema,
      securityClass: securityClass,
      source: BhaiCodeOrigin.pool,
      vaultAssets: finalAssets,
    );

    final telemetry = _ref.read(telemetryBusProvider);
    final schemaEntry = await telemetry.readVaultData(
      registry.schemaKeyFor(listing.name),
    );
    final schemaMap = schemaEntry != null
        ? Map<String, dynamic>.from(jsonDecode(schemaEntry['value']!) as Map)
        : <String, dynamic>{
            'name': listing.name,
            'securityClass': securityClass.id,
          };
    schemaMap['license'] = listing.license;
    schemaMap['marketplaceId'] = listing.id;
    schemaMap['source'] = BhaiCodeOrigin.pool;
    await telemetry.writeVaultData(
      registry.schemaKeyFor(listing.name),
      jsonEncode(schemaMap),
      mimeType: 'application/json',
    );
    
    // Automatically execute the agent in sovereign mode so vault HTML is published.
    try {
      final bridge = _ref.read(jsBridgeServiceProvider);
      await bridge.executeAgentScript(
        agentName: listing.name,
        script: finalScript,
        parameters: {},
        sandboxMode: false,
        assets: finalAssets,
      );
    } catch (e) {
      debugPrint('[MarketplaceCatalog] Execution error on install: $e');
    }
  }
}

final marketplaceCatalogProvider = Provider<MarketplaceCatalog>((ref) {
  return MarketplaceCatalog(ref);
});
