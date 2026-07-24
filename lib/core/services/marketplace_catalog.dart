import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agents/agent_base.dart';
import '../agents/js_agent_adapter.dart';
import 'bhai_code_access.dart';
import 'bhai_code_origin.dart';
import 'js_agent_registry.dart';
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

  const MarketplaceListing({
    required this.id,
    required this.name,
    required this.description,
    required this.script,
    this.inputSchema = const {},
    this.license = 'remix_free',
    this.author = '',
    this.access = BhaiCodeAccess.defaults,
  });
}

/// Seed catalog of pick-upable Bhai Code (shown under Sabke Bhai).
class MarketplaceCatalog {
  MarketplaceCatalog(this._ref);

  final Ref _ref;

  static final List<MarketplaceListing> seedListings = [
    MarketplaceListing(
      id: 'pool-tip-jar',
      name: 'TipJar',
      description:
          'Tracks cash tips told via voice feed. Uses System.readInbox.',
      license: 'remix_free',
      script: r'''
async function execute(params) {
  System.log('TipJar reading inbox…');
  const items = await System.readInbox({ unreadOnly: true, limit: 20 });
  if (!items || items.length === 0) {
    return 'No new tip entries. Tell TipJar that you received an amount.';
  }
  let total = 0;
  const ids = [];
  for (const item of items) {
    ids.push(item.id);
    const m = String(item.text).match(/(\d+(?:\.\d+)?)/);
    if (m) total += Number(m[1]);
  }
  await System.consumeInbox({ ids: ids });
  return 'Logged ' + items.length + ' tip(s); sum about ' + total + '.';
}
''',
    ),
    MarketplaceListing(
      id: 'pool-hello-counter',
      name: 'HelloCounter',
      description: 'Sandbox-friendly counter that writes a tiny HTML note.',
      license: 'remix_free',
      script: r'''
async function execute(params) {
  const n = (params && params.count) ? Number(params.count) : 1;
  const html = '<!DOCTYPE html><html><body style="background:#111;color:#eee;font-family:sans-serif;padding:24px">'
    + '<h1>Hello Counter</h1><p>Count: ' + n + '</p></body></html>';
  await System.writeVault('hello_counter.html', html, 'text/html');
  return 'Hello counter updated to ' + n + '. Open from Vault Dashboards.';
}
''',
      inputSchema: {
        'count': {'type': 'number', 'description': 'Display count'},
      },
    ),
  ];

  List<MarketplaceListing> listings() => List.unmodifiable(seedListings);

  /// Install listing into vault at C4 and register. Returns false if name taken.
  Future<bool> pickup(MarketplaceListing listing) async {
    final registry = _ref.read(jsAgentRegistryProvider);
    final existing = await registry.exportAgentBundle(listing.name);
    if (existing != null) return false;

    final schema = <String, BroCodeParameter>{};
    listing.inputSchema.forEach((key, value) {
      if (value is Map) {
        schema[key] = BroCodeParameter(
          type: value['type']?.toString() ?? 'string',
          description: value['description']?.toString() ?? '',
        );
      }
    });

    await registry.saveAndRegisterAgent(
      name: listing.name,
      description: '${listing.description} [marketplace:${listing.id}]',
      script: listing.script,
      inputSchema: schema,
      securityClass: AgentSecurityClass.c4Unverified,
      source: BhaiCodeOrigin.pool,
    );

    final telemetry = _ref.read(telemetryBusProvider);
    final schemaEntry = await telemetry.readVaultData(
      registry.schemaKeyFor(listing.name),
    );
    final schemaMap = schemaEntry != null
        ? Map<String, dynamic>.from(jsonDecode(schemaEntry['value']!) as Map)
        : <String, dynamic>{
            'name': listing.name,
            'securityClass': AgentSecurityClass.c4Unverified.id,
          };
    schemaMap['license'] = listing.license;
    schemaMap['marketplaceId'] = listing.id;
    schemaMap['source'] = BhaiCodeOrigin.pool;
    await telemetry.writeVaultData(
      registry.schemaKeyFor(listing.name),
      jsonEncode(schemaMap),
      mimeType: 'application/json',
    );
    return true;
  }
}

final marketplaceCatalogProvider = Provider<MarketplaceCatalog>((ref) {
  return MarketplaceCatalog(ref);
});
