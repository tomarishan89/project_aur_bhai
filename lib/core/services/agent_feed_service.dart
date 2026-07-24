import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'js_agent_registry.dart';
import 'telemetry_bus.dart';

/// One runtime data entry pushed via "Tell <agent> that…" (MS-AGENT-FEED).
class AgentFeedEntry {
  final String id;
  final String text;
  final String source;
  final DateTime createdAt;
  final bool consumed;

  const AgentFeedEntry({
    required this.id,
    required this.text,
    required this.source,
    required this.createdAt,
    this.consumed = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'source': source,
    'createdAt': createdAt.toIso8601String(),
    'consumed': consumed,
  };

  factory AgentFeedEntry.fromJson(Map<String, dynamic> json) {
    return AgentFeedEntry(
      id: json['id'] as String? ?? '',
      text: json['text'] as String? ?? '',
      source: json['source'] as String? ?? 'voice',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      consumed: json['consumed'] as bool? ?? false,
    );
  }

  AgentFeedEntry copyWith({bool? consumed}) => AgentFeedEntry(
    id: id,
    text: text,
    source: source,
    createdAt: createdAt,
    consumed: consumed ?? this.consumed,
  );
}

/// Persistent per-agent inbox in the sovereign vault.
class AgentFeedService {
  AgentFeedService(this._ref);

  final Ref _ref;

  String inboxKeyFor(String agentName) =>
      '${JsAgentRegistry.vaultPrefix}$agentName:inbox';

  Future<List<AgentFeedEntry>> _load(String agentName) async {
    final bus = _ref.read(telemetryBusProvider);
    final row = await bus.readVaultData(inboxKeyFor(agentName));
    if (row == null) return [];
    try {
      final decoded = jsonDecode(row['value'] ?? '[]');
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => AgentFeedEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(String agentName, List<AgentFeedEntry> entries) async {
    final bus = _ref.read(telemetryBusProvider);
    await bus.writeVaultData(
      inboxKeyFor(agentName),
      jsonEncode(entries.map((e) => e.toJson()).toList()),
      mimeType: 'application/json',
    );
  }

  /// Push a tell/SMS-style entry. Returns the new entry id.
  Future<AgentFeedEntry> push({
    required String agentName,
    required String text,
    String source = 'voice',
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Feed text must not be empty');
    }
    final entries = await _load(agentName);
    final entry = AgentFeedEntry(
      id: 'feed-${DateTime.now().microsecondsSinceEpoch}',
      text: trimmed,
      source: source,
      createdAt: DateTime.now().toUtc(),
    );
    entries.add(entry);
    await _save(agentName, entries);
    return entry;
  }

  Future<List<AgentFeedEntry>> readInbox(
    String agentName, {
    bool unreadOnly = false,
    int? limit,
  }) async {
    var entries = await _load(agentName);
    if (unreadOnly) {
      entries = entries.where((e) => !e.consumed).toList();
    }
    if (limit != null && entries.length > limit) {
      entries = entries.sublist(entries.length - limit);
    }
    return entries;
  }

  /// Mark entries consumed (or all unread if [ids] is null/empty).
  Future<int> consume(String agentName, {List<String>? ids}) async {
    final entries = await _load(agentName);
    final idSet = ids == null || ids.isEmpty ? null : ids.toSet();
    var n = 0;
    final next = entries.map((e) {
      if (e.consumed) return e;
      if (idSet != null && !idSet.contains(e.id)) return e;
      n++;
      return e.copyWith(consumed: true);
    }).toList();
    if (n > 0) await _save(agentName, next);
    return n;
  }
}

final agentFeedServiceProvider = Provider<AgentFeedService>((ref) {
  return AgentFeedService(ref);
});
