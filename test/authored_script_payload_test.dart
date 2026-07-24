import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/agent_bridge_spec.dart';
import 'package:project_aur_bhai/core/services/llm_service.dart';

void main() {
  group('scriptFromDraftJson', () {
    test('decodes scriptBase64 round-trip', () {
      const source = r'''
async function execute(params) {
  const html = `<!DOCTYPE html><html><body>ok</body></html>`;
  await System.writeVault('x.html', html, 'text/html');
  return 'ready';
}
''';
      final encoded = base64Encode(utf8.encode(source));
      final out = scriptFromDraftJson({'scriptBase64': encoded});
      expect(out, source);
    });

    test('falls back to legacy script field', () {
      const source = 'async function execute(params) { return "hi"; }';
      expect(scriptFromDraftJson({'script': source}), source);
    });

    test('prefers scriptBase64 over script', () {
      final b64 = base64Encode(utf8.encode('from-b64'));
      expect(
        scriptFromDraftJson({'scriptBase64': b64, 'script': 'from-script'}),
        'from-b64',
      );
    });

    test('throws when neither field present', () {
      expect(() => scriptFromDraftJson({}), throwsException);
    });
  });

  group('authoredJsonParseFailureMessage', () {
    test('maps FormatException / unterminated string to friendly copy', () {
      expect(
        authoredJsonParseFailureMessage(
          const FormatException(
            'Unterminated string (at line 5, character 909)',
          ),
        ),
        startsWith(AgentBridgeSpec.incompleteJsonUserMessage),
      );
      expect(
        authoredJsonParseFailureMessage(
          Exception('FormatException: Unterminated string'),
        ),
        startsWith(AgentBridgeSpec.incompleteJsonUserMessage),
      );
    });

    test('passes through unrelated errors', () {
      expect(
        authoredJsonParseFailureMessage(Exception('Configure your API Key')),
        contains('Configure your API Key'),
      );
    });
  });
}
