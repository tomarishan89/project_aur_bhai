import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

/// Pending Bro Code "call" — cue Aur Bhai, wait for Haan Bhai, then speak payload.
class BroCall {
  final String id;
  final String agentName;
  final String title;
  final String body;
  final String speakText;
  final DateTime createdAt;

  const BroCall({
    required this.id,
    required this.agentName,
    required this.title,
    required this.body,
    required this.speakText,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'agentName': agentName,
        'title': title,
        'body': body,
        'speakText': speakText,
        'createdAt': createdAt.toIso8601String(),
      };

  factory BroCall.fromJson(Map<String, dynamic> json) => BroCall(
        id: json['id'] as String? ?? '',
        agentName: json['agentName'] as String? ?? '',
        title: json['title'] as String? ?? '',
        body: json['body'] as String? ?? '',
        speakText: json['speakText'] as String? ?? '',
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now().toUtc(),
      );
}

/// Host-mediated Bro Code calls (S17). No silent cloud.
class BroCallService extends ChangeNotifier {
  static const _prefsKey = 'bro_calls_pending_v1';

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final List<BroCall> _pending = [];
  bool _ready = false;
  void Function(BroCall call)? onDeliverPayload;
  /// Optional TTS cue when a call is queued (host sets to speak “Aur Bhai”).
  void Function(BroCall call)? onCallQueued;

  List<BroCall> get pending => List.unmodifiable(_pending);
  BroCall? get nextPending => _pending.isEmpty ? null : _pending.first;

  bool _disposed = false;

  BroCallService() {
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
        _ready = true;
        await _load();
        return;
      }
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const ios = DarwinInitializationSettings();
      await _notifications.initialize(
        settings: const InitializationSettings(android: android, iOS: ios),
        onDidReceiveNotificationResponse: (resp) {
          unawaited(acknowledgeAndDeliver());
        },
      );
      final androidPlugin =
          _notifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          AppConfig.broCallChannelId,
          AppConfig.broCallChannelName,
          description: 'Alerts from Bhai Codes (tap or say Haan Bhai)',
          importance: Importance.high,
        ),
      );
      _ready = true;
      await _load();
      if (!_disposed) notifyListeners();
    } catch (e) {
      // Host tests / missing plugins: keep in-memory queue only.
      debugPrint('[BroCall] init: $e');
      _ready = false;
      await _load();
    }
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      _pending.clear();
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List;
      for (final e in list.whereType<Map>()) {
        _pending.add(BroCall.fromJson(Map<String, dynamic>.from(e)));
      }
    } catch (e) {
      debugPrint('[BroCall] load: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode(_pending.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[BroCall] persist: $e');
    }
  }

  /// Called from JS `System.notifyUser` (C2 agents).
  Future<BroCall> enqueue({
    required String agentName,
    required String title,
    required String body,
    String? speakText,
  }) async {
    if (!AppConfig.broCallFeatureEnabled) {
      throw Exception('Bro Call feature disabled');
    }
    final call = BroCall(
      id: 'call-${DateTime.now().microsecondsSinceEpoch}',
      agentName: agentName,
      title: title.trim().isEmpty ? 'Aur Bhai' : title.trim(),
      body: body.trim(),
      speakText: (speakText ?? body).trim(),
      createdAt: DateTime.now().toUtc(),
    );
    _pending.add(call);
    await _persist();
    notifyListeners();
    await _notify(call);
    onCallQueued?.call(call);
    return call;
  }

  Future<void> _notify(BroCall call) async {
    if (!_ready || kIsWeb) return;
    try {
      await _notifications.show(
        id: call.id.hashCode & 0x7fffffff,
        title: '${AppConfig.broCallCuePhrase}: ${call.title}',
        body: call.body.isEmpty
            ? 'Say ${AppConfig.broCallAckPhrase} to hear more'
            : call.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            AppConfig.broCallChannelId,
            AppConfig.broCallChannelName,
            channelDescription: 'Bhai Code calls',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: const DarwinNotificationDetails(),
        ),
        payload: call.id,
      );
    } catch (e) {
      debugPrint('[BroCall] notify: $e');
    }
  }

  /// User said Haan Bhai or tapped the notification — deliver speak payload.
  Future<BroCall?> acknowledgeAndDeliver() async {
    if (_pending.isEmpty) return null;
    final call = _pending.removeAt(0);
    await _persist();
    notifyListeners();
    onDeliverPayload?.call(call);
    return call;
  }

  /// True when [text] looks like the Haan Bhai ack while a call is pending.
  bool looksLikeAck(String text) {
    if (nextPending == null) return false;
    return textLooksLikeAck(text);
  }

  /// Pure ack phrase check (no pending-call requirement).
  static bool textLooksLikeAck(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return false;
    return t.contains('haan bhai') ||
        t == 'haan' ||
        t.contains('han bhai') ||
        t == 'yes';
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final broCallServiceProvider =
    ChangeNotifierProvider<BroCallService>((ref) {
  return BroCallService();
});
