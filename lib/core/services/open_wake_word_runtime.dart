import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Path-based openWakeWord engine (uses the plugin's native lib).
///
/// The pub package [OpenWakeWord.init] only loads Flutter assets; downloads
/// live on disk, so we call `oww_init` with absolute paths.
class OpenWakeWordRuntime {
  OpenWakeWordRuntime._();

  static const _libName = 'open_wake_word';
  static DynamicLibrary? _dylib;
  static bool _ready = false;

  static DynamicLibrary _loadLib() {
    if (_dylib != null) return _dylib!;
    if (Platform.isAndroid || Platform.isLinux) {
      try {
        _dylib = DynamicLibrary.open('lib$_libName.so');
      } catch (_) {
        _dylib = DynamicLibrary.process();
      }
    } else if (Platform.isWindows) {
      _dylib = DynamicLibrary.open('$_libName.dll');
    } else if (Platform.isIOS || Platform.isMacOS) {
      _dylib = DynamicLibrary.process();
    } else {
      throw UnsupportedError('openWakeWord unsupported on this platform');
    }
    return _dylib!;
  }

  static bool get isReady => _ready;

  /// Initialize with filesystem paths (mel, embedding, one wake model).
  static bool initFromPaths({
    required String melPath,
    required String embPath,
    required String wwPath,
  }) {
    destroy();
    final lib = _loadLib();
    final init = lib
        .lookup<
          NativeFunction<
            Int Function(Pointer<Char>, Pointer<Char>, Pointer<Char>)
          >
        >('oww_init')
        .asFunction<int Function(Pointer<Char>, Pointer<Char>, Pointer<Char>)>();

    final mel = melPath.toNativeUtf8();
    final emb = embPath.toNativeUtf8();
    final ww = wwPath.toNativeUtf8();
    try {
      final code = init(mel.cast<Char>(), emb.cast<Char>(), ww.cast<Char>());
      _ready = code == 0;
      if (!_ready) {
        debugPrint('[OpenWakeWordRuntime] oww_init failed code=$code');
      }
      return _ready;
    } finally {
      calloc.free(mel);
      calloc.free(emb);
      calloc.free(ww);
    }
  }

  static double getProbability() {
    if (!_ready) return -1;
    try {
      final lib = _loadLib();
      final fn = lib
          .lookup<NativeFunction<Float Function()>>('oww_get_probability')
          .asFunction<double Function()>();
      return fn();
    } catch (_) {
      return -2;
    }
  }

  static void processAudio(Int16List audioData) {
    if (!_ready || audioData.isEmpty) return;
    final lib = _loadLib();
    final process = lib
        .lookup<NativeFunction<Void Function(Pointer<Int16>, Int)>>(
          'oww_process_audio',
        )
        .asFunction<void Function(Pointer<Int16>, int)>();
    final ptr = calloc<Int16>(audioData.length);
    ptr.asTypedList(audioData.length).setAll(0, audioData);
    try {
      process(ptr, audioData.length);
    } finally {
      calloc.free(ptr);
    }
  }

  static bool isActivated() {
    if (!_ready) return false;
    final lib = _loadLib();
    final fn = lib
        .lookup<NativeFunction<Bool Function()>>('oww_is_activated')
        .asFunction<bool Function()>();
    return fn();
  }

  static void destroy() {
    if (_dylib == null) {
      _ready = false;
      return;
    }
    try {
      final destroyFn = _dylib!
          .lookup<NativeFunction<Void Function()>>('oww_destroy')
          .asFunction<void Function()>();
      destroyFn();
    } catch (e) {
      debugPrint('[OpenWakeWordRuntime] destroy: $e');
    }
    _ready = false;
  }
}
