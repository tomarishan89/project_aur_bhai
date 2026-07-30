import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/wake_handshake_config.dart';

/// Installs / deletes free openWakeWord models; tracks the active model id.
class WakeModelLibrary {
  static const _prefsActive = 'wake_active_model_id';

  String _activeId = WakeHandshakeConfig.defaultWakeModelId;

  String get activeId => _activeId;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _activeId = WakeHandshakeConfig.normalizeWakeModelId(
      prefs.getString(_prefsActive),
    );
    await ensureBundledInstalled();
    if (!await isInstalled(_activeId)) {
      _activeId = WakeHandshakeConfig.defaultWakeModelId;
      await prefs.setString(_prefsActive, _activeId);
    }
  }

  Future<Directory> modelsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/wake/models');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> modelFile(String id) async {
    final spec = WakeHandshakeConfig.specForId(id);
    if (spec == null) {
      throw StateError('Unknown wake model: $id');
    }
    final dir = await modelsDir();
    return File('${dir.path}/${spec.fileName}');
  }

  Future<bool> isInstalled(String id) async {
    final spec = WakeHandshakeConfig.specForId(id);
    if (spec == null) return false;
    final f = await modelFile(id);
    return f.exists();
  }

  Future<int> installedBytes(String id) async {
    final f = await modelFile(id);
    if (!await f.exists()) return 0;
    return f.length();
  }

  /// Copy bundled default into documents.
  Future<void> ensureBundledInstalled() async {
    for (final spec in WakeHandshakeConfig.wakeCatalog) {
      if (!spec.bundled || spec.assetPath == null) continue;
      try {
        final dest = await modelFile(spec.id);
        if (await dest.exists()) continue;
        final data = await rootBundle.load(spec.assetPath!);
        await dest.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      } catch (e) {
        debugPrint('[WakeModelLibrary] ensureBundled ${spec.id}: $e');
      }
    }
  }

  /// Extract shared mel/embedding ONNX to documents (absolute paths for FFI).
  Future<({String mel, String emb})> ensureSharedPaths() async {
    final docs = await getApplicationDocumentsDirectory();
    final wakeDir = Directory('${docs.path}/wake');
    if (!await wakeDir.exists()) {
      await wakeDir.create(recursive: true);
    }

    Future<String> extract(String asset, String name) async {
      final out = File('${wakeDir.path}/$name');
      if (!await out.exists()) {
        final data = await rootBundle.load(asset);
        await out.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      return out.path;
    }

    final mel = await extract(
      WakeHandshakeConfig.melAssetPath,
      'melspectrogram.onnx',
    );
    final emb = await extract(
      WakeHandshakeConfig.embAssetPath,
      'embedding_model.onnx',
    );
    return (mel: mel, emb: emb);
  }

  Future<String> resolveActiveModelPath() async {
    await ensureBundledInstalled();
    final f = await modelFile(_activeId);
    if (!await f.exists()) {
      throw StateError('Active wake model missing: $_activeId');
    }
    return f.path;
  }

  Future<void> setActive(String id) async {
    final normalized = WakeHandshakeConfig.normalizeWakeModelId(id);
    if (!await isInstalled(normalized)) {
      throw StateError('Install the model before activating it.');
    }
    _activeId = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsActive, _activeId);
  }

  Future<void> download(String id, {void Function(double)? onProgress}) async {
    final spec = WakeHandshakeConfig.specForId(id);
    if (spec == null) throw StateError('Unknown wake model: $id');
    if (spec.bundled) {
      await ensureBundledInstalled();
      return;
    }
    final url = spec.downloadUrl;
    if (url == null) throw StateError('No download URL for $id');

    final dest = await modelFile(id);
    if (await dest.exists()) return;

    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      final res = await client.send(req);
      if (res.statusCode != 200) {
        throw HttpException('Download failed (${res.statusCode})');
      }
      final total = res.contentLength ?? 0;
      final sink = dest.openWrite();
      var received = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.close();
    } catch (e) {
      if (await dest.exists()) {
        try {
          await dest.delete();
        } catch (_) {}
      }
      debugPrint('[WakeModelLibrary] download $id failed: $e');
      rethrow;
    } finally {
      client.close();
    }
  }

  /// Delete a dormant installed model. Active / bundled defaults cannot be deleted.
  Future<void> delete(String id) async {
    final spec = WakeHandshakeConfig.specForId(id);
    if (spec == null) throw StateError('Unknown wake model: $id');
    if (spec.bundled) {
      throw StateError('Bundled wake model cannot be deleted.');
    }
    if (id == _activeId) {
      throw StateError('Switch active wake word before deleting.');
    }
    final f = await modelFile(id);
    if (await f.exists()) {
      await f.delete();
    }
  }

  List<WakeModelSpec> get catalog => WakeHandshakeConfig.wakeCatalog;
}
