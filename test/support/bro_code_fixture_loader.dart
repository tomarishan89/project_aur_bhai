import 'dart:convert';
import 'dart:io';

/// Parsed `test/fixtures/bro_code/*.bundle.json` entry.
class BroCodeFixture {
  final String fileName;
  final String name;
  final String script;
  final Map<String, dynamic> schema;
  final Map<String, dynamic> fixtureExpectations;
  final Map<String, String> assets;

  const BroCodeFixture({
    required this.fileName,
    required this.name,
    required this.script,
    required this.schema,
    this.fixtureExpectations = const {},
    this.assets = const {},
  });

  bool? get expectSyntaxOk => fixtureExpectations['expectSyntaxOk'] as bool?;

  bool? get expectSandboxOk => fixtureExpectations['expectSandboxOk'] as bool?;

  bool? get expectFormatOk => fixtureExpectations['expectFormatOk'] as bool?;

  bool? get expectStyleOk => fixtureExpectations['expectStyleOk'] as bool?;

  List<String> get expectHtmlKeys {
    final raw = fixtureExpectations['expectHtmlKeys'];
    if (raw is! List) return const [];
    return raw
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  bool? get expectNoCanvas => fixtureExpectations['expectNoCanvas'] as bool?;

  bool? get expectLeafletMap =>
      fixtureExpectations['expectLeafletMap'] as bool?;

  bool? get expectPwa => fixtureExpectations['expectPwa'] as bool?;

  bool? get expectNoDanglingDom =>
      fixtureExpectations['expectNoDanglingDom'] as bool?;

  String? get improveGoal => fixtureExpectations['improveGoal'] as String?;

  /// Optional multi-attempt session payload from reportVersion 2 exports.
  Map<String, dynamic>? get session {
    final raw = fixtureExpectations['session'];
    // Prefer top-level session when present (see fromJsonFile).
    return raw is Map ? Map<String, dynamic>.from(raw) : null;
  }

  factory BroCodeFixture.fromJsonFile(File file) {
    final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

    // Accept full fixture report pasted as bundle (ingest helper).
    if (raw.containsKey('broCode') && raw['broCode'] is Map) {
      final normalized = _reportToBundle(raw);
      return BroCodeFixture._fromBundleMap(file.path, normalized);
    }

    // Clipboard wrap: { "content": "<report JSON string>", "slug": "...", ... }
    if (raw['content'] is String) {
      try {
        final inner = jsonDecode(raw['content'] as String);
        if (inner is Map && inner['broCode'] is Map) {
          final normalized = _reportToBundle(Map<String, dynamic>.from(inner));
          return BroCodeFixture._fromBundleMap(file.path, normalized);
        }
      } on FormatException {
        // fall through
      }
    }

    return BroCodeFixture._fromBundleMap(file.path, raw);
  }

  factory BroCodeFixture._fromBundleMap(String path, Map<String, dynamic> raw) {
    final name = (raw['name'] as String?)?.trim() ?? 'Unnamed';
    final script = raw['script'] as String? ?? '';
    final schema = raw['schema'] is Map
        ? Map<String, dynamic>.from(raw['schema'] as Map)
        : <String, dynamic>{};
    final fixture = raw['fixture'] is Map
        ? Map<String, dynamic>.from(raw['fixture'] as Map)
        : <String, dynamic>{};
    // Carry top-level session into fixtureExpectations for tests.
    if (raw['session'] is Map && !fixture.containsKey('session')) {
      fixture['session'] = raw['session'];
    }
    final assetsRaw = raw['assets'];
    final assets = <String, String>{};
    if (assetsRaw is Map) {
      assetsRaw.forEach((k, v) => assets[k.toString()] = v.toString());
    }
    return BroCodeFixture(
      fileName: path.split(Platform.pathSeparator).last,
      name: name,
      script: script,
      schema: schema,
      fixtureExpectations: fixture,
      assets: assets,
    );
  }

  static Map<String, dynamic> _reportToBundle(Map<String, dynamic> report) {
    final bro = Map<String, dynamic>.from(report['broCode'] as Map);
    final fixture = report['fixture'] is Map
        ? Map<String, dynamic>.from(report['fixture'] as Map)
        : <String, dynamic>{};
    return {
      'name': bro['name'],
      'script': bro['script'],
      'schema': bro['schema'],
      if (bro['assets'] != null) 'assets': bro['assets'],
      'fixture': fixture,
      if (report['session'] != null) 'session': report['session'],
    };
  }

  Map<String, dynamic> inputSchemaFromSchema() {
    final raw = schema['inputSchema'];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return {};
  }
}

/// Discovers committed Bro Code fixture bundles.
List<BroCodeFixture> loadBroCodeFixtures({String? directory}) {
  final dir = Directory(directory ?? 'test/fixtures/bro_code');
  if (!dir.existsSync()) return [];

  return dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.bundle.json'))
      .map(BroCodeFixture.fromJsonFile)
      .toList()
    ..sort((a, b) => a.fileName.compareTo(b.fileName));
}

Map<String, dynamic> smokeParamsFromSchema(Map<String, dynamic>? inputSchema) {
  if (inputSchema == null || inputSchema.isEmpty) return {};
  final out = <String, dynamic>{};
  inputSchema.forEach((key, value) {
    if (value is! Map) {
      out[key] = '';
      return;
    }
    final type = (value['type'] as String?)?.toLowerCase() ?? 'string';
    out[key] = switch (type) {
      'number' => 1,
      'boolean' => true,
      _ => 'test',
    };
  });
  return out;
}
