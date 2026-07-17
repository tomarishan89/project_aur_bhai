import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:quickjs_engine/quickjs_engine.dart';

import '../pipeline/bro_code_capability_judge.dart';
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

  JsBridgeService(this._telemetry);

  /// Parses [script] without calling execute — blocks save of broken JS.
  ScriptSyntaxCheck validateScriptSyntax(String script) {
    final runtime = getJavascriptRuntime(xhr: false);
    try {
      final probe = '''
$script
;(typeof execute === 'function' ? 'ok' : 'missing_execute')
''';
      final result = runtime.evaluate(probe);
      final raw = result.stringResult;
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
      return ScriptSyntaxCheck.fail('$e');
    } finally {
      runtime.dispose();
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

      final wrapped = '''
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
      final looksLikeError = message.toLowerCase().contains('error') ||
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
      final message = args is Map ? args['message']?.toString() ?? '$args' : '$args';
      onStepLog?.call(message);
      eventsOut.add(BroCodeExecutionEvent(
        kind: 'log',
        data: {'message': message},
        summary: message.length > 120 ? '${message.substring(0, 120)}…' : message,
      ));
    });

    runtime.onMessage('AurBhai_querySQL', (dynamic args) async {
      final query = (args['query'] as String?)?.trim() ?? '';
      onStepLog?.call('System.querySQL → ${query.length > 80 ? '${query.substring(0, 80)}...' : query}');
      if (!_isReadOnlyQuery(query)) {
        throw Exception('Only read-only SELECT queries are permitted');
      }
      final rows = await _telemetry.executeQuery(query);
      onStepLog?.call('System.querySQL ← ${rows.length} row(s)');
      eventsOut.add(BroCodeExecutionEvent(
        kind: 'querySQL',
        data: {'query': query, 'rowCount': rows.length},
        summary: 'querySQL → ${rows.length} row(s)',
      ));
      return rows;
    });

    runtime.onMessage('AurBhai_writeVault', (dynamic args) async {
      final key = args['key'] as String? ?? '';
      final value = args['value'] as String? ?? '';
      final mimeType = args['mimeType'] as String? ?? 'text/plain';
      onStepLog?.call('System.writeVault → $key ($mimeType)');
      await _telemetry.writeVaultData(key, value, mimeType: mimeType);
      if (mimeType.toLowerCase().contains('html') ||
          key.toLowerCase().endsWith('.html')) {
        htmlKeysOut.add(key);
      }
      eventsOut.add(BroCodeExecutionEvent(
        kind: 'writeVault',
        data: {
          'key': key,
          'mimeType': mimeType,
          'byteLength': value.length,
        },
        summary: 'writeVault $key ($mimeType)',
      ));
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
      eventsOut.add(BroCodeExecutionEvent(
        kind: 'sendHTTP',
        data: {
          'url': url,
          'method': payload == null ? 'GET' : 'POST',
          'statusCode': response.statusCode,
          'bodyPreview': body.length > 500 ? '${body.substring(0, 500)}…' : body,
        },
        summary: 'sendHTTP ${payload == null ? 'GET' : 'POST'} $url → ${response.statusCode}',
      ));
      return {
        'statusCode': response.statusCode,
        'body': body,
      };
    });
  }

  String _systemBootstrap({Map<String, String> assets = const {}}) => '''
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
  // Read-only sidecars (HTML / manifest / SW). Do not mutate.
  assets: Object.freeze(${jsonEncode(assets)})
};
''';

  bool _isReadOnlyQuery(String sql) {
    final normalized = sql.trim().toUpperCase();
    if (!normalized.startsWith('SELECT')) return false;
    const forbidden = [
      'INSERT',
      'UPDATE',
      'DELETE',
      'DROP',
      'ALTER',
      'CREATE',
      'ATTACH',
      'DETACH',
      'REPLACE',
      'TRUNCATE',
    ];
    for (final word in forbidden) {
      if (RegExp('\\b$word\\b').hasMatch(normalized)) return false;
    }
    return true;
  }

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
  return JsBridgeService(telemetry);
});
