import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'bhai_code_access.dart';
import 'bhai_code_origin.dart';
import 'js_agent_registry.dart';
import 'marketplace_catalog.dart';
import 'secure_secret_store.dart';
import 'telemetry_bus.dart';

/// Bhai Code bundle published to the Friend Circle GitHub registry (MVP-S10).
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
  final BhaiCodeAccess access;

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
    this.access = BhaiCodeAccess.defaults,
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
    'access': access.toJson(),
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
      access: BhaiCodeAccess.fromJson(
        json['access'] is Map
            ? Map<String, dynamic>.from(json['access'] as Map)
            : null,
      ),
    );
  }

  MarketplaceListing toMarketplaceListing() => MarketplaceListing(
    id: id,
    name: name,
    description: description,
    script: script,
    inputSchema: inputSchema,
    license: license,
    author: author,
    access: access,
  );
}

/// GitHub Contents API client for multi-city circle share.
class CircleRegistryService {
  CircleRegistryService(this._ref, {SecureSecretStore? secretStore})
    : _secrets =
          secretStore ??
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
  bool get hasToken => _token.isNotEmpty;
  bool get isConfigured =>
      _owner.isNotEmpty && _repo.isNotEmpty && _token.isNotEmpty;

  Future<void> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _owner = prefs.getString(AppConfig.circlePrefsOwnerKey) ?? '';
    _repo =
        prefs.getString(AppConfig.circlePrefsRepoKey) ??
        AppConfig.circleDefaultRepo;
    _author = prefs.getString(AppConfig.circlePrefsAuthorKey) ?? 'circle-user';
    _token = await _secrets.read(AppConfig.circlePrefsTokenKey) ?? '';
  }

  /// GitHub login for the current PAT (`GET /user`). Null if unavailable.
  Future<String?> fetchTokenLogin() async {
    if (_token.isEmpty) return null;
    final res = await _http.get(
      Uri.parse('https://api.github.com/user'),
      headers: _headers,
    );
    if (res.statusCode != 200) return null;
    final login = (jsonDecode(res.body) as Map<String, dynamic>)['login'];
    return login is String && login.trim().isNotEmpty ? login.trim() : null;
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
    _author = authorDisplay.trim().isEmpty
        ? 'circle-user'
        : authorDisplay.trim();
    final incoming = token.trim();
    final existing = await _secrets.read(AppConfig.circlePrefsTokenKey) ?? '';
    // Empty PAT field means "keep stored token" — never wipe on blank re-save.
    final tokenChanged = incoming.isNotEmpty;
    if (tokenChanged) {
      _token = incoming;
      await _secrets.write(AppConfig.circlePrefsTokenKey, _token);
    } else {
      _token = existing;
    }
    if (_owner.isEmpty && _token.isNotEmpty) {
      final login = await fetchTokenLogin();
      if (login != null) {
        _owner = login;
      }
    }
    await prefs.setString(AppConfig.circlePrefsOwnerKey, _owner);
    await prefs.setString(AppConfig.circlePrefsRepoKey, _repo);
    await prefs.setString(AppConfig.circlePrefsAuthorKey, _author);
  }

  Future<void> clearToken() async {
    _token = '';
    await _secrets.delete(AppConfig.circlePrefsTokenKey);
  }

  /// Probes GitHub with the stored owner/repo/token. Returns a short status.
  Future<String> verifyConnection() async {
    await loadConfig();
    if (!isConfigured) {
      throw Exception(
        'Configure circle GitHub owner / repo / token in Settings first.',
      );
    }
    // Prove the PAT itself first — 404 on the repo is often "no access", not a bad token.
    final userRes = await _http.get(
      Uri.parse('https://api.github.com/user'),
      headers: _headers,
    );
    if (userRes.statusCode == 401 || userRes.statusCode == 403) {
      throw Exception(AppConfig.circleAuthFailedHint);
    }
    if (userRes.statusCode != 200) {
      throw Exception('PAT check failed: HTTP ${userRes.statusCode}');
    }
    final login = (jsonDecode(userRes.body) as Map<String, dynamic>)['login'];
    final loginStr = login is String ? login : '?';

    final res = await _http.get(
      Uri.parse('https://api.github.com/repos/$_owner/$_repo'),
      headers: _headers,
    );
    if (res.statusCode == 200) {
      return '$_owner/$_repo reachable (PAT @$loginStr)';
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw Exception(AppConfig.circleAuthFailedHint);
    }
    if (res.statusCode == 404) {
      throw Exception(
        'PAT is valid (@$loginStr) but cannot see $_owner/$_repo (HTTP 404). '
        'Check: (1) owner/repo match the GitHub URL exactly, '
        '(2) fine-grained PAT → Repository access includes this private repo, '
        '(3) Contents + Issues permissions enabled for that repo.',
      );
    }
    throw Exception('Circle verify failed: HTTP ${res.statusCode}');
  }

  Uri _contentsUri(String path) =>
      Uri.parse('https://api.github.com/repos/$_owner/$_repo/contents/$path');

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
      final contentB64 = (body['content'] as String? ?? '').replaceAll(
        '\n',
        '',
      );
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
    BhaiCodeAccess access = BhaiCodeAccess.defaults,
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
      access: access,
    );
    final bundlePath = '${AppConfig.circleBundleDir}/$id/bundle.json';
    await _putFile(
      path: bundlePath,
      content: jsonEncode(listing.toBundleJson()),
      message: 'Publish Bhai Code $name ($revisionId)',
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
            (jsonDecode(existing.body) as Map<String, dynamic>)['sha']
                as String?;
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
    final ok = await catalog.pickup(listing.toMarketplaceListing());
    if (!ok) return false;
    // Override pool source set by catalog with Friend Circle provenance.
    final registry = _ref.read(jsAgentRegistryProvider);
    final telemetry = _ref.read(telemetryBusProvider);
    final schemaEntry = await telemetry.readVaultData(
      registry.schemaKeyFor(listing.name),
    );
    if (schemaEntry != null) {
      final schema = Map<String, dynamic>.from(
        jsonDecode(schemaEntry['value']!) as Map,
      );
      schema['source'] = BhaiCodeOrigin.friendCircle;
      await telemetry.writeVaultData(
        registry.schemaKeyFor(listing.name),
        jsonEncode(schema),
        mimeType: 'application/json',
      );
    }
    await registry.loadAndRegisterAgents();
    return true;
  }

  /// Publish a vault Bhai Code by name.
  Future<void> publishAgent(
    String agentName, {
    String license = 'remix_free',
    BhaiCodeAccess access = BhaiCodeAccess.defaults,
  }) async {
    final registry = _ref.read(jsAgentRegistryProvider);
    final bundle = await registry.exportAgentBundle(agentName);
    if (bundle == null) throw Exception('Agent $agentName not found');
    final schema = Map<String, dynamic>.from(bundle['schema'] as Map? ?? {});
    final script = bundle['script'] as String? ?? '';
    final input = Map<String, dynamic>.from(
      schema['inputSchema'] as Map? ?? {},
    );
    await publish(
      name: agentName,
      description: schema['description'] as String? ?? agentName,
      script: script,
      inputSchema: input,
      license: license,
      parentRevisionId: schema['parentRevisionId'] as String?,
      access: access,
    );
  }
}

final circleRegistryProvider = Provider<CircleRegistryService>((ref) {
  return CircleRegistryService(ref);
});
