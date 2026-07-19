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
  Database? _sandboxDb;
  Timer? _purgeTimer;
  final Duration ttlDuration;
  final String databaseFileName;

  TelemetryBusService({
    this.ttlDuration = const Duration(hours: 24),
    this.databaseFileName = 'aur_bhai_telemetry_vault.db',
    SecureSecretStore? secretStore,
    bool enableVaultSeal = true,
  })  : _secretStore = secretStore ?? MemorySecureSecretStore(),
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
      version: 4,
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
      },
    );
    // Always repair: hot reload / stuck user_version can leave columns missing.
    await _ensureVaultBuildColumns(_db!);
    await _ensureVaultTtlColumn(_db!);

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
      await db.execute('ALTER TABLE sovereign_vault ADD COLUMN updated_at TEXT');
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
      await db.execute('ALTER TABLE sovereign_vault ADD COLUMN expires_at TEXT');
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
        compassDirection REAL
      )
    ''');
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

  /// Fictional cluster near 41.0°N, 74.0°W — not the user's location.
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
  ///
  /// Even while [isSandboxActive], never writes into `_sandboxDb`. Sandbox Bro
  /// Code must not call this; collectors and unit tests write real/fixture rows
  /// to the on-disk vault for dashboards only.
  Future<void> addRecord({
    required double latitude,
    required double longitude,
    required double accelerometerZ,
    required double compassDirection,
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
    );

    await _db!.insert(
      'telemetry',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    if (DateTime.now().second % 10 == 0) notifyListeners();
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
    final resolvedHash =
        (hash != null && hash.isNotEmpty) ? hash : vaultContentHash(value);
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
    await db.insert(
      'sovereign_vault',
      {
        'key': key,
        'value': value,
        'mime_type': mimeType,
        'updated_at': updatedAt,
        'content_hash': hash,
        'expires_at': expiresAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
    }).toList();
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
    return _rowToVaultMap({
      ...results.first,
      'key': key,
    });
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
    final expirationThreshold =
        DateTime.now().subtract(ttlDuration).toIso8601String();

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

  /// User-authored CSV dump of recent telemetry (ENG3 stretch — not a platform button).
  Future<String> exportTelemetryCsv({int limit = 500}) async {
    final rows = await getRecentRecords(limit);
    final buf = StringBuffer('id,timestamp,latitude,longitude,accelerometerZ,compassDirection\n');
    for (final r in rows) {
      buf.writeln(
        '${r.id},${r.timestamp.toIso8601String()},${r.latitude},${r.longitude},${r.accelerometerZ},${r.compassDirection}',
      );
    }
    return buf.toString();
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
    secretStore:
        inTest ? MemorySecureSecretStore() : FlutterSecureSecretStore(),
    // Sealing in parallel unit tests races on the shared default DB path.
    enableVaultSeal: !inTest,
  );
  ref.onDispose(() => bus.dispose());
  return bus;
});
