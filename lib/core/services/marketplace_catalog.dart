import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agents/agent_base.dart';
import '../agents/js_agent_adapter.dart';
import '../models/lineage_entry.dart';
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
  final String? originalAuthor;
  final List<LineageEntry> lineage;
  final String provenance;
  final List<String> bhaiWords;
  final String invocationPrompt;
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
    this.author = '@core',
    this.originalAuthor,
    this.lineage = const [],
    this.provenance = 'official',
    this.bhaiWords = const [],
    this.invocationPrompt = '',
    this.access = BhaiCodeAccess.defaults,
    this.vaultAssets = const {},
    this.assetBundleDir,
  });

  /// Formatted handle ensuring '@' prefix.
  String get displayHandle {
    final trimmed = author.trim();
    if (trimmed.isEmpty) return '@core';
    return trimmed.startsWith('@') ? trimmed : '@$trimmed';
  }

  /// Number of remixes / contributions beyond the root creation.
  int get remixCount => lineage.length > 1 ? lineage.length - 1 : 0;
}

/// Seed catalog of pick-upable Bhai Code (shown under Sabke Bhai).
class MarketplaceCatalog {
  MarketplaceCatalog(this._ref);

  final Ref _ref;

  static final List<MarketplaceListing> seedListings = [
    MarketplaceListing(
      id: 'pool-calculator',
      name: 'Calculator',
      description:
          'Sovereign mathematical evaluator for arithmetic expressions, percentages, and formulas.',
      license: 'remix_free',
      author: '@core',
      provenance: 'official',
      lineage: [
        LineageEntry(
          author: '@core',
          version: '1.0.0',
          timestamp: DateTime(2026, 8, 1),
          note: 'Official Project Aur Bhai Core Seed',
        ),
      ],
      bhaiWords: const ['calculate', 'what is', 'how much is'],
      invocationPrompt: 'Calculate 15 * 84',
      script: JsAgentRegistry.calculatorScript,
      inputSchema: const {
        'expression': {
          'type': 'string',
          'description':
              'The standard mathematical expression to solve. Supports + - * / ^ and parentheses, e.g. "2+2" or "2^3".',
          'required': true,
        },
      },
    ),
    MarketplaceListing(
      id: 'pool-accountant',
      name: 'Accountant',
      description:
          'Sovereign expenditure logger & PWA dashboard. Multi-item voice feed, spend Q&A, and category charts.',
      license: 'remix_free',
      author: '@core',
      provenance: 'official',
      lineage: [
        LineageEntry(
          author: '@core',
          version: '1.0.0',
          timestamp: DateTime(2026, 8, 1),
          note: 'Official Project Aur Bhai Core Seed',
        ),
      ],
      bhaiWords: const ['spent', 'expense', 'how much did i spend', 'expenditure'],
      invocationPrompt: 'Spent 50 on chai',
      script: '',
      assetBundleDir: 'assets/bro_code/accountant',
      inputSchema: const {
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
      author: '@core',
      provenance: 'official',
      lineage: [
        LineageEntry(
          author: '@core',
          version: '1.0.0',
          timestamp: DateTime(2026, 8, 1),
          note: 'Official Project Aur Bhai Core Seed',
        ),
      ],
      bhaiWords: const ['telemetry', 'live speed', 'sensor map', 'show telemetry'],
      invocationPrompt: 'Show telemetry dashboard',
      script: '',
      assetBundleDir: 'assets/bro_code/telemeter',
    ),
    MarketplaceListing(
      id: 'pool-notetaker',
      name: 'NoteTaker',
      description:
          'Sovereign thought & idea vault with tag filtering, markdown search, and PWA dashboard.',
      license: 'remix_free',
      author: '@core',
      provenance: 'official',
      lineage: [
        LineageEntry(
          author: '@core',
          version: '1.0.0',
          timestamp: DateTime(2026, 8, 1),
          note: 'Official Project Aur Bhai Core Seed',
        ),
      ],
      bhaiWords: const ['note down', 'jot down', 'remember that', 'take a note', 'what did i note'],
      invocationPrompt: 'Note down buy groceries tomorrow',
      script: '',
      assetBundleDir: 'assets/bro_code/note_taker',
      inputSchema: const {
        'text': {'type': 'string', 'description': 'Note content, question, or tag'},
        'action': {'type': 'string', 'description': 'Action such as "dashboard"'},
      },
    ),
    MarketplaceListing(
      id: 'pool-iwish',
      name: 'IWish',
      description:
          'Sovereign feedback & feature wishlist vault. 100% on-device wish recording and PWA dashboard.',
      license: 'remix_free',
      author: '@core',
      provenance: 'official',
      lineage: [
        LineageEntry(
          author: '@core',
          version: '1.0.0',
          timestamp: DateTime(2026, 8, 1),
          note: 'Official Project Aur Bhai Core Seed',
        ),
      ],
      bhaiWords: const ['i wish', 'wish', 'feedback', 'feature request', 'bhai wish'],
      invocationPrompt: 'I wish we had dark red theme',
      script: '',
      assetBundleDir: 'assets/bro_code/i_wish',
      inputSchema: const {
        'wish': {'type': 'string', 'description': 'Wish, feature request, or feedback text'},
        'action': {'type': 'string', 'description': 'Action such as "list", "summary", or "dashboard"'},
      },
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

  /// Silently upgrade already-installed seed-catalog agents whose script or assets changed.
  /// NOTE: This never auto-installs unpicked seeds into Sandbox.
  Future<void> upgradeSeedListings() async {
    final registry = _ref.read(jsAgentRegistryProvider);
    final telemetry = _ref.read(telemetryBusProvider);
    for (final listing in seedListings) {
      try {
        final bundle = await registry.exportAgentBundle(listing.name);
        if (bundle == null) {
          // Do NOT auto-install catalog items. User must tap "Pick Up".
          continue;
        }
        final storedScript = bundle['script'] as String? ?? '';
        final keyName = listing.name.toLowerCase();
        final vaultAsset = await telemetry.readVaultData('$keyName.html') ??
            await telemetry.readVaultData('dashboard.html');
        if (storedScript != listing.script || vaultAsset == null) {
          final schemaMap = bundle['schema'] as Map<String, dynamic>? ?? {};
          final existingSec = AgentSecurityClassX.fromId(
            schemaMap['securityClass']?.toString() ??
                bundle['securityClass']?.toString() ??
                (listing.name == 'Calculator' ? 'C2' : 'C4'),
          );
          await _installListing(registry, listing, securityClass: existingSec);
        }
      } catch (e) {
        debugPrint(
          '[MarketplaceCatalog] Seed upgrade skipped for ${listing.name}: $e',
        );
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
        final scriptJs = await rootBundle.loadString(
          '${listing.assetBundleDir}/script.js',
        );
        final dashboardHtml = await rootBundle.loadString(
          '${listing.assetBundleDir}/dashboard.html',
        );
        finalScript = scriptJs;
        final keyName = listing.name.toLowerCase();
        finalAssets['$keyName.html'] = dashboardHtml;
        finalAssets['dashboard.html'] = dashboardHtml;
      } catch (e) {
        debugPrint(
          '[MarketplaceCatalog] Error loading bundle assets for ${listing.name}: $e',
        );
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
