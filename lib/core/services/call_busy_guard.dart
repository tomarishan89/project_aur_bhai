import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Detects active/ringing phone calls so handshake does not barge in.
class CallBusyGuard {
  static const _channel = MethodChannel('aur_bhai/call_state');

  /// True when a cellular/VoIP-style call appears active (best-effort).
  static Future<bool> isBusy() async {
    if (kIsWeb) return false;
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    try {
      final state = await _channel.invokeMethod<String>('getCallBusy');
      return state == 'busy';
    } catch (e) {
      debugPrint('[CallBusyGuard] $e');
      return false;
    }
  }
}
