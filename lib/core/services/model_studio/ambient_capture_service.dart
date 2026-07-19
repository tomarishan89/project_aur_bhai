import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;

import '../telemetry_bus.dart';
import 'fine_telemetry_buffer.dart';

/// Proposed Path L label awaiting user confirm/reject (S8).
class AmbientCaptureCandidate {
  final String id;
  final String agentName;
  final String proposedLabel;
  final String compressedSnapshot;
  final DateTime createdAt;
  final String? decision; // confirm | reject | null

  const AmbientCaptureCandidate({
    required this.id,
    required this.agentName,
    required this.proposedLabel,
    required this.compressedSnapshot,
    required this.createdAt,
    this.decision,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'agentName': agentName,
        'proposedLabel': proposedLabel,
        'compressedSnapshot': compressedSnapshot,
        'createdAt': createdAt.toIso8601String(),
        'decision': decision,
      };

  factory AmbientCaptureCandidate.fromJson(Map<String, dynamic> json) {
    return AmbientCaptureCandidate(
      id: json['id'] as String? ?? '',
      agentName: json['agentName'] as String? ?? '',
      proposedLabel: json['proposedLabel'] as String? ?? '',
      compressedSnapshot: json['compressedSnapshot'] as String? ?? '[]',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      decision: json['decision'] as String?,
    );
  }

  AmbientCaptureCandidate copyWith({String? decision}) =>
      AmbientCaptureCandidate(
        id: id,
        agentName: agentName,
        proposedLabel: proposedLabel,
        compressedSnapshot: compressedSnapshot,
        createdAt: createdAt,
        decision: decision ?? this.decision,
      );
}

/// Queues compressed fine-window snapshots for Path L labeling.
class AmbientCaptureService extends ChangeNotifier {
  AmbientCaptureService(this._ref);

  final Ref _ref;
  final FineTelemetryBuffer buffer = FineTelemetryBuffer();
  final List<AmbientCaptureCandidate> _pending = [];

  List<AmbientCaptureCandidate> get pending =>
      List.unmodifiable(_pending.where((c) => c.decision == null));

  void ingestSample({
    required double latitude,
    required double longitude,
    required double accelerometerZ,
    required double compassDirection,
  }) {
    buffer.push(FineTelemetrySample(
      at: DateTime.now().toUtc(),
      latitude: latitude,
      longitude: longitude,
      accelerometerZ: accelerometerZ,
      compassDirection: compassDirection,
    ));
  }

  /// Propose a label from the current fine buffer (Path H still owns runtime).
  Future<AmbientCaptureCandidate> propose({
    required String agentName,
    required String proposedLabel,
  }) async {
    final candidate = AmbientCaptureCandidate(
      id: 'cand-${DateTime.now().microsecondsSinceEpoch}',
      agentName: agentName,
      proposedLabel: proposedLabel,
      compressedSnapshot: buffer.encodeSnapshot(),
      createdAt: DateTime.now().toUtc(),
    );
    _pending.add(candidate);
    await _persist();
    notifyListeners();
    return candidate;
  }

  Future<void> decide(String id, {required bool confirm}) async {
    final i = _pending.indexWhere((c) => c.id == id);
    if (i < 0) return;
    _pending[i] =
        _pending[i].copyWith(decision: confirm ? 'confirm' : 'reject');
    await _persist();
    notifyListeners();
  }

  static const _vaultKey = 'model_studio:ambient_candidates';

  Future<void> _persist() async {
    final bus = _ref.read(telemetryBusProvider);
    await bus.writeVaultData(
      _vaultKey,
      jsonEncode(_pending.map((e) => e.toJson()).toList()),
      mimeType: 'application/json',
    );
  }

  Future<void> load() async {
    final bus = _ref.read(telemetryBusProvider);
    final row = await bus.readVaultData(_vaultKey);
    _pending.clear();
    if (row == null) return;
    try {
      final list = jsonDecode(row['value'] ?? '[]') as List;
      for (final e in list.whereType<Map>()) {
        _pending.add(
          AmbientCaptureCandidate.fromJson(Map<String, dynamic>.from(e)),
        );
      }
    } catch (e) {
      debugPrint('[AmbientCapture] load error: $e');
    }
    notifyListeners();
  }
}

final ambientCaptureProvider =
    ChangeNotifierProvider<AmbientCaptureService>((ref) {
  return AmbientCaptureService(ref);
});
