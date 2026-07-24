import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:quickjs_engine/quickjs_engine.dart';

import '../pipeline/bro_code_capability_judge.dart';
import 'agent_feed_service.dart';
import 'bro_call_service.dart';
import 'telemetry_bus.dart';

/// Outcome of a single JS agent sandbox run.
class AgentExecutionResult {
  final String message;
  final bool isError;
  final List<String> vaultHtmlKeysWritten;

  /// Side effects for capability judging (writeVault, sendHTTP, …).
  final BroCodeExecutionTrace trace;

  const AgentExecutionResult({
    required this.message,
    this.isError = false,
    this.vaultHtmlKeysWritten = const [],
    this.trace = const BroCodeExecutionTrace(),
  });
}

/// Result of a pre-save QuickJS syntax check.
class ScriptSyntaxCheck {
  final bool ok;
  final String? message;

  const ScriptSyntaxCheck.ok() : ok = true, message = null;
  const ScriptSyntaxCheck.fail(this.message) : ok = false;
}

/// Sandboxed QuickJS runtime exposing the Aur Bhai `System` bridge API.
class JsBridgeService {
  final TelemetryBusService _telemetry;
  final AgentFeedService? _feed;
  final BroCallService? _broCalls;

  JsBridgeService(
    this._telemetry, {
    AgentFeedService? this._feed,
    BroCallService? this._broCalls,
  });

  /// Parses [script] without calling execute — blocks save of broken JS.
  ScriptSyntaxCheck validateScriptSyntax(String script) {
    dynamic runtime;
    try {
      runtime = getJavascriptRuntime(xhr: false);
      final probe =
          '''
$script
;(typeof execute === 'function' ? 'ok' : 'missing_execute')
''';
      final result = runtime.evaluate(probe);
      final raw = result.stringResult as String;
      if (result.isError ||
          raw.toLowerCase().contains('syntaxerror') ||
          raw.toLowerCase().contains('unexpected') ||
          raw.toLowerCase().contains('expecting')) {
        return ScriptSyntaxCheck.fail(raw);
      }
      if (raw.contains('missing_execute')) {
        return const ScriptSyntaxCheck.fail(
          'Bro Code must define async function execute(params)',
        );
      }
      return const ScriptSyntaxCheck.ok();
    } catch (e) {
      // Unit hosts without QuickJS native DLL cannot parse — skip gate in tests.
      final msg = '$e';
      if (Platform.environment.containsKey('FLUTTER_TEST') &&
          msg.contains('Failed to load dynamic library')) {
        return const ScriptSyntaxCheck.ok();
      }
      return ScriptSyntaxCheck.fail(msg);
    } finally {
      try {
        runtime?.dispose();
      } catch (_) {}
    }
  }

  /// Executes vault-stored Bro Code (JS).
  ///
  /// Scripts must define `async function execute(params)` returning a
  /// human-readable string for TTS.
  ///
  /// When [sandboxMode] is true, System.querySQL / writeVault hit an in-memory
  /// DB seeded with **synthetic** telemetry only — never the sovereign vault
  /// and never a copy of real GPS/accel (safe for C4 / IMPROVE / marketplace).
  ///
  /// [assets] are injected as read-only `System.assets[id]` so thin orchestrators
  /// can `System.writeVault(key, System.assets[id], mime)` without embedding
  /// large HTML/PWA blobs inside the execute script.
  Future<AgentExecutionResult> executeAgentScript({
    required String agentName,
    required String script,
    required Map<String, dynamic> parameters,
    void Function(String step)? onStepLog,
    bool sandboxMode = false,
    Map<String, String> assets = const {},
  }) async {
    final runtime = getJavascriptRuntime(xhr: false);
    final htmlKeys = <String>[];
    final events = <BroCodeExecutionEvent>[];
    if (sandboxMode) {
      await _telemetry.openSandbox(reset: true);
      onStepLog?.call('Sandbox vault opened (in-memory, isolated)');
    }
    try {
      _registerBridges(runtime, agentName, onStepLog, htmlKeys, events);
      if (assets.isNotEmpty) {
        onStepLog?.call('Injected ${assets.length} System.assets key(s)');
      }

      final wrapped =
          '''
${_systemBootstrap(assets: assets)}

$script

(async function() {
  if (typeof execute !== 'function') {
    throw new Error('Bro Code must define async function execute(params)');
  }
  return await execute(${jsonEncode(parameters)});
})()
''';

      onStepLog?.call(
        sandboxMode
            ? 'QuickJS sandbox + mock vault for $agentName'
            : 'QuickJS sandbox initialized for $agentName',
      );
      var result = runtime.evaluate(wrapped);
      result = await runtime.handlePromise(result);
      onStepLog?.call('Bro Code execution completed');

      final message = _parseJsResult(result);
      final looksLikeError =
          message.toLowerCase().contains('error') ||
          message.toLowerCase().contains('syntaxerror');
      return AgentExecutionResult(
        message: message,
        isError: looksLikeError,
        vaultHtmlKeysWritten: List.unmodifiable(htmlKeys),
        trace: BroCodeExecutionTrace(
          events: List.unmodifiable(events),
          returnMessage: message,
          ranOk: !looksLikeError,
        ),
      );
    } catch (e, st) {
      debugPrint('[JsBridge] Execution error ($agentName): $e\n$st');
      onStepLog?.call('Execution error: $e');
      return AgentExecutionResult(
        message: '$agentName Bro Code encountered an error: $e',
        isError: true,
        vaultHtmlKeysWritten: List.unmodifiable(htmlKeys),
        trace: BroCodeExecutionTrace(
          events: List.unmodifiable(events),
          returnMessage: '$e',
          ranOk: false,
        ),
      );
    } finally {
      if (sandboxMode) {
        await _telemetry.closeSandbox();
        onStepLog?.call('Sandbox vault closed');
      }
      runtime.dispose();
    }
  }

