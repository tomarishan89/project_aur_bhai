import 'dart:collection';
import 'dart:convert';

/// Compressed fine-window ring buffer for Path L ambient capture (S8 first rung).
class FineTelemetrySample {
  final DateTime at;
  final double latitude;
  final double longitude;
  final double accelerometerZ;
  final double compassDirection;
  // Extended sensor fields (optional — absent if sensor not available)
  final double? accelMagnitude;
  final double? gyroMagnitude;
  final double? pressure;
  final double? altitude;

  const FineTelemetrySample({
    required this.at,
    required this.latitude,
    required this.longitude,
    required this.accelerometerZ,
    required this.compassDirection,
    this.accelMagnitude,
    this.gyroMagnitude,
    this.pressure,
    this.altitude,
  });

  /// Lossy write-time compression: round coords / accel for storage.
  Map<String, dynamic> toCompressedJson() => {
    't': at.toUtc().millisecondsSinceEpoch,
    'lat': double.parse(latitude.toStringAsFixed(5)),
    'lng': double.parse(longitude.toStringAsFixed(5)),
    'z': double.parse(accelerometerZ.toStringAsFixed(2)),
    'h': double.parse(compassDirection.toStringAsFixed(1)),
    if (accelMagnitude != null)
      'am': double.parse(accelMagnitude!.toStringAsFixed(2)),
    if (gyroMagnitude != null)
      'gm': double.parse(gyroMagnitude!.toStringAsFixed(3)),
    if (pressure != null)
      'p': double.parse(pressure!.toStringAsFixed(1)),
    if (altitude != null)
      'alt': double.parse(altitude!.toStringAsFixed(1)),
  };

  factory FineTelemetrySample.fromCompressedJson(Map<String, dynamic> json) {
    return FineTelemetrySample(
      at: DateTime.fromMillisecondsSinceEpoch(
        (json['t'] as num?)?.toInt() ?? 0,
        isUtc: true,
      ),
      latitude: (json['lat'] as num?)?.toDouble() ?? 0,
      longitude: (json['lng'] as num?)?.toDouble() ?? 0,
      accelerometerZ: (json['z'] as num?)?.toDouble() ?? 0,
      compassDirection: (json['h'] as num?)?.toDouble() ?? 0,
      accelMagnitude: (json['am'] as num?)?.toDouble(),
      gyroMagnitude: (json['gm'] as num?)?.toDouble(),
      pressure: (json['p'] as num?)?.toDouble(),
      altitude: (json['alt'] as num?)?.toDouble(),
    );
  }
}

class FineTelemetryBuffer {
  FineTelemetryBuffer({this.window = const Duration(seconds: 45)});

  Duration window;
  final Queue<FineTelemetrySample> _ring = Queue();

  int get length => _ring.length;

  void push(FineTelemetrySample sample) {
    _ring.addLast(sample);
    final cutoff = DateTime.now().toUtc().subtract(window);
    while (_ring.isNotEmpty && _ring.first.at.isBefore(cutoff)) {
      _ring.removeFirst();
    }
  }

  List<FineTelemetrySample> snapshot() => List.unmodifiable(_ring);

  /// Compact JSON for vault candidate packs.
  String encodeSnapshot() =>
      jsonEncode(_ring.map((e) => e.toCompressedJson()).toList());
}
