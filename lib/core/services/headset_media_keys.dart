import 'package:flutter/services.dart';

/// Maps Android media controls to tap / hold / cancel handshake paths.
///
/// Play/Pause/Next from earbuds, car wheel, or headset remotes arrive via
/// native [MediaSession] (not Flutter [HardwareKeyboard]). Keyboard remains a
/// secondary path. iOS capture is not implemented.
class HeadsetMediaKeys {
  static const _channel = MethodChannel('aur_bhai/headset');

  HeadsetMediaKeys({
    required this.onShortPress,
    required this.onLongPressStart,
    required this.onLongPressEnd,
    required this.onCancel,
    this.longPressMs = 400,
  });

  final VoidCallback onShortPress;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressEnd;
  final VoidCallback onCancel;
  final int longPressMs;

  bool _armed = false;
  bool _longFired = false;
  DateTime? _downAt;
  bool _listening = false;

  void attach() {
    if (_listening) return;
    HardwareKeyboard.instance.addHandler(_onKey);
    _channel.setMethodCallHandler(_onPlatform);
    _listening = true;
    _setNativeCapture(true);
  }

  void detach() {
    if (!_listening) return;
    HardwareKeyboard.instance.removeHandler(_onKey);
    _channel.setMethodCallHandler(null);
    _setNativeCapture(false);
    _listening = false;
  }

  Future<void> _setNativeCapture(bool enabled) async {
    try {
      await _channel.invokeMethod('setCaptureEnabled', {'enabled': enabled});
    } catch (_) {
      // Native channel unavailable (e.g. tests / non-Android).
    }
  }

  Future<void> _onPlatform(MethodCall call) async {
    if (call.method != 'headsetEvent') return;
    final args = call.arguments;
    if (args is! Map) return;
    final event = args['event']?.toString() ?? '';
    if (event == 'short') {
      onShortPress();
    } else if (event == 'longStart') {
      onLongPressStart();
    } else if (event == 'longEnd') {
      onLongPressEnd();
    } else if (event == 'cancel') {
      onCancel();
    }
  }

  bool _isHeadsetKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.headsetHook ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPause ||
        key == LogicalKeyboardKey.select;
  }

  bool _onKey(KeyEvent event) {
    if (!_isHeadsetKey(event.logicalKey)) return false;

    if (event is KeyDownEvent) {
      if (_armed) {
        onCancel();
        _reset();
        return true;
      }
      _armed = true;
      _longFired = false;
      _downAt = DateTime.now();
      Future<void>.delayed(Duration(milliseconds: longPressMs), () {
        if (!_armed || _longFired) return;
        final down = _downAt;
        if (down == null) return;
        if (DateTime.now().difference(down).inMilliseconds >= longPressMs) {
          _longFired = true;
          onLongPressStart();
        }
      });
      return true;
    }

    if (event is KeyUpEvent && _armed) {
      if (_longFired) {
        onLongPressEnd();
      } else {
        onShortPress();
      }
      _reset();
      return true;
    }
    return false;
  }

  void _reset() {
    _armed = false;
    _longFired = false;
    _downAt = null;
  }
}
