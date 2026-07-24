import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keystore-backed string store (ENG5). Memory backend for unit tests.
abstract class SecureSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class MemorySecureSecretStore implements SecureSecretStore {
  final Map<String, String> _map = {};

  @override
  Future<String?> read(String key) async => _map[key];

  @override
  Future<void> write(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _map.remove(key);
  }
}

class FlutterSecureSecretStore implements SecureSecretStore {
  FlutterSecureSecretStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      debugPrint('[SecureSecretStore] read error: $e');
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      debugPrint('[SecureSecretStore] write error: $e');
      rethrow;
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      debugPrint('[SecureSecretStore] delete error: $e');
    }
  }
}
