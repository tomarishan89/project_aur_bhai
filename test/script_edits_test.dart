import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/agent_bridge_spec.dart';
import 'package:project_aur_bhai/core/services/llm_service.dart';
import 'package:project_aur_bhai/core/services/script_edits.dart';

void main() {
  group('applyScriptEdits', () {
    test('applies a unique search/replace', () {
      const source = 'async function execute(params) {\n  return 1;\n}';
      final result = applyScriptEdits(source, [
        const ScriptEdit(oldString: 'return 1;', newString: 'return 2;'),
      ]);
      expect(result, contains('return 2;'));
      expect(result, isNot(contains('return 1;')));
    });

    test('replaceAll replaces every occurrence', () {
      const source = 'foo bar foo';
      final result = applyScriptEdits(source, [
        const ScriptEdit(oldString: 'foo', newString: 'baz', replaceAll: true),
      ]);
      expect(result, 'baz bar baz');
    });

    test('throws when oldString is missing', () {
      expect(
        () => applyScriptEdits('hello', [
          const ScriptEdit(oldString: 'missing', newString: 'x'),
        ]),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Base64 edit transport', () {
    test('parses oldStringBase64/newStringBase64 with newlines', () {
      final oldRaw = "System.log('start')\nconst x = 1";
      final newRaw = "System.log('start');\nconst x = 1";
      final edits = parseScriptEdits({
        'edits': [
          {
            'oldStringBase64': base64Encode(utf8.encode(oldRaw)),
            'newStringBase64': base64Encode(utf8.encode(newRaw)),
          },
        ],
      });
      expect(edits, isNotNull);
      expect(edits!.single.oldString, oldRaw);
      expect(edits.single.newString, newRaw);

      const source = "System.log('start')\nconst x = 1\nreturn 'ok';";
      final patched = applyScriptEdits(source, edits);
      expect(patched, contains("System.log('start');"));
    });

    test('plain oldString still works as fallback', () {
      final edits = parseScriptEdits({
        'edits': [
          {'oldString': 'a', 'newString': 'b'},
        ],
      });
      expect(edits!.single.oldString, 'a');
    });
  });

  group('excerpt + local syntax fix', () {
    test('parseScriptErrorLocation reads eval line:col', () {
      final loc = parseScriptErrorLocation(
        "SyntaxError: expecting ';' at <eval>:34:16",
      );
      expect(loc, isNotNull);
      expect(loc!.line, 34);
      expect(loc.column, 16);
    });

    test('buildScriptExcerpt marks the error line', () {
      final script = List.generate(40, (i) => 'line${i + 1}();').join('\n');
      final excerpt = buildScriptExcerpt(
        script,
        location: const ScriptErrorLocation(34, 16),
        radius: 2,
      );
      expect(excerpt, contains('>>  34|'));
      expect(excerpt, contains('line34'));
      expect(excerpt, isNot(contains('line1();')));
    });

    test('localSyntaxFixCandidates inserts semicolon', () {
      const script = '''
async function execute(params) {
  System.log('start')
  return 'ok';
}
''';
      final candidates = localSyntaxFixCandidates(
        script,
        "SyntaxError: expecting ';' at <eval>:2:22",
      );
      expect(candidates, isNotEmpty);
      expect(
        candidates.any((c) => c.script.contains("System.log('start');")),
        isTrue,
      );
    });
  });

  group('error messaging', () {
    test('parse failure is not large-HTML incomplete JSON coaching', () {
      final msg = authoredJsonParseFailureMessage(
        const FormatException('Unexpected character'),
        rawSnippet: '{"edits":[{"oldString":"broken',
      );
      expect(msg, contains('invalid Bro Code JSON'));
      expect(msg.toLowerCase(), isNot(contains('ask to fix only')));
      expect(msg, isNot(contains('large dashboard HTML')));
      expect(
        AgentBridgeSpec.invalidPatchJsonUserMessage,
        contains('scriptBase64'),
      );
    });
  });

  group('large-script surgical fix', () {
    test('SyntaxError fix does not rewrite embedded HTML', () {
      final html = List.filled(80, '<div class="row">telemetry</div>').join();
      final source =
          '''
async function execute(params) {
  System.log('start')
  const html = `$html`;
  await System.writeVault('Dash.html', html, 'text/html');
  return 'ok';
}
''';
      final patched = applyScriptEdits(source, [
        const ScriptEdit(
          oldString: "System.log('start')",
          newString: "System.log('start');",
        ),
      ]);
      expect(patched, contains("System.log('start');"));
      expect(patched, contains(html));
    });
  });
}
