import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'secure_secret_store.dart';
import 'sql_query_guard.dart';
import 'vault_build_stamp.dart';
import 'vault_file_cipher.dart';

class TelemetryRecord {
  final String id;
  final DateTime timestamp;
  final double latitude;
  final double longitude;
  // Legacy alias — same value as accelZ. Kept for backward compat with Bro Code.
  final double accelerometerZ;
  final double compassDirection;

  // Raw accelerometer (includes gravity), m/s²
  final double? accelX;
  final double? accelY;
  final double? accelZ;
  final double? accelMagnitude;

  // User accelerometer (gravity removed), m/s²
  final double? userAccelX;
  final double? userAccelY;
  final double? userAccelZ;

  // Gyroscope, rad/s
  final double? gyroX;
  final double? gyroY;
  final double? gyroZ;
  final double? gyroMagnitude;

  // Magnetometer, µT
  final double? magX;
  final double? magY;
  final double? magZ;

  // Barometer, hPa
  final double? pressure;

  // GPS extended fields
  final double? altitude;
  final double? altitudeAccuracy;
  final double? speed;
  final double? speedAccuracy;
  final double? gpsAccuracy;
  final double? headingAccuracy;
  final int? floor;
  final int? isMocked;

  TelemetryRecord({
    required this.id,
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.accelerometerZ,
    required this.compassDirection,
    this.accelX,
    this.accelY,
    this.accelZ,
    this.accelMagnitude,
    this.userAccelX,
    this.userAccelY,
    this.userAccelZ,
    this.gyroX,
    this.gyroY,
    this.gyroZ,
    this.gyroMagnitude,
    this.magX,
    this.magY,
    this.magZ,
    this.pressure,
    this.altitude,
    this.altitudeAccuracy,
    this.speed,
    this.speedAccuracy,
    this.gpsAccuracy,
    this.headingAccuracy,
    this.floor,
    this.isMocked,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'timestamp': timestamp.toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
      'accelerometerZ': accelerometerZ,
      'compassDirection': compassDirection,
      'accel_x': accelX,
      'accel_y': accelY,
      'accel_z': accelZ,
      'accel_magnitude': accelMagnitude,
      'user_accel_x': userAccelX,
      'user_accel_y': userAccelY,
      'user_accel_z': userAccelZ,
      'gyro_x': gyroX,
      'gyro_y': gyroY,
      'gyro_z': gyroZ,
      'gyro_magnitude': gyroMagnitude,
      'mag_x': magX,
      'mag_y': magY,
      'mag_z': magZ,
      'pressure': pressure,
      'altitude': altitude,
      'altitude_accuracy': altitudeAccuracy,
      'speed': speed,
      'speed_accuracy': speedAccuracy,
      'gps_accuracy': gpsAccuracy,
      'heading_accuracy': headingAccuracy,
      'floor': floor,
      'is_mocked': isMocked,
    };
  }

  factory TelemetryRecord.fromMap(Map<String, dynamic> map) {
    final accelZ = (map['accel_z'] as num?)?.toDouble() ??
        (map['accelerometerZ'] as num?)?.toDouble() ?? 9.8;
    return TelemetryRecord(
      id: map['id'] as String,
      timestamp: DateTime.parse(map['timestamp'] as String),
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      accelerometerZ: accelZ,
      compassDirection: (map['compassDirection'] as num).toDouble(),
      accelX: (map['accel_x'] as num?)?.toDouble(),
      accelY: (map['accel_y'] as num?)?.toDouble(),
      accelZ: accelZ,
      accelMagnitude: (map['accel_magnitude'] as num?)?.toDouble(),
      userAccelX: (map['user_accel_x'] as num?)?.toDouble(),
      userAccelY: (map['user_accel_y'] as num?)?.toDouble(),
      userAccelZ: (map['user_accel_z'] as num?)?.toDouble(),
      gyroX: (map['gyro_x'] as num?)?.toDouble(),
      gyroY: (map['gyro_y'] as num?)?.toDouble(),
      gyroZ: (map['gyro_z'] as num?)?.toDouble(),
      gyroMagnitude: (map['gyro_magnitude'] as num?)?.toDouble(),
      magX: (map['mag_x'] as num?)?.toDouble(),
      magY: (map['mag_y'] as num?)?.toDouble(),
      magZ: (map['mag_z'] as num?)?.toDouble(),
      pressure: (map['pressure'] as num?)?.toDouble(),
      altitude: (map['altitude'] as num?)?.toDouble(),
      altitudeAccuracy: (map['altitude_accuracy'] as num?)?.toDouble(),
      speed: (map['speed'] as num?)?.toDouble(),
      speedAccuracy: (map['speed_accuracy'] as num?)?.toDouble(),
      gpsAccuracy: (map['gps_accuracy'] as num?)?.toDouble(),
      headingAccuracy: (map['heading_accuracy'] as num?)?.toDouble(),
      floor: (map['floor'] as num?)?.toInt(),
      isMocked: (map['is_mocked'] as num?)?.toInt(),
    );
  }
}

