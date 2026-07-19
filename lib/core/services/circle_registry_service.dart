import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'js_agent_registry.dart';
import 'marketplace_catalog.dart';
import 'secure_secret_store.dart';

/// Bro Code bundle published to the closed-circle GitHub registry (MVP-S10).
class CircleListing {
  final String id;
  final String name;
  final String description;
  final String license;
  final String revisionId;
  final String author;
  final String script;
  final Map<String, dynamic> inputSchema;
  final String? parentRevisionId;

  const CircleListing({
    required this.id,
    required this.name,
    required this.description,
    required this.license,
    required this.revisionId,
    required this.author,
    required this.script,
    this.inputSchema = const {},
    this.parentRevisionId,
  });

  Map<String, dynamic> toBundleJson() => {
        'id': id,
        'name': name,
        'description': description,
        'license': license,
        'revisionId': revisionId,
        if (parentRevisionId != null) 'parentRevisionId': parentRevisionId,
        'author': author,
        'script': script,
        'inputSchema': inputSchema,
      };

  factory CircleListing.fromBundleJson(Map<String, dynamic> json) {
    return CircleListing(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      license: json['license'] as String? ?? 'remix_free',
      revisionId: json['revisionId'] as String? ?? '',
      author: json['author'] as String? ?? '',
      script: json['script'] as String? ?? '',
      parentRevisionId: json['parentRevisionId'] as String?,
      inputSchema: Map<String, dynamic>.from(
        (json['inputSchema'] as Map?) ?? const {},
      ),
    );
  }

  MarketplaceListing toMarketplaceListing() => MarketplaceListing(
        id: id,
        name: name,
        description: '$description · by $author · $license · $revisionId',
        script: script,
        inputSchema: inputSchema,
        license: license,
      );
}

/// GitHub Contents API client for multi-city circle share.
class CircleRegistryService {
  CircleRegistryService(this._ref, {SecureSecretStore? secretStore})
      : _secrets = secretStore ??
            (Platform.environment.containsKey('FLUTTER_TEST')
                ? MemorySecureSecretStore()
                : FlutterSecureSecretStore());

  final Ref _ref;
  final SecureSecretStore _secrets;
  final http.Client _http = http.Client();

  String _owner = '';
  String _repo = AppConfig.circleDefaultRepo;
  String _token = '';
  String _author = 'circle-user';

  String get owner => _owner;
  String get repo => _repo;
  String get authorDisplay => _author;
  bool get isConfigured =>
      _owner.isNotEmpty && _repo.isNotEmpty && _token.isNotEmpty;

