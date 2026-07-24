import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

/// Result of a device authentication attempt (screen lock / biometrics).
class DeviceAuthResult {
  final bool success;
  final String? errorMessage;

  const DeviceAuthResult({required this.success, this.errorMessage});

  factory DeviceAuthResult.ok() => const DeviceAuthResult(success: true);

  factory DeviceAuthResult.fail(String message) =>
      DeviceAuthResult(success: false, errorMessage: message);
}

/// Gates sensitive actions (e.g. force-promote) with the device screen lock / biometrics.
class DeviceAuthService {
  final LocalAuthentication _auth = LocalAuthentication();

  /// Returns structured success/failure so the UI can keep the dialog open and show why.
  Future<DeviceAuthResult> authenticate({
    String reason = 'Confirm this action on your device',
  }) async {
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) {
        debugPrint('[DeviceAuth] Device auth not supported on this platform.');
        return DeviceAuthResult.fail(
          'This device does not support screen lock or biometric authentication.',
        );
      }
      final ok = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
      );
      if (ok) return DeviceAuthResult.ok();
      return DeviceAuthResult.fail(
        'Authentication cancelled or failed. Agent stays at C4.',
      );
    } on LocalAuthException catch (e) {
      debugPrint('[DeviceAuth] Authentication error: $e');
      return DeviceAuthResult.fail(_messageForLocalAuth(e));
    } catch (e) {
      debugPrint('[DeviceAuth] Authentication error: $e');
      final raw = e.toString();
      if (raw.contains('uiUnavailable') || raw.contains('FragmentActivity')) {
        return DeviceAuthResult.fail(
          'Device authentication UI is unavailable. Rebuild the app so MainActivity uses FlutterFragmentActivity, then try again.',
        );
      }
      return DeviceAuthResult.fail('Authentication error: $e');
    }
  }

  String _messageForLocalAuth(LocalAuthException e) {
    switch (e.code) {
      case LocalAuthExceptionCode.uiUnavailable:
        return 'Device authentication UI is unavailable. Rebuild the app so MainActivity uses FlutterFragmentActivity, then try again.';
      case LocalAuthExceptionCode.noCredentialsSet:
      case LocalAuthExceptionCode.noBiometricsEnrolled:
        return 'Set a screen lock or fingerprint on this device, then try again.';
      case LocalAuthExceptionCode.userCanceled:
      case LocalAuthExceptionCode.systemCanceled:
        return 'Authentication cancelled. Agent stays at C4.';
      default:
        return e.description ?? 'Authentication failed. Agent stays at C4.';
    }
  }
}

final deviceAuthServiceProvider = Provider<DeviceAuthService>((ref) {
  return DeviceAuthService();
});
