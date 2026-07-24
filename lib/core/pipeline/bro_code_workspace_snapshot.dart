import 'dart:convert';

import 'bro_code_workspace.dart';

/// One linear (optionally parent-linked) snapshot of a Bro Code workspace.
///
/// Lightweight Git alternative: full text states, no object hashing / branches.
class BroCodeWorkspaceSnapshot {
  final String id;
  final String? parentId;
  final String broCodeName;
  final DateTime createdAt;
  final String script;
  final Map<String, String> assets;
  final int turn;
  final String action;
  final String summary;
  final bool gatesGreen;

  const BroCodeWorkspaceSnapshot({
    required this.id,
    this.parentId,
    required this.broCodeName,
    required this.createdAt,
    required this.script,
    required this.assets,
    this.turn = 0,
    this.action = '',
    this.summary = '',
    this.gatesGreen = false,
  });

  BroCodeWorkspace toWorkspace({
    required String description,
    required Map<String, dynamic> inputSchema,
  }) => BroCodeWorkspace(
    name: broCodeName,
    description: description,
    inputSchema: inputSchema,
    script: script,
    assets: Map<String, String>.from(assets),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    if (parentId != null) 'parentId': parentId,
    'broCodeName': broCodeName,
    'createdAt': createdAt.toIso8601String(),
    'script': script,
    'assets': assets,
    'turn': turn,
    'action': action,
    'summary': summary,
    'gatesGreen': gatesGreen,
  };

  factory BroCodeWorkspaceSnapshot.fromJson(Map<String, dynamic> json) {
    final assetsRaw = json['assets'];
    final assets = <String, String>{};
    if (assetsRaw is Map) {
      assetsRaw.forEach((k, v) => assets[k.toString()] = v.toString());
    }
    return BroCodeWorkspaceSnapshot(
      id: json['id'] as String? ?? '',
      parentId: json['parentId'] as String?,
      broCodeName: json['broCodeName'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      script: json['script'] as String? ?? '',
      assets: assets,
      turn: json['turn'] as int? ?? 0,
      action: json['action'] as String? ?? '',
      summary: json['summary'] as String? ?? '',
      gatesGreen: json['gatesGreen'] as bool? ?? false,
    );
  }

  String toJsonString({bool pretty = false}) {
    if (pretty) {
      return const JsonEncoder.withIndent('  ').convert(toJson());
    }
    return jsonEncode(toJson());
  }
}

/// In-memory linear snapshot log (tests + agent loop). Cap prevents bloat.
class BroCodeSnapshotStore {
  static const int maxSnapshots = 40;

  final List<BroCodeWorkspaceSnapshot> _snapshots = [];
  String? _headId;

  List<BroCodeWorkspaceSnapshot> get snapshots => List.unmodifiable(_snapshots);

  String? get headId => _headId;

  BroCodeWorkspaceSnapshot? get head {
    if (_headId == null) return null;
    for (final s in _snapshots.reversed) {
      if (s.id == _headId) return s;
    }
    return _snapshots.isEmpty ? null : _snapshots.last;
  }

  /// Capture current workspace; returns the new snapshot.
  BroCodeWorkspaceSnapshot capture({
    required BroCodeWorkspace workspace,
    required String action,
    String summary = '',
    int turn = 0,
    bool gatesGreen = false,
    String? id,
  }) {
    final snap = BroCodeWorkspaceSnapshot(
      id:
          id ??
          'snap-${DateTime.now().microsecondsSinceEpoch}-'
              '${_snapshots.length + 1}',
      parentId: _headId,
      broCodeName: workspace.name,
      createdAt: DateTime.now(),
      script: workspace.script,
      assets: Map<String, String>.from(workspace.assets),
      turn: turn,
      action: action,
      summary: summary,
      gatesGreen: gatesGreen,
    );
    _snapshots.add(snap);
    _headId = snap.id;
    while (_snapshots.length > maxSnapshots) {
      _snapshots.removeAt(0);
    }
    return snap;
  }

  /// Move head to [id] and return that snapshot (for host undo / retry).
  BroCodeWorkspaceSnapshot? restore(String id) {
    for (final s in _snapshots) {
      if (s.id == id) {
        _headId = id;
        return s;
      }
    }
    return null;
  }

  /// Apply [snapshot] onto [workspace] (mutates script + assets).
  static void applyToWorkspace(
    BroCodeWorkspace workspace,
    BroCodeWorkspaceSnapshot snapshot,
  ) {
    workspace.script = snapshot.script;
    workspace.assets
      ..clear()
      ..addAll(snapshot.assets);
  }

  void clear() {
    _snapshots.clear();
    _headId = null;
  }

  /// Vault key for optional persistence of the full log.
  static String vaultIndexKey(String broCodeName) =>
      'brocode-snap-index:$broCodeName';

  Map<String, dynamic> toJson() => {
    'headId': _headId,
    'snapshots': _snapshots.map((s) => s.toJson()).toList(),
  };

  void loadFromJson(Map<String, dynamic> json) {
    clear();
    final list = json['snapshots'];
    if (list is List) {
      for (final item in list) {
        if (item is Map) {
          _snapshots.add(
            BroCodeWorkspaceSnapshot.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    _headId = json['headId'] as String?;
  }
}
