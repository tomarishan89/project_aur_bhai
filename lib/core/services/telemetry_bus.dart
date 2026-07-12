import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class TelemetryRecord {
  final String id;
  final DateTime timestamp;
  final double latitude;
  final double longitude;
  final double accelerometerZ;
  final double compassDirection;

  TelemetryRecord({
    required this.id,
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.accelerometerZ,
    required this.compassDirection,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'timestamp': timestamp.toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
      'accelerometerZ': accelerometerZ,
      'compassDirection': compassDirection,
    };
  }

  factory TelemetryRecord.fromMap(Map<String, dynamic> map) {
    return TelemetryRecord(
      id: map['id'],
      timestamp: DateTime.parse(map['timestamp']),
      latitude: map['latitude'],
      longitude: map['longitude'],
      accelerometerZ: map['accelerometerZ'],
      compassDirection: map['compassDirection'],
    );
  }
}

/// The Telemetry Bus Service manages the SQLite Sovereign Data Vault.
class TelemetryBusService extends ChangeNotifier {
  Database? _db;
  Timer? _purgeTimer;
  final Duration ttlDuration;

  TelemetryBusService({this.ttlDuration = const Duration(hours: 24)});

  Future<void> initialize() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'aur_bhai_telemetry_vault.db');

    _db = await openDatabase(
      path,
      version: 2, // Bump to support dynamic vault tables
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE telemetry (
            id TEXT PRIMARY KEY,
            timestamp TEXT,
            latitude REAL,
            longitude REAL,
            accelerometerZ REAL,
            compassDirection REAL
          )
        ''');
        await db.execute('''
          CREATE TABLE sovereign_vault (
            key TEXT PRIMARY KEY,
            value TEXT,
            mime_type TEXT
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS sovereign_vault (
              key TEXT PRIMARY KEY,
              value TEXT,
              mime_type TEXT
            )
          ''');
        }
      },
    );
    debugPrint('[TelemetryBus] SQLite Sovereign Vault Initialized at $path');
    _startPurgeFirewall();
  }

  Future<void> addRecord({
    required double latitude,
    required double longitude,
    required double accelerometerZ,
    required double compassDirection,
  }) async {
    if (_db == null) return;
    
    final record = TelemetryRecord(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      timestamp: DateTime.now(),
      latitude: latitude,
      longitude: longitude,
      accelerometerZ: accelerometerZ,
      compassDirection: compassDirection,
    );

    await _db!.insert(
      'telemetry',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    
    // Notify listeners only occasionally to avoid flooding UI
    if (DateTime.now().second % 10 == 0) notifyListeners();
  }

  /// Query the last N records from the database
  Future<List<TelemetryRecord>> getRecentRecords(int limit) async {
    if (_db == null) return [];
    
    final List<Map<String, dynamic>> maps = await _db!.query(
      'telemetry',
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return maps.map((e) => TelemetryRecord.fromMap(e)).toList();
  }

  // Raw Database Getter for the JS Bridge & Agents
  Database? get database => _db;

  /// Generic SQLite query method for high-performance agent operations
  Future<List<Map<String, dynamic>>> executeQuery(String sql, [List<dynamic>? arguments]) async {
    if (_db == null) return [];
    try {
      return await _db!.rawQuery(sql, arguments);
    } catch (e) {
      debugPrint('[TelemetryBus] Query Error: $e');
      rethrow;
    }
  }

  /// Write dynamic string asset to the sovereign vault (e.g. dynamic HTML or generated code)
  Future<void> writeVaultData(String key, String value, {String mimeType = 'text/plain'}) async {
    if (_db == null) return;
    await _db!.insert(
      'sovereign_vault',
      {'key': key, 'value': value, 'mime_type': mimeType},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    debugPrint('[TelemetryBus] Wrote dynamic asset to Vault: $key ($mimeType)');
  }

  /// List vault keys, optionally filtered by prefix (e.g. `agent:`).
  Future<List<String>> listVaultKeys({String? prefix}) async {
    if (_db == null) return [];

    final List<Map<String, dynamic>> results = await _db!.query(
      'sovereign_vault',
      columns: ['key'],
      where: prefix != null ? 'key LIKE ?' : null,
      whereArgs: prefix != null ? ['$prefix%'] : null,
      orderBy: 'key ASC',
    );
    return results.map((row) => row['key'] as String).toList();
  }

  /// List vault entries (key + mime_type), optionally filtered by mime type.
  Future<List<Map<String, String>>> listVaultEntries({String? mimeType}) async {
    if (_db == null) return [];

    final List<Map<String, dynamic>> results = await _db!.query(
      'sovereign_vault',
      columns: ['key', 'mime_type'],
      where: mimeType != null ? 'mime_type = ?' : null,
      whereArgs: mimeType != null ? [mimeType] : null,
      orderBy: 'key ASC',
    );
    return results
        .map((row) => {
              'key': row['key'] as String,
              'mime_type': (row['mime_type'] as String?) ?? 'text/plain',
            })
        .toList();
  }

  /// Delete a dynamic asset from the sovereign vault.
  Future<void> deleteVaultData(String key) async {
    if (_db == null) return;
    await _db!.delete('sovereign_vault', where: 'key = ?', whereArgs: [key]);
    debugPrint('[TelemetryBus] Deleted vault asset: $key');
  }

  /// Read dynamic string asset from the sovereign vault
  Future<Map<String, String>?> readVaultData(String key) async {
    if (_db == null) return null;
    final List<Map<String, dynamic>> results = await _db!.query(
      'sovereign_vault',
      where: 'key = ?',
      whereArgs: [key],
    );
    if (results.isEmpty) return null;
    return {
      'value': results.first['value'] as String,
      'mime_type': results.first['mime_type'] as String,
    };
  }

  void _startPurgeFirewall() {
    _purgeTimer?.cancel();
    _purgeTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      purgeExpiredRecords();
    });
  }

  Future<void> purgeExpiredRecords() async {
    if (_db == null) return;
    final expirationThreshold = DateTime.now().subtract(ttlDuration).toIso8601String();
    
    final count = await _db!.delete(
      'telemetry',
      where: 'timestamp < ?',
      whereArgs: [expirationThreshold],
    );
    if (count > 0) {
      debugPrint('[TelemetryPurgeFirewall] Purged $count expired records from SQLite.');
    }
  }

  @override
  void dispose() {
    _purgeTimer?.cancel();
    _db?.close();
    super.dispose();
  }
}

final telemetryBusProvider = Provider<TelemetryBusService>((ref) {
  final bus = TelemetryBusService();
  ref.onDispose(() => bus.dispose());
  return bus;
});