  void _registerBridges(
    JavascriptRuntime runtime,
    String agentName,
    void Function(String step)? onStepLog,
    List<String> htmlKeysOut,
    List<BroCodeExecutionEvent> eventsOut,
  ) {
    runtime.onMessage('AurBhai_BridgeLog', (dynamic args) {
      final message = args is Map
          ? args['message']?.toString() ?? '$args'
          : '$args';
      onStepLog?.call(message);
      eventsOut.add(
        BroCodeExecutionEvent(
          kind: 'log',
          data: {'message': message},
          summary: message.length > 120
              ? '${message.substring(0, 120)}…'
              : message,
        ),
      );
    });

    runtime.onMessage('AurBhai_querySQL', (dynamic args) async {
      final query = (args['query'] as String?)?.trim() ?? '';
      onStepLog?.call(
        'System.querySQL → ${query.length > 80 ? '${query.substring(0, 80)}...' : query}',
      );
      final rows = await _telemetry.executeQuery(query);
      onStepLog?.call('System.querySQL ← ${rows.length} row(s)');
      eventsOut.add(
        BroCodeExecutionEvent(
          kind: 'querySQL',
          data: {'query': query, 'rowCount': rows.length},
          summary: 'querySQL → ${rows.length} row(s)',
        ),
      );
      return rows;
    });

    runtime.onMessage('AurBhai_writeVault', (dynamic args) async {
      final key = args['key'] as String? ?? '';
      final value = args['value'] as String? ?? '';
      final mimeType = args['mimeType'] as String? ?? 'text/plain';
      onStepLog?.call('System.writeVault → $key ($mimeType)');
      // Default finite TTL for HTML dashboards (MS-TELEMETRY-DASHBOARD-UX3).
      final isHtml =
          mimeType.toLowerCase().contains('html') ||
          key.toLowerCase().endsWith('.html');
      await _telemetry.writeVaultData(
        key,
        value,
        mimeType: mimeType,
        ttl: isHtml ? const Duration(hours: 24) : null,
      );
      if (mimeType.toLowerCase().contains('html') ||
          key.toLowerCase().endsWith('.html')) {
        htmlKeysOut.add(key);
      }
      eventsOut.add(
        BroCodeExecutionEvent(
          kind: 'writeVault',
          data: {'key': key, 'mimeType': mimeType, 'byteLength': value.length},
          summary: 'writeVault $key ($mimeType)',
        ),
      );
      onStepLog?.call('System.writeVault ← ok');
      return {'success': true, 'key': key};
    });

    runtime.onMessage('AurBhai_sendHTTP', (dynamic args) async {
      final url = args['url'] as String? ?? '';
      onStepLog?.call('System.sendHTTP → $url');
      final payload = args['payload'];
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) {
        throw Exception('Invalid URL: $url');
      }

      late final http.Response response;
      if (payload == null) {
        response = await http.get(uri).timeout(const Duration(seconds: 15));
      } else {
        response = await http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: payload is String ? payload : jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 15));
      }

