import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

import 'secure_secret_store.dart';

/// AES-256-CBC + HMAC-SHA256 file seal for the sovereign SQLite DB (ENG5).
///
/// While the app runs the DB is open as a normal SQLite file. On boot, a
/// prior `*.sealed` archive is restored into the working path. After open
/// (and on close), the working file is re-sealed. The AES key lives in
/// [SecureSecretStore] (Android Keystore / iOS Keychain via flutter_secure_storage).
class VaultFileCipher {
  static const vaultKeySecureId = 'aur_bhai_vault_aes_key_v1';
  static const sealedSuffix = '.sealed';
  static const _magic = 'AURBHAIv1';

  VaultFileCipher(this._store);

  final SecureSecretStore _store;

  Future<Uint8List> getOrCreateKey() async {
    final existing = await _store.read(vaultKeySecureId);
    if (existing != null && existing.isNotEmpty) {
      return Uint8List.fromList(base64Decode(existing));
    }
    final key = Uint8List.fromList(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    await _store.write(vaultKeySecureId, base64Encode(key));
    return key;
  }

  String sealedPathFor(String dbPath) => '$dbPath$sealedSuffix';

  Future<void> prepareWorkingCopy(String dbPath) async {
    final sealed = File(sealedPathFor(dbPath));
    final working = File(dbPath);
    if (!await sealed.exists()) return;
    try {
      final key = await getOrCreateKey();
      final bytes = await sealed.readAsBytes();
      final plain = decryptBytes(bytes, key);
      await working.writeAsBytes(plain, flush: true);
    } catch (e) {
      // Corrupt / partial seal (e.g. written while SQLite still open) — drop it.
      await sealed.delete();
    }
  }

  Future<void> sealWorkingCopy(String dbPath) async {
    final working = File(dbPath);
    if (!await working.exists()) return;
    final key = await getOrCreateKey();
    final plain = await working.readAsBytes();
    final sealedBytes = encryptBytes(plain, key);
    await File(sealedPathFor(dbPath)).writeAsBytes(sealedBytes, flush: true);
  }

  Future<bool> migratePlaintextIfNeeded(String dbPath) async {
    final working = File(dbPath);
    final sealed = File(sealedPathFor(dbPath));
    if (!await working.exists()) return false;
    if (await sealed.exists()) return false;
    await sealWorkingCopy(dbPath);
    return true;
  }

  Uint8List encryptBytes(Uint8List plain, Uint8List keyBytes) {
    final key = enc.Key(keyBytes);
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
    final encrypted = encrypter.encryptBytes(plain, iv: iv);
    final mac = Hmac(sha256, keyBytes)
        .convert([...iv.bytes, ...encrypted.bytes])
        .bytes;
    final out = BytesBuilder();
    out.add(utf8.encode(_magic));
    out.add(iv.bytes);
    out.add(encrypted.bytes);
    out.add(mac);
    return out.toBytes();
  }

  Uint8List decryptBytes(Uint8List sealed, Uint8List keyBytes) {
    final magic = utf8.encode(_magic);
    if (sealed.length < magic.length + 16 + 32) {
      throw StateError('Sealed vault too short');
    }
    for (var i = 0; i < magic.length; i++) {
      if (sealed[i] != magic[i]) {
        throw StateError('Bad sealed vault magic');
      }
    }
    var offset = magic.length;
    final ivBytes = sealed.sublist(offset, offset + 16);
    offset += 16;
    final macStart = sealed.length - 32;
    final cipher = sealed.sublist(offset, macStart);
    final expectedMac = sealed.sublist(macStart);
    final actualMac =
        Hmac(sha256, keyBytes).convert([...ivBytes, ...cipher]).bytes;
    for (var i = 0; i < 32; i++) {
      if (actualMac[i] != expectedMac[i]) {
        throw StateError('Sealed vault integrity check failed');
      }
    }
    final key = enc.Key(keyBytes);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
    final decrypted = encrypter.decryptBytes(
      enc.Encrypted(Uint8List.fromList(cipher)),
      iv: enc.IV(Uint8List.fromList(ivBytes)),
    );
    return Uint8List.fromList(decrypted);
  }
}
