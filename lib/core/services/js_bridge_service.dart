import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:quickjs_engine/quickjs_engine.dart';

import 'telemetry_bus.dart';

/// Outcome of a single JS agent sandbox run.
class AgentExecutionResult {
  final String message;
  final bool isError;
  final List<String> vaultHtmlKeysWritten;

  const AgentExecutionResult({
    required this.message,
    this.isError = false,
    this.vaultHtmlKeysWritten = const [],
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
  /// DB — never the sovereign vault (safe for C4 / Tester Agent runs).
  Future<AgentExecutionResult> executeAgentScript({
    required String agentName,
    required String script,
    required Map<String, dynamic> parameters,
    void Function(String step)? onStepLog,
    bool sandboxMode = false,
  }) async {
    final runtime = getJavascriptRuntime(xhr: false);
    final htmlKeys = <String>[];
    if (sandboxMode) {
      await _telemetry.openSandbox(reset: true);
      onStepLog?.call('Sandbox vault opened (in-memory, isolated)');
    }
    try {
      _registerBridges(runtime, agentName, onStepLog, htmlKeys);

      final wrapped = '''
${_systemBootstrap()}

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
      );
    } catch (e, st) {
      debugPrint('[JsBridge] Execution error ($agentName): $e\n$st');
      onStepLog?.call('Execution error: $e');
      return AgentExecutionResult(
        message: '$agentName Bro Code encountered an error: $e',
        isError: true,
        vaultHtmlKeysWritten: List.unmodifiable(htmlKeys),
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
  ) {
    runtime.onMessage('AurBhai_BridgeLog', (dynamic args) {
      final message = args is Map ? args['message']?.toString() ?? '$args' : '$args';
      onStepLog?.call(message);
    });

    runtime.onMessage('AurBhai_querySQL', (dynamic args) async {
      final query = (args['query'] as String?)?.trim() ?? '';
      onStepLog?.call('System.querySQL → ${query.length > 80 ? '${query.substring(0, 80)}...' : query}');
      if (!_isReadOnlyQuery(query)) {
        throw Exception('Only read-only SELECT queries are permitted');
      }
      final rows = await _telemetry.executeQuery(query);
      onStepLog?.call('System.querySQL ← ${rows.length} row(s)');
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
      return {
        'statusCode': response.statusCode,
        'body': body,
      };
    });
  }

  String _systemBootstrap() => '''
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
  }
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
