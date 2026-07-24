import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'agent_base.dart';
import '../services/telemetry_bus.dart';

/// The Driving Coach Agent demonstrates Alternative 3.
/// It reads from the Sovereign SQLite Telemetry Vault and applies the ML
/// thresholds extracted from the Python Scikit-learn model natively.
class DrivingCoachAgent extends AurBhaiAgent {
  final Ref ref;
  DrivingCoachAgent(this.ref);

  @override
  String get name => "DrivingCoach";

  @override
  String get description =>
      "Analyzes recent sensor telemetry from the SQLite vault to predict user movement state (Idle, Walking, Driving).";

  @override
  Map<String, AgentParameter> get inputSchema => {
    'recordCount': const AgentParameter(
      type: 'number',
      description:
          'The number of recent telemetry records to analyze (e.g. 10 or 50). Extract this from words like "recent", "last 10", etc. Default is 20 if omitted.',
      required: false,
    ),
  };

  @override
  Future<String> execute(Map<String, dynamic> parameters) async {
    final telemetryBus = ref.read(telemetryBusProvider);

    // Parse arguments
    int recordCount = 20;
    if (parameters['recordCount'] != null) {
      if (parameters['recordCount'] is num) {
        recordCount = (parameters['recordCount'] as num).toInt();
      } else if (parameters['recordCount'] is String) {
        recordCount = int.tryParse(parameters['recordCount']) ?? 20;
      }
    }

    // Query local SQLite Vault
    final records = await telemetryBus.getRecentRecords(recordCount);

    if (records.isEmpty) {
      return "I cannot analyze your movement. The SQLite telemetry vault is currently empty.";
    }

    if (records.length < 5) {
      return "I need a few more seconds of telemetry data to make an accurate prediction.";
    }

    // Calculate Variance of Accelerometer Z
    double sum = 0.0;
    for (var r in records) {
      sum += r.accelerometerZ;
    }
    double mean = sum / records.length;

    double varianceSum = 0.0;
    for (var r in records) {
      varianceSum += pow(r.accelerometerZ - mean, 2);
    }
    double variance = varianceSum / records.length;

    // Apply the Scikit-learn Model Logic trained in python_ml/telemetry_trainer.py
    // Thresholds extracted: idle_max: ~0.4, walk_max: ~1.8
    String prediction;
    if (variance <= 0.45) {
      prediction = "Idle";
    } else if (variance <= 1.85) {
      prediction = "Walking";
    } else {
      prediction = "Driving";
    }

    return "Based on your last ${records.length} sensor readings, your accelerometer variance is ${variance.toStringAsFixed(2)}. My model predicts you are currently $prediction.";
  }
}
