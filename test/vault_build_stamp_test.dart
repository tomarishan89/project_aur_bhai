import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';
import 'package:project_aur_bhai/core/services/vault_build_stamp.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('vaultContentHash is stable and changes with body', () {
    final a = vaultContentHash('<html>hello</html>');
    final b = vaultContentHash('<html>hello</html>');
    final c = vaultContentHash('<html>hello!</html>');
    expect(a, b);
    expect(a.length, 8);
    expect(a, isNot(c));
  });

  test(
    'injectHtmlBuildStamp inserts meta + badge; second inject is idempotent',
    () {
      const html = '''
<!DOCTYPE html><html><head><title>t</title></head>
<body><p>hi</p></body></html>
''';
      final once = injectHtmlBuildStamp(html, 'abc12345 · 2026-07-17 12:41');
      expect(once, contains('name="aur-bhai-build"'));
      expect(once, contains('content="abc12345 · 2026-07-17 12:41"'));
      expect(once, contains('id="aur-bhai-build"'));
      expect(once, contains('build abc12345 · 2026-07-17 12:41'));
      expect('name="aur-bhai-build"'.allMatches(once).length, 1);
      expect('id="aur-bhai-build"'.allMatches(once).length, 1);

      final twice = injectHtmlBuildStamp(once, 'deadbeef · 2026-07-17 13:00');
      expect('name="aur-bhai-build"'.allMatches(twice).length, 1);
      expect('id="aur-bhai-build"'.allMatches(twice).length, 1);
      expect(twice, contains('deadbeef · 2026-07-17 13:00'));
      expect(twice, isNot(contains('abc12345')));
    },
  );

  test('writeVaultData exposes matching build_id via read and list', () async {
    final bus = TelemetryBusService(
      databaseFileName:
          'vault_build_stamp_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    await bus.initialize();

    const body = '<html><head></head><body>Locator</body></html>';
    await bus.writeVaultData('locator.html', body, mimeType: 'text/html');

    final read = await bus.readVaultData('locator.html');
    expect(read, isNotNull);
    expect(read!['content_hash'], vaultContentHash(body));
    expect(read['build_id'], startsWith('${vaultContentHash(body)} · '));
    expect(read['updated_at'], isNotEmpty);

    final listed = await bus.listVaultEntries(mimeType: 'text/html');
    expect(listed, hasLength(1));
    expect(listed.first['build_id'], read['build_id']);
    expect(listed.first['content_hash'], read['content_hash']);
    expect(listed.first.containsKey('value'), isFalse);

    // Serve-time inject uses the same build id string.
    final stamped = injectHtmlBuildStamp(body, read['build_id']!);
    expect(stamped, contains('build ${read['build_id']}'));

    bus.dispose();
  });

  test('legacy row without hash still gets compute-on-read build_id', () async {
    final bus = TelemetryBusService(
      databaseFileName:
          'vault_build_legacy_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    await bus.initialize();

    const body = '<html>legacy</html>';
    // Insert without hash columns populated (simulate pre-v3 row after upgrade).
    await bus.database!.insert('sovereign_vault', {
      'key': 'old.html',
      'value': body,
      'mime_type': 'text/html',
      'updated_at': null,
      'content_hash': null,
    });

    final read = await bus.readVaultData('old.html');
    expect(read!['content_hash'], vaultContentHash(body));
    expect(read['build_id'], startsWith('${vaultContentHash(body)} · '));

    bus.dispose();
  });

  test('stuck v3 DB missing build columns is repaired on initialize', () async {
    final name = 'vault_stuck_v3_${DateTime.now().microsecondsSinceEpoch}.db';
    final path = join(await getDatabasesPath(), name);

    // Pretend user_version is already 3 but columns were never added.
    final raw = await openDatabase(
      path,
      version: 3,
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
    );
    await raw.close();

    final bus = TelemetryBusService(databaseFileName: name);
    await bus.initialize();

    await bus.writeVaultData(
      'agent:Locator:v8',
      'async function execute(){ return "ok"; }',
      mimeType: 'application/javascript',
    );
    final read = await bus.readVaultData('agent:Locator:v8');
    expect(read, isNotNull);
    expect(read!['content_hash'], isNotEmpty);
    expect(read['updated_at'], isNotEmpty);

    bus.dispose();
  });
}
