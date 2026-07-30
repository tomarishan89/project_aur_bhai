import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../config/app_config.dart';

/// Keeps the process eligible for background mic while openWakeWord listens
/// (MS-OFFLINE-WAKE). Does not capture or persist audio itself.
@pragma('vm:entry-point')
void wakeForegroundStartCallback() {
  FlutterForegroundTask.setTaskHandler(_WakeListenTaskHandler());
}

class _WakeListenTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class WakeForegroundTask {
  WakeForegroundTask._();

  static bool _initialized = false;

  static Future<void> ensureInitialized() async {
    if (_initialized || kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      return;
    }
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'aur_bhai_wake_listen',
        channelName: 'Wake listen',
        channelDescription: AppConfig.wakeListenSubtitle,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
    _initialized = true;
  }

  static Future<void> start() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    await ensureInitialized();
    final notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
        notificationTitle: AppConfig.wakeWordPhraseLabel,
        notificationText: AppConfig.wakeListeningIndicator,
      );
      return;
    }
    await FlutterForegroundTask.startService(
      serviceId: 2607,
      serviceTypes: [ForegroundServiceTypes.microphone],
      notificationTitle: AppConfig.wakeWordPhraseLabel,
      notificationText: AppConfig.wakeListeningIndicator,
      callback: wakeForegroundStartCallback,
    );
  }

  static Future<void> stop() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}