  Future<void> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _owner = prefs.getString(AppConfig.circlePrefsOwnerKey) ?? '';
    _repo = prefs.getString(AppConfig.circlePrefsRepoKey) ??
        AppConfig.circleDefaultRepo;
    _author = prefs.getString(AppConfig.circlePrefsAuthorKey) ?? 'circle-user';
    _token = await _secrets.read(AppConfig.circlePrefsTokenKey) ?? '';
  }

  Future<void> saveConfig({
    required String owner,
    required String repo,
    required String token,
    required String authorDisplay,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    _owner = owner.trim();
    _repo = repo.trim().isEmpty ? AppConfig.circleDefaultRepo : repo.trim();
    _author = authorDisplay.trim().isEmpty ? 'circle-user' : authorDisplay.trim();
    _token = token.trim();
    await prefs.setString(AppConfig.circlePrefsOwnerKey, _owner);
    await prefs.setString(AppConfig.circlePrefsRepoKey, _repo);
    await prefs.setString(AppConfig.circlePrefsAuthorKey, _author);
    if (_token.isEmpty) {
      await _secrets.delete(AppConfig.circlePrefsTokenKey);
    } else {
      await _secrets.write(AppConfig.circlePrefsTokenKey, _token);
    }
  }

  Uri _contentsUri(String path) => Uri.parse(
        'https://api.github.com/repos/$_owner/$_repo/contents/$path',
      );

  Map<String, String> get _headers => {
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $_token',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  /// Thrown when Settings has no owner/repo/token yet (distinct from empty index).
  static const notConfiguredSentinel = 'CIRCLE_NOT_CONFIGURED';

  Future<List<CircleListing>> listCircle() async {
    await loadConfig();
    if (!isConfigured) {
      throw StateError(notConfiguredSentinel);
    }
    try {
      final res = await _http.get(
        _contentsUri(AppConfig.circleIndexPath),
        headers: _headers,
      );
      if (res.statusCode == 404) return [];
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw Exception(AppConfig.circleAuthFailedHint);
      }
      if (res.statusCode != 200) {
        throw Exception('Circle list failed: HTTP ${res.statusCode}');
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final contentB64 = (body['content'] as String? ?? '').replaceAll('\n', '');
      final decoded = utf8.decode(base64Decode(contentB64));
      final index = jsonDecode(decoded) as Map<String, dynamic>;
      final entries = (index['listings'] as List?) ?? const [];
      final out = <CircleListing>[];
      for (final e in entries.whereType<Map>()) {
        final path = e['path'] as String?;
        if (path == null) continue;
        final listing = await _fetchBundleAt(path);
        if (listing != null) out.add(listing);
      }
      return out;
    } catch (e) {
      debugPrint('[CircleRegistry] list error: $e');
      rethrow;
    }
  }

  Future<CircleListing?> _fetchBundleAt(String path) async {
    final res = await _http.get(_contentsUri(path), headers: _headers);
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final contentB64 = (body['content'] as String? ?? '').replaceAll('\n', '');
    final decoded = utf8.decode(base64Decode(contentB64));
    return CircleListing.fromBundleJson(
      jsonDecode(decoded) as Map<String, dynamic>,
    );
  }

  Future<void> publish({
    required String name,
    required String description,
    required String script,
    required Map<String, dynamic> inputSchema,
    String license = 'remix_free',
    String? parentRevisionId,
  }) async {
    await loadConfig();
    if (!isConfigured) {
      throw Exception(
        'Configure circle GitHub owner / repo / token in Settings.',
      );
    }
    if (license == 'paid') {
      throw Exception('Paid license is deferred for MVP.');
    }
    if (parentRevisionId != null &&
        license == 'remix_free' &&
        parentRevisionId.isNotEmpty) {
      // lineage_indexed parents cannot be erased via remix_free republish.
      throw Exception(
        'Parent revision requires lineage_indexed license (cannot erase ancestry).',
      );
    }

    final revisionId = 'rev-${DateTime.now().toUtc().millisecondsSinceEpoch}';
    final id = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_').toLowerCase();
    final listing = CircleListing(
      id: id,
      name: name,
      description: description,
      license: license,
      revisionId: revisionId,
      author: _author,
      script: script,
      inputSchema: inputSchema,
      parentRevisionId: license == 'lineage_indexed' ? parentRevisionId : null,
    );
    final bundlePath = '${AppConfig.circleBundleDir}/$id/bundle.json';
    await _putFile(
      path: bundlePath,
      content: jsonEncode(listing.toBundleJson()),
      message: 'Publish Bro Code $name ($revisionId)',
    );

    final index = await _readIndex();
    final listings = List<Map<String, dynamic>>.from(
      (index['listings'] as List?)?.whereType<Map>().map(
                (e) => Map<String, dynamic>.from(e),
              ) ??
          const [],
    );
    listings.removeWhere((e) => e['id'] == id);
    listings.insert(0, {
      'id': id,
      'name': name,
      'path': bundlePath,
      'revisionId': revisionId,
      'license': license,
      'author': _author,
    });
    index['listings'] = listings;
    index['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    final sha = index.remove('_sha') as String?;
    await _putFile(
      path: AppConfig.circleIndexPath,
      content: const JsonEncoder.withIndent('  ').convert(index),
      message: 'Update circle index for $name',
      sha: sha,
    );
  }

  Future<Map<String, dynamic>> _readIndex() async {
    final res = await _http.get(
      _contentsUri(AppConfig.circleIndexPath),
      headers: _headers,
    );
    if (res.statusCode == 404) {
      return {'listings': <Map<String, dynamic>>[]};
    }
    if (res.statusCode != 200) {
      throw Exception('Read index failed: HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final sha = body['sha'] as String?;
    final contentB64 = (body['content'] as String? ?? '').replaceAll('\n', '');
    final decoded = utf8.decode(base64Decode(contentB64));
    final map = jsonDecode(decoded) as Map<String, dynamic>;
    map['_sha'] = sha;
    return map;
  }

  Future<void> _putFile({
    required String path,
    required String content,
    required String message,
    String? sha,
  }) async {
    String? useSha = sha;
    if (useSha == null) {
      final existing = await _http.get(_contentsUri(path), headers: _headers);
      if (existing.statusCode == 200) {
        useSha =
            (jsonDecode(existing.body) as Map<String, dynamic>)['sha'] as String?;
      }
    }
    final payload = <String, dynamic>{
      'message': message,
      'content': base64Encode(utf8.encode(content)),
      'sha': ?useSha,
    };
    final res = await _http.put(
      _contentsUri(path),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception(
        'GitHub put $path failed: HTTP ${res.statusCode} ${res.body}',
      );
    }
  }

  Future<bool> pickup(CircleListing listing) async {
    final catalog = _ref.read(marketplaceCatalogProvider);
    return catalog.pickup(listing.toMarketplaceListing());
  }

  /// Publish a vault Bro Code by name.
  Future<void> publishAgent(String agentName, {String license = 'remix_free'}) async {
    final registry = _ref.read(jsAgentRegistryProvider);
    final bundle = await registry.exportAgentBundle(agentName);
    if (bundle == null) throw Exception('Agent $agentName not found');
    final schema = Map<String, dynamic>.from(bundle['schema'] as Map? ?? {});
    final script = bundle['script'] as String? ?? '';
    final input = Map<String, dynamic>.from(schema['inputSchema'] as Map? ?? {});
    await publish(
      name: agentName,
      description: schema['description'] as String? ?? agentName,
      script: script,
      inputSchema: input,
      license: license,
      parentRevisionId: schema['parentRevisionId'] as String?,
    );
  }
}

final circleRegistryProvider = Provider<CircleRegistryService>((ref) {
  return CircleRegistryService(ref);
});