/// High-frequency IMU row (0.5 s default) — no GPS columns.
class ImuRecord {
  final String id;
  final int timestampMs; // ms since epoch — INTEGER for fast range queries
  final double? accelX;
  final double? accelY;
  final double? accelZ;
  final double? accelMagnitude;
  final double? userAccelX;
  final double? userAccelY;
  final double? userAccelZ;
  final double? gyroX;
  final double? gyroY;
  final double? gyroZ;
  final double? gyroMagnitude;
  final double? magX;
  final double? magY;
  final double? magZ;
  final double? pressure;

  ImuRecord({
    required this.id,
    required this.timestampMs,
    this.accelX,
    this.accelY,
    this.accelZ,
    this.accelMagnitude,
    this.userAccelX,
    this.userAccelY,
    this.userAccelZ,
    this.gyroX,
    this.gyroY,
    this.gyroZ,
    this.gyroMagnitude,
    this.magX,
    this.magY,
    this.magZ,
    this.pressure,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'timestamp': timestampMs,
    'accel_x': accelX,
    'accel_y': accelY,
    'accel_z': accelZ,
    'accel_magnitude': accelMagnitude,
    'user_accel_x': userAccelX,
    'user_accel_y': userAccelY,
    'user_accel_z': userAccelZ,
    'gyro_x': gyroX,
    'gyro_y': gyroY,
    'gyro_z': gyroZ,
    'gyro_magnitude': gyroMagnitude,
    'mag_x': magX,
    'mag_y': magY,
    'mag_z': magZ,
    'pressure': pressure,
  };
}

/// The Telemetry Bus Service manages the SQLite Sovereign Data Vault.
class TelemetryBusService extends ChangeNotifier {
  Database? _db;
  Database? _sandboxDb;
  Timer? _purgeTimer;
  final Duration ttlDuration;
  final String databaseFileName;

  TelemetryBusService({
    this.ttlDuration = const Duration(hours: 24),
    this.databaseFileName = 'aur_bhai_telemetry_vault.db',
    SecureSecretStore? secretStore,
    bool enableVaultSeal = true,
  }) : _secretStore = secretStore ?? MemorySecureSecretStore(),
       _enableVaultSeal = enableVaultSeal;

  final SecureSecretStore _secretStore;
  final bool _enableVaultSeal;
  VaultFileCipher? _cipher;
  String? _dbPath;

  /// True while Bro Code is executing against the in-memory sandbox vault.
  bool get isSandboxActive => _sandboxDb != null;

  /// True after a sealed archive exists beside the working DB (ENG5).
  bool get hasSealedArchive {
    final path = _dbPath;
    if (path == null || _cipher == null) return false;
    return File(_cipher!.sealedPathFor(path)).existsSync();
  }

  Future<void> initialize() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, databaseFileName);
    _dbPath = path;

    if (_enableVaultSeal) {
      _cipher = VaultFileCipher(_secretStore);
      // Restore from seal only when DB handle is closed. Never seal while open
      // (sqflite still holds the working file — partial seals corrupt next boot).
      await _cipher!.prepareWorkingCopy(path);
    }

