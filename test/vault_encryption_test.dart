import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_aur_bhai/core/services/secure_secret_store.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';
import 'package:project_aur_bhai/core/services/vault_file_cipher.dart';
import 'package:sqflite/sqflite.dart' show getDatabasesPath;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('VaultFileCipher round-trips bytes with integrity mac', () {
    final store = MemorySecureSecretStore();
    final cipher = VaultFileCipher(store);
    final key = List<int>.generate(32, (i) => i + 1);
    final plain = List<int>.generate(200, (i) => i % 251);
    final sealed = cipher.encryptBytes(
      Uint8List.fromList(plain),
      Uint8List.fromList(key),
    );
    expect(sealed.length, greaterThan(plain.length));
    final out = cipher.decryptBytes(sealed, Uint8List.fromList(key));
    expect(out, plain);
  });

  test('TelemetryBus seals working DB after close (ENG5)', () async {
    final store = MemorySecureSecretStore();
    final name = 'vault_seal_${DateTime.now().microsecondsSinceEpoch}.db';
    final bus = TelemetryBusService(
      databaseFileName: name,
      secretStore: store,
      enableVaultSeal: true,
    );
    await bus.initialize();
    await bus.addRecord(
      latitude: 1,
      longitude: 2,
      accelerometerZ: 3,
      compassDirection: 4,
    );
    // Seal only after close — while open there is no sealed archive yet.
    expect(bus.hasSealedArchive, isFalse);
    await bus.closeAndSeal();
    expect(bus.hasSealedArchive, isTrue);

    final dbPath = p.join(await getDatabasesPath(), name);
    final sealedPath = '$dbPath${VaultFileCipher.sealedSuffix}';
    expect(File(sealedPath).existsSync(), isTrue);
    final sealedBytes = await File(sealedPath).readAsBytes();
    expect(sealedBytes.length, greaterThan(32));
    expect(
      String.fromCharCodes(sealedBytes.take(15)),
      isNot(startsWith('SQLite format')),
    );

    // Boot #2 restores from seal with the same key store.
    final bus2 = TelemetryBusService(
      databaseFileName: name,
      secretStore: store,
      enableVaultSeal: true,
    );
    await bus2.initialize();
    final rows = await bus2.getRecentRecords(5);
    expect(rows, isNotEmpty);
    expect(rows.first.latitude, 1);
    await bus2.closeAndSeal();
  });
}
