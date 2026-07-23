import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bhai_code_access.dart';
import 'marketplace_catalog.dart';

/// Deferred "test later" entry for Sandbox tab.
class SandboxQueueItem {
  final String id;
  final String name;
  final String description;
  final String script;
  final Map<String, dynamic> inputSchema;
  final String license;
  final String author;
  final BhaiCodeAccess access;
  final DateTime enqueuedAt;
  final String? lastResult;

  const SandboxQueueItem({
    required this.id,
    required this.name,
    required this.description,
    required this.script,
    this.inputSchema = const {},
    this.license = 'remix_free',
    this.author = '',
    this.access = BhaiCodeAccess.defaults,
    required this.enqueuedAt,
    this.lastResult,
  });

  MarketplaceListing toListing() => MarketplaceListing(
        id: id,
        name: name,
        description: description,
        script: script,
        inputSchema: inputSchema,
        license: license,
        author: author,
        access: access,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'script': script,
        'inputSchema': inputSchema,
        'license': license,
        'author': author,
        'access': access.toJson(),
        'enqueuedAt': enqueuedAt.toUtc().toIso8601String(),
        'lastResult': lastResult,
      };

  factory SandboxQueueItem.fromJson(Map<String, dynamic> json) {
    return SandboxQueueItem(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      script: json['script'] as String? ?? '',
      inputSchema: Map<String, dynamic>.from(
        (json['inputSchema'] as Map?) ?? const {},
      ),
      license: json['license'] as String? ?? 'remix_free',
      author: json['author'] as String? ?? '',
      access: BhaiCodeAccess.fromJson(
        json['access'] is Map
            ? Map<String, dynamic>.from(json['access'] as Map)
            : null,
      ),
      enqueuedAt: DateTime.tryParse(json['enqueuedAt'] as String? ?? '') ??
          DateTime.now().toUtc(),
      lastResult: json['lastResult'] as String?,
    );
  }

  factory SandboxQueueItem.fromListing(MarketplaceListing listing) {
    return SandboxQueueItem(
      id: listing.id,
      name: listing.name,
      description: listing.description,
      script: listing.script,
      inputSchema: listing.inputSchema,
      license: listing.license,
      author: listing.author,
      access: listing.access,
      enqueuedAt: DateTime.now().toUtc(),
    );
  }

  SandboxQueueItem copyWith({String? lastResult}) => SandboxQueueItem(
        id: id,
        name: name,
        description: description,
        script: script,
        inputSchema: inputSchema,
        license: license,
        author: author,
        access: access,
        enqueuedAt: enqueuedAt,
        lastResult: lastResult ?? this.lastResult,
      );
}

/// Persisted Sandbox "test later" queue.
class SandboxQueueService extends ChangeNotifier {
  static const _prefsKey = 'sandbox_test_later_v1';

  final List<SandboxQueueItem> _items = [];
  bool _loaded = false;

  List<SandboxQueueItem> get items => List.unmodifiable(_items);
  bool get isLoaded => _loaded;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    _items.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        for (final e in list.whereType<Map>()) {
          _items.add(
            SandboxQueueItem.fromJson(Map<String, dynamic>.from(e)),
          );
        }
      } catch (e) {
        debugPrint('[SandboxQueue] load error: $e');
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_items.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> enqueue(MarketplaceListing listing) async {
    if (!_loaded) await load();
    _items.removeWhere((e) => e.id == listing.id || e.name == listing.name);
    _items.insert(0, SandboxQueueItem.fromListing(listing));
    await _persist();
    notifyListeners();
  }

  Future<void> setLastResult(String id, String result) async {
    final i = _items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    _items[i] = _items[i].copyWith(lastResult: result);
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _items.removeWhere((e) => e.id == id);
    await _persist();
    notifyListeners();
  }
}

final sandboxQueueProvider =
    ChangeNotifierProvider<SandboxQueueService>((ref) {
  final q = SandboxQueueService();
  unawaited(q.load());
  return q;
});