    _db = await openDatabase(
      path,
      version: 5,
      onCreate: (db, version) async {
        await _createVaultSchema(db);
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
        if (oldVersion < 3) {
          await _ensureVaultBuildColumns(db);
        }
        if (oldVersion < 4) {
          await _ensureVaultTtlColumn(db);
        }
        if (oldVersion < 5) {
          await _ensureTelemetryColumns(db);
          await _ensureImuTable(db);
        }
      },
    );
    // Always repair: hot reload / stuck user_version can leave columns missing.
    await _ensureVaultBuildColumns(_db!);
    await _ensureVaultTtlColumn(_db!);
    await _ensureTelemetryColumns(_db!);
    await _ensureImuTable(_db!);
    await _ensureExpensesTable(_db!);

    debugPrint('[TelemetryBus] SQLite Sovereign Vault Initialized at $path');
    _startPurgeFirewall();
  }

  /// Idempotent: adds build-stamp columns if missing (safe on every boot).
  Future<void> _ensureVaultBuildColumns(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='sovereign_vault'",
    );
    if (tables.isEmpty) return;

    final info = await db.rawQuery('PRAGMA table_info(sovereign_vault)');
    final cols = info.map((r) => r['name'] as String).toSet();
    if (!cols.contains('updated_at')) {
      await db.execute(
        'ALTER TABLE sovereign_vault ADD COLUMN updated_at TEXT',
      );
      debugPrint('[TelemetryBus] Added sovereign_vault.updated_at');
    }
    if (!cols.contains('content_hash')) {
      await db.execute(
        'ALTER TABLE sovereign_vault ADD COLUMN content_hash TEXT',
      );
      debugPrint('[TelemetryBus] Added sovereign_vault.content_hash');
    }
  }

  Future<void> _ensureVaultTtlColumn(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='sovereign_vault'",
    );
    if (tables.isEmpty) return;
    final info = await db.rawQuery('PRAGMA table_info(sovereign_vault)');
    final cols = info.map((r) => r['name'] as String).toSet();
    if (!cols.contains('expires_at')) {
      await db.execute(
        'ALTER TABLE sovereign_vault ADD COLUMN expires_at TEXT',
      );
      debugPrint('[TelemetryBus] Added sovereign_vault.expires_at');
    }
  }

  Future<void> _createVaultSchema(Database db) async {
    await db.execute('''
      CREATE TABLE telemetry (
        id TEXT PRIMARY KEY,
        timestamp TEXT,
        latitude REAL,
        longitude REAL,
        accelerometerZ REAL,
        compassDirection REAL,
        accel_x REAL,
        accel_y REAL,
        accel_z REAL,
        accel_magnitude REAL,
        user_accel_x REAL,
        user_accel_y REAL,
        user_accel_z REAL,
        gyro_x REAL,
        gyro_y REAL,
        gyro_z REAL,
        gyro_magnitude REAL,
        mag_x REAL,
        mag_y REAL,
        mag_z REAL,
        pressure REAL,
        altitude REAL,
        altitude_accuracy REAL,
        speed REAL,
        speed_accuracy REAL,
        gps_accuracy REAL,
        heading_accuracy REAL,
        floor INTEGER,
        is_mocked INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE imu_telemetry (
        id TEXT PRIMARY KEY,
        timestamp INTEGER,
        accel_x REAL,
        accel_y REAL,
        accel_z REAL,
        accel_magnitude REAL,
        user_accel_x REAL,
        user_accel_y REAL,
        user_accel_z REAL,
        gyro_x REAL,
        gyro_y REAL,
        gyro_z REAL,
        gyro_magnitude REAL,
        mag_x REAL,
        mag_y REAL,
        mag_z REAL,
        pressure REAL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_imu_ts ON imu_telemetry(timestamp)',
    );
    await db.execute('''
      CREATE TABLE sovereign_vault (
        key TEXT PRIMARY KEY,
        value TEXT,
        mime_type TEXT,
        updated_at TEXT,
        content_hash TEXT,
        expires_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS expenses (
        id TEXT PRIMARY KEY,
        timestamp TEXT,
        item TEXT,
        amount REAL,
        category TEXT,
        note TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_expenses_ts ON expenses(timestamp)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_expenses_cat ON expenses(category)',
    );
  }

  Future<void> _ensureExpensesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS expenses (
        id TEXT PRIMARY KEY,
        timestamp TEXT,
        item TEXT,
        amount REAL,
        category TEXT,
        note TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_expenses_ts ON expenses(timestamp)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_expenses_cat ON expenses(category)',
    );
  }

  /// Idempotent: adds the 21 new sensor columns to the telemetry table if absent.
  Future<void> _ensureTelemetryColumns(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='telemetry'",
    );
    if (tables.isEmpty) return;
    final info = await db.rawQuery('PRAGMA table_info(telemetry)');
    final cols = info.map((r) => r['name'] as String).toSet();
    final newCols = {
      'accel_x': 'REAL',
      'accel_y': 'REAL',
      'accel_z': 'REAL',
      'accel_magnitude': 'REAL',
      'user_accel_x': 'REAL',
      'user_accel_y': 'REAL',
      'user_accel_z': 'REAL',
      'gyro_x': 'REAL',
      'gyro_y': 'REAL',
      'gyro_z': 'REAL',
      'gyro_magnitude': 'REAL',
      'mag_x': 'REAL',
      'mag_y': 'REAL',
      'mag_z': 'REAL',
      'pressure': 'REAL',
      'altitude': 'REAL',
      'altitude_accuracy': 'REAL',
      'speed': 'REAL',
      'speed_accuracy': 'REAL',
      'gps_accuracy': 'REAL',
      'heading_accuracy': 'REAL',
      'floor': 'INTEGER',
      'is_mocked': 'INTEGER',
    };
    for (final entry in newCols.entries) {
      if (!cols.contains(entry.key)) {
        try {
          await db.execute(
            'ALTER TABLE telemetry ADD COLUMN ${entry.key} ${entry.value} DEFAULT NULL',
          );
          debugPrint('[TelemetryBus] Added telemetry.${entry.key}');
        } catch (e) {
          debugPrint('[TelemetryBus] Skip column ${entry.key}: $e');
        }
      }
    }
  }

  /// Idempotent: creates imu_telemetry table if absent.
  Future<void> _ensureImuTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS imu_telemetry (
        id TEXT PRIMARY KEY,
        timestamp INTEGER,
        accel_x REAL,
        accel_y REAL,
        accel_z REAL,
        accel_magnitude REAL,
        user_accel_x REAL,
        user_accel_y REAL,
        user_accel_z REAL,
        gyro_x REAL,
        gyro_y REAL,
        gyro_z REAL,
        gyro_magnitude REAL,
        mag_x REAL,
        mag_y REAL,
        mag_z REAL,
        pressure REAL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_imu_ts ON imu_telemetry(timestamp)',
    );
  }

  /// Opens (or resets) an isolated in-memory DB for unverified Bro Code tests.
  ///
  /// **Invariant:** sandbox telemetry is synthetic fixture-only. Never copy
  /// sovereign GPS/accel rows into sandbox — marketplace / C4 / IMPROVE Bro
  /// Code must not see real device location history.
  Future<void> openSandbox({bool reset = true}) async {
    if (_sandboxDb != null && reset) {
      await _sandboxDb!.close();
      _sandboxDb = null;
    }
    if (_sandboxDb != null) return;

    _sandboxDb = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onCreate: (db, version) async {
        await _createVaultSchema(db);
      },
    );
    await _seedSandboxTelemetry(_sandboxDb!);
    debugPrint(
      '[TelemetryBus] Sandbox vault opened (in-memory, synthetic telemetry only)',
    );
  }

  /// Seed the sandbox with synthetic data including all new sensor columns.
  Future<void> _seedSandboxTelemetry(Database db) async {
    const baseLat = 41.0;
    const baseLng = -74.0;
    final now = DateTime.now();
    for (var i = 0; i < 8; i++) {
      await db.insert('telemetry', {
        'id': 'sandbox-seed-$i',
        'timestamp': now.subtract(Duration(seconds: i * 12)).toIso8601String(),
        'latitude': baseLat + (i * 0.0008),
        'longitude': baseLng + (i * 0.0006),
        'accelerometerZ': 9.5 + (i % 4) * 0.15,
        'accel_x': 0.1 * (i % 3 - 1),
        'accel_y': 0.05 * (i % 2),
        'accel_z': 9.5 + (i % 4) * 0.15,
        'accel_magnitude': 9.8,
        'user_accel_x': 0.0,
        'user_accel_y': 0.0,
        'user_accel_z': 0.0,
        'gyro_x': 0.01 * (i % 5),
        'gyro_y': 0.02 * (i % 3),
        'gyro_z': 0.005,
        'gyro_magnitude': 0.02,
        'mag_x': 25.0 + i,
        'mag_y': -12.0 + i * 0.5,
        'mag_z': 40.0,
        'pressure': 1013.25,
        'altitude': 200.0 + i * 2,
        'altitude_accuracy': 5.0,
        'speed': i * 0.5,
        'speed_accuracy': 0.3,
        'gps_accuracy': 3.0,
        'heading_accuracy': 5.0,
        'floor': null,
        'is_mocked': 0,
        'compassDirection': (i * 45.0) % 360.0,
      });
    }
  }

  Future<void> closeSandbox() async {
    if (_sandboxDb == null) return;
    await _sandboxDb!.close();
    _sandboxDb = null;
    debugPrint('[TelemetryBus] Sandbox vault closed');
  }

  Database? get _activeDb => _sandboxDb ?? _db;

  /// Live / test injector path — **sovereign `_db` only**.
  Future<void> addRecord({
    required double latitude,
    required double longitude,
    required double accelerometerZ,
    required double compassDirection,
    double? accelX,
    double? accelY,
    double? accelZ,
    double? accelMagnitude,
    double? userAccelX,
    double? userAccelY,
    double? userAccelZ,
    double? gyroX,
    double? gyroY,
    double? gyroZ,
    double? gyroMagnitude,
    double? magX,
    double? magY,
    double? magZ,
    double? pressure,
    double? altitude,
    double? altitudeAccuracy,
    double? speed,
    double? speedAccuracy,
    double? gpsAccuracy,
    double? headingAccuracy,
    int? floor,
    int? isMocked,
  }) async {
    if (_db == null) return;

    assert(
      !identical(_db, _sandboxDb),
      'addRecord must never target the sandbox DB',
    );

    final record = TelemetryRecord(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      timestamp: DateTime.now(),
      latitude: latitude,
      longitude: longitude,
      accelerometerZ: accelerometerZ,
      compassDirection: compassDirection,
      accelX: accelX,
      accelY: accelY,
      accelZ: accelZ,
      accelMagnitude: accelMagnitude,
      userAccelX: userAccelX,
      userAccelY: userAccelY,
      userAccelZ: userAccelZ,
      gyroX: gyroX,
      gyroY: gyroY,
      gyroZ: gyroZ,
      gyroMagnitude: gyroMagnitude,
      magX: magX,
      magY: magY,
      magZ: magZ,
      pressure: pressure,
      altitude: altitude,
      altitudeAccuracy: altitudeAccuracy,
      speed: speed,
      speedAccuracy: speedAccuracy,
      gpsAccuracy: gpsAccuracy,
      headingAccuracy: headingAccuracy,
      floor: floor,
      isMocked: isMocked,
    );

    await _db!.insert(
      'telemetry',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    if (DateTime.now().second % 10 == 0) notifyListeners();
  }

  /// Write a high-frequency IMU row to imu_telemetry (sovereign DB only).
  Future<void> addImuRecord(ImuRecord record) async {
    if (_db == null) return;
    await _db!.insert(
      'imu_telemetry',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Delete imu_telemetry rows older than [retention].
  Future<void> purgeOldImuRecords(Duration retention) async {
    if (_db == null) return;
    final cutoffMs =
        DateTime.now().subtract(retention).millisecondsSinceEpoch;
    final count = await _db!.delete(
      'imu_telemetry',
      where: 'timestamp < ?',
      whereArgs: [cutoffMs],
    );
    if (count > 0) {
      debugPrint('[TelemetryBus] Purged $count old IMU records');
    }
  }

  Future<List<TelemetryRecord>> getRecentRecords(int limit) async {
    if (_db == null) return [];

    final List<Map<String, dynamic>> maps = await _db!.query(
      'telemetry',
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return maps.map((e) => TelemetryRecord.fromMap(e)).toList();
  }

  Database? get database => _db;

  Database? get bridgeDatabase => _activeDb;

  /// Max rows returned to callers (bridge + `/api/query`).
  static const int queryRowCap = SqlQueryGuard.defaultMaxRows;

  Future<List<Map<String, dynamic>>> executeQuery(
    String sql, [
    List<dynamic>? arguments,
  ]) async {
    final db = _activeDb;
    if (db == null) return [];
    SqlQueryGuard.validate(sql, maxRows: queryRowCap);
    try {
      final rows = await db.rawQuery(sql, arguments);
      if (rows.length > queryRowCap) {
        return rows.sublist(0, queryRowCap);
      }
      return rows;
    } catch (e) {
      debugPrint('[TelemetryBus] Query Error: $e');
      rethrow;
    }
  }

  Map<String, String> _rowToVaultMap(Map<String, dynamic> row) {
    final value = row['value'] as String? ?? '';
    final mime = (row['mime_type'] as String?) ?? 'text/plain';
    final hash = row['content_hash'] as String?;
    final updatedAt = row['updated_at'] as String?;
    final resolvedHash = (hash != null && hash.isNotEmpty)
        ? hash
        : vaultContentHash(value);
    return {
      'key': row['key'] as String? ?? '',
      'value': value,
      'mime_type': mime,
      'updated_at': updatedAt ?? '',
      'content_hash': resolvedHash,
      'expires_at': row['expires_at'] as String? ?? '',
      'build_id': resolveVaultBuildId(
        value: value,
        contentHash: hash,
        updatedAtIso: updatedAt,
      ),
    };
  }

  bool _isExpired(String? expiresAtIso) {
    if (expiresAtIso == null || expiresAtIso.isEmpty) return false;
    final at = DateTime.tryParse(expiresAtIso);
    if (at == null) return false;
    return !at.toUtc().isAfter(DateTime.now().toUtc());
  }

  /// Write a string asset. Sandbox-active writes never touch the sovereign vault.
  ///
  /// [ttl] null = forever; otherwise expires_at = now + ttl (MS-TELEMETRY-DASHBOARD-UX3).
  Future<void> writeVaultData(
    String key,
    String value, {
    String mimeType = 'text/plain',
    Duration? ttl,
  }) async {
    final db = _activeDb;
    if (db == null) return;
    final hash = vaultContentHash(value);
    final updatedAt = DateTime.now().toUtc().toIso8601String();
    final expiresAt = ttl == null
        ? null
        : DateTime.now().toUtc().add(ttl).toIso8601String();
    await db.insert('sovereign_vault', {
      'key': key,
      'value': value,
      'mime_type': mimeType,
      'updated_at': updatedAt,
      'content_hash': hash,
      'expires_at': expiresAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    final target = _sandboxDb != null ? 'sandbox' : 'sovereign';
    debugPrint(
      '[TelemetryBus] Wrote $target vault asset: $key ($mimeType) build=$hash'
      '${expiresAt != null ? ' expires=$expiresAt' : ''}',
    );
  }

  /// Renew / extend TTL for an existing vault key (null = forever).
  Future<bool> setVaultTtl(String key, Duration? ttl) async {
    if (_db == null) return false;
    final expiresAt = ttl == null
        ? null
        : DateTime.now().toUtc().add(ttl).toIso8601String();
    final n = await _db!.update(
      'sovereign_vault',
      {'expires_at': expiresAt},
      where: 'key = ?',
      whereArgs: [key],
    );
    return n > 0;
  }

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

  /// List vault entries (key + mime + build stamp), optionally filtered by mime.
  /// Expired keys are omitted (and purged opportunistically).
  Future<List<Map<String, String>>> listVaultEntries({String? mimeType}) async {
    if (_db == null) return [];
    await purgeExpiredVaultAssets();

    final List<Map<String, dynamic>> results = await _db!.query(
      'sovereign_vault',
      columns: [
        'key',
        'value',
        'mime_type',
        'updated_at',
        'content_hash',
        'expires_at',
      ],
      where: mimeType != null ? 'mime_type = ?' : null,
      whereArgs: mimeType != null ? [mimeType] : null,
      orderBy: 'key ASC',
    );
    return results
        .where((r) => !_isExpired(r['expires_at'] as String?))
        .map(_rowToVaultMap)
        .map((m) {
          return {
            'key': m['key']!,
            'mime_type': m['mime_type']!,
            'updated_at': m['updated_at']!,
            'content_hash': m['content_hash']!,
            'build_id': m['build_id']!,
            'expires_at': m['expires_at'] ?? '',
          };
        })
        .toList();
  }

  Future<void> deleteVaultData(String key) async {
    if (_db == null) return;
    await _db!.delete('sovereign_vault', where: 'key = ?', whereArgs: [key]);
    debugPrint('[TelemetryBus] Deleted vault asset: $key');
  }

  /// Read dynamic string asset from the sovereign vault (includes build stamp).
  Future<Map<String, String>?> readVaultData(String key) async {
    if (_db == null) return null;
    final List<Map<String, dynamic>> results = await _db!.query(
      'sovereign_vault',
      where: 'key = ?',
      whereArgs: [key],
    );
    if (results.isEmpty) return null;
    if (_isExpired(results.first['expires_at'] as String?)) {
      await deleteVaultData(key);
      return null;
    }
    return _rowToVaultMap({...results.first, 'key': key});
  }

  void _startPurgeFirewall() {
    _purgeTimer?.cancel();
    _purgeTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      purgeExpiredRecords();
      unawaited(purgeExpiredVaultAssets());
    });
  }

  Future<void> purgeExpiredRecords() async {
    if (_db == null) return;
    final expirationThreshold = DateTime.now()
        .subtract(ttlDuration)
        .toIso8601String();

    final count = await _db!.delete(
      'telemetry',
      where: 'timestamp < ?',
      whereArgs: [expirationThreshold],
    );
    if (count > 0) {
      debugPrint(
        '[TelemetryPurgeFirewall] Purged $count expired records from SQLite.',
      );
    }
  }

  /// Delete vault assets past expires_at (dashboard TTL ENG4).
  Future<int> purgeExpiredVaultAssets() async {
    if (_db == null) return 0;
    final now = DateTime.now().toUtc().toIso8601String();
    final count = await _db!.delete(
      'sovereign_vault',
      where: "expires_at IS NOT NULL AND expires_at != '' AND expires_at <= ?",
      whereArgs: [now],
    );
    if (count > 0) {
      debugPrint('[TelemetryBus] Purged $count expired vault asset(s)');
    }
    return count;
  }

  /// User-authored CSV dump of recent telemetry.
  Future<String> exportTelemetryCsv({int limit = 500}) async {
    final rows = await getRecentRecords(limit);
    final buf = StringBuffer(
      'id,timestamp,latitude,longitude,accelerometerZ,compassDirection,'
      'accel_x,accel_y,accel_z,accel_magnitude,'
      'user_accel_x,user_accel_y,user_accel_z,'
      'gyro_x,gyro_y,gyro_z,gyro_magnitude,'
      'mag_x,mag_y,mag_z,pressure,'
      'altitude,altitude_accuracy,speed,speed_accuracy,'
      'gps_accuracy,heading_accuracy,floor,is_mocked\n',
    );
    for (final r in rows) {
      buf.writeln(
        '${r.id},${r.timestamp.toIso8601String()},${r.latitude},${r.longitude},'
        '${r.accelerometerZ},${r.compassDirection},'
        '${r.accelX ?? ""},${r.accelY ?? ""},${r.accelZ ?? ""},${r.accelMagnitude ?? ""},'
        '${r.userAccelX ?? ""},${r.userAccelY ?? ""},${r.userAccelZ ?? ""},'
        '${r.gyroX ?? ""},${r.gyroY ?? ""},${r.gyroZ ?? ""},${r.gyroMagnitude ?? ""},'
        '${r.magX ?? ""},${r.magY ?? ""},${r.magZ ?? ""},${r.pressure ?? ""},'
        '${r.altitude ?? ""},${r.altitudeAccuracy ?? ""},${r.speed ?? ""},${r.speedAccuracy ?? ""},'
        '${r.gpsAccuracy ?? ""},${r.headingAccuracy ?? ""},${r.floor ?? ""},${r.isMocked ?? ""}',
      );
    }
    return buf.toString();
  }

  // ── Expense Ledger Helpers ──────────────────────────────────────────────────

  Future<void> addExpense({
    required String item,
    required double amount,
    String? category,
    String? note,
    DateTime? timestamp,
    String? id,
  }) async {
    final effectiveDb = _sandboxDb ?? _db;
    if (effectiveDb == null) throw StateError('Vault DB not initialized');
    final ts = (timestamp ?? DateTime.now()).toIso8601String();
    final expenseId = id ?? 'exp-${DateTime.now().microsecondsSinceEpoch}';
    await effectiveDb.insert(
      'expenses',
      {
        'id': expenseId,
        'timestamp': ts,
        'item': item.trim(),
        'amount': amount,
        'category': (category ?? 'General').trim(),
        'note': (note ?? '').trim(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> getExpenses({
    int limit = 1000,
    String? category,
    DateTime? since,
  }) async {
    final effectiveDb = _sandboxDb ?? _db;
    if (effectiveDb == null) return [];
    final whereClauses = <String>[];
    final whereArgs = <dynamic>[];

    if (category != null && category.isNotEmpty && category != 'All') {
      whereClauses.add('category = ?');
      whereArgs.add(category);
    }
    if (since != null) {
      whereClauses.add('timestamp >= ?');
      whereArgs.add(since.toIso8601String());
    }

    return await effectiveDb.query(
      'expenses',
      where: whereClauses.isNotEmpty ? whereClauses.join(' AND ') : null,
      whereArgs: whereArgs.isNotEmpty ? whereArgs : null,
      orderBy: 'timestamp DESC',
      limit: limit,
    );
  }

  Future<void> deleteExpense(String id) async {
    final effectiveDb = _sandboxDb ?? _db;
    if (effectiveDb == null) return;
    await effectiveDb.delete(
      'expenses',
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyListeners();
  }

  Future<double> getTotalExpenses({String? category, DateTime? since}) async {
    final effectiveDb = _sandboxDb ?? _db;
    if (effectiveDb == null) return 0.0;
    final whereClauses = <String>[];
    final whereArgs = <dynamic>[];

    if (category != null && category.isNotEmpty && category != 'All') {
      whereClauses.add('category = ?');
      whereArgs.add(category);
    }
    if (since != null) {
      whereClauses.add('timestamp >= ?');
      whereArgs.add(since.toIso8601String());
    }

    final res = await effectiveDb.rawQuery(
      'SELECT SUM(amount) as total FROM expenses' +
          (whereClauses.isNotEmpty ? ' WHERE ${whereClauses.join(' AND ')}' : ''),
      whereArgs,
    );
    if (res.isEmpty) return 0.0;
    return (res.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  Future<void> closeAndSeal() async {
    _purgeTimer?.cancel();
    await _sandboxDb?.close();
    _sandboxDb = null;
    await _db?.close();
    _db = null;
    final path = _dbPath;
    final cipher = _cipher;
    if (_enableVaultSeal && path != null && cipher != null) {
      await cipher.sealWorkingCopy(path);
    }
  }

  @override
  void dispose() {
    unawaited(closeAndSeal());
    super.dispose();
  }
}

final telemetryBusProvider = Provider<TelemetryBusService>((ref) {
  final inTest = !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');
  final bus = TelemetryBusService(
    secretStore: inTest
        ? MemorySecureSecretStore()
        : FlutterSecureSecretStore(),
    // Sealing in parallel unit tests races on the shared default DB path.
    enableVaultSeal: !inTest,
  );
  ref.onDispose(() => bus.dispose());
  return bus;
});