      final body = response.body.length > 4096
          ? '${response.body.substring(0, 4096)}…'
          : response.body;
      onStepLog?.call('System.sendHTTP ← HTTP ${response.statusCode}');
      eventsOut.add(
        BroCodeExecutionEvent(
          kind: 'sendHTTP',
          data: {
            'url': url,
            'method': payload == null ? 'GET' : 'POST',
            'statusCode': response.statusCode,
            'bodyPreview': body.length > 500
                ? '${body.substring(0, 500)}…'
                : body,
          },
          summary:
              'sendHTTP ${payload == null ? 'GET' : 'POST'} $url → ${response.statusCode}',
        ),
      );
      return {'statusCode': response.statusCode, 'body': body};
    });

    runtime.onMessage('AurBhai_readInbox', (dynamic args) async {
      final feed = _feed;
      if (feed == null) {
        throw Exception('Feed service unavailable');
      }
      final unreadOnly = args['unreadOnly'] == true;
      final limit = args['limit'] is int ? args['limit'] as int : null;
      onStepLog?.call('System.readInbox → $agentName');
      final entries = await feed.readInbox(
        agentName,
        unreadOnly: unreadOnly,
        limit: limit,
      );
      onStepLog?.call('System.readInbox ← ${entries.length} entr(y/ies)');
      eventsOut.add(
        BroCodeExecutionEvent(
          kind: 'readInbox',
          data: {'count': entries.length, 'unreadOnly': unreadOnly},
          summary: 'readInbox → ${entries.length}',
        ),
      );
      return entries.map((e) => e.toJson()).toList();
    });

    runtime.onMessage('AurBhai_consumeInbox', (dynamic args) async {
      final feed = _feed;
      if (feed == null) {
        throw Exception('Feed service unavailable');
      }
      final rawIds = args['ids'];
      final ids = rawIds is List
          ? rawIds.map((e) => e.toString()).toList()
          : <String>[];
      onStepLog?.call('System.consumeInbox → $agentName');
      final n = await feed.consume(agentName, ids: ids.isEmpty ? null : ids);
      onStepLog?.call('System.consumeInbox ← $n consumed');
      eventsOut.add(
        BroCodeExecutionEvent(
          kind: 'consumeInbox',
          data: {'consumed': n},
          summary: 'consumeInbox → $n',
        ),
      );
      return {'consumed': n};
    });

    runtime.onMessage('AurBhai_notifyUser', (dynamic args) async {
      final calls = _broCalls;
      if (calls == null) {
        throw Exception('Bro Call service unavailable');
      }
      final title = args['title']?.toString() ?? 'Aur Bhai';
      final body = args['body']?.toString() ?? '';
      final speak = args['speakText']?.toString();
      onStepLog?.call('System.notifyUser → $agentName');
      final call = await calls.enqueue(
        agentName: agentName,
        title: title,
        body: body,
        speakText: speak,
      );
      eventsOut.add(
        BroCodeExecutionEvent(
          kind: 'notifyUser',
          data: {'id': call.id, 'title': title},
          summary: 'notifyUser → ${call.id}',
        ),
      );
      return {'id': call.id, 'queued': true};
    });
  }

  String _systemBootstrap({Map<String, String> assets = const {}}) =>
      '''
const System = {
  log: function(message) {
    sendMessage('AurBhai_BridgeLog', JSON.stringify({ message: String(message) }));
  },
  querySQL: function(query) {
    return sendMessage('AurBhai_querySQL', JSON.stringify({ query: String(query) }));
  },
  writeVault: function(key, value, mimeType) {
    return sendMessage('AurBhai_writeVault', JSON.stringify({
      key: String(key),
      value: String(value),
      mimeType: mimeType || 'text/plain'
    }));
  },
  sendHTTP: function(url, payload) {
    return sendMessage('AurBhai_sendHTTP', JSON.stringify({
      url: String(url),
      payload: payload === undefined ? null : payload
    }));
  },
  readInbox: function(opts) {
    opts = opts || {};
    return sendMessage('AurBhai_readInbox', JSON.stringify({
      unreadOnly: !!opts.unreadOnly,
      limit: opts.limit === undefined ? null : opts.limit
    }));
  },
  consumeInbox: function(opts) {
    opts = opts || {};
    return sendMessage('AurBhai_consumeInbox', JSON.stringify({
      ids: opts.ids || []
    }));
  },
  notifyUser: function(opts) {
    opts = opts || {};
    return sendMessage('AurBhai_notifyUser', JSON.stringify({
      title: opts.title || 'Aur Bhai',
      body: opts.body || '',
      speakText: opts.speakText === undefined ? null : opts.speakText
    }));
  },
  // Read-only sidecars (HTML / manifest / SW). Do not mutate.
  assets: Object.freeze(${jsonEncode(assets)})
};
''';

  String _parseJsResult(JsEvalResult result) {
    final raw = result.stringResult;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is String) return decoded;
      if (decoded is num || decoded is bool) return 'Result: $decoded';
      if (decoded == null) return 'Bro Code completed with no return value.';
      return decoded.toString();
    } catch (_) {
      return raw;
    }
  }
}

final jsBridgeServiceProvider = Provider<JsBridgeService>((ref) {
  final telemetry = ref.watch(telemetryBusProvider);
  final feed = ref.watch(agentFeedServiceProvider);
  final broCalls = ref.watch(broCallServiceProvider);
  return JsBridgeService(telemetry, feed: feed, broCalls: broCalls);
});
