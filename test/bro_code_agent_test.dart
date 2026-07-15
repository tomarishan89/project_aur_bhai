import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_aur_bhai/core/pipeline/bro_code_coding_agent.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_workspace.dart';
import 'package:project_aur_bhai/core/pipeline/context_estimate.dart';
import 'package:project_aur_bhai/core/services/agent_verification_service.dart';
import 'package:project_aur_bhai/core/services/script_edits.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('context estimate', () {
    test('estimateTokensFromString scales with size', () {
      expect(estimateTokensFromString(''), 0);
      expect(estimateTokensFromString('abcd'), greaterThan(0));
      expect(
        estimateTokensFromString('a' * 400),
        greaterThan(estimateTokensFromString('a' * 40)),
      );
    });
  });

  group('workspace + apply_edit fidelity', () {
    test('applyScriptEdits unique match updates workspace-shaped source', () {
      const src = 'async function execute(params) {\n  return "hi";\n}\n';
      final next = applyScriptEdits(src, [
        const ScriptEdit(oldString: 'return "hi";', newString: 'return "ok";'),
      ]);
      final ws = BroCodeWorkspace(
        name: 'Demo',
        description: 'd',
        inputSchema: const {},
        script: next,
      );
      expect(ws.script, contains('return "ok";'));
      expect(ws.excerptAroundLine(2), contains('>>'));
    });

    test('ambiguous edit fails', () {
      expect(
        () => applyScriptEdits('aa aa', [
          const ScriptEdit(oldString: 'aa', newString: 'b'),
        ]),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('coding-agent action protocol', () {
    test('accepts raw JSON', () {
      final action = parseBroCodeActionJson(
        '{"thought":"check","action":"validate_syntax","args":{}}',
      );
      expect(action['action'], 'validate_syntax');
    });

    test('recovers JSON wrapped in provider prose', () {
      final action = parseBroCodeActionJson(
        'Here is the next action:\n'
        '```json\n'
        '{"thought":"edit now","action":"apply_edit",'
        '"args":{"old":"a}b","new":"c"}}\n'
        '```',
      );
      expect(action['action'], 'apply_edit');
      expect((action['args'] as Map)['old'], 'a}b');
    });

    test('recovers a known tool call from non-JSON text', () {
      final action = parseBroCodeActionJson(
        "I'll inspect it: read_script(startLine: 40, endLine: 80)",
      );
      expect(action['action'], 'read_script');
      expect((action['args'] as Map)['startLine'], 40);
      expect((action['args'] as Map)['endLine'], 80);
    });
  });

  test('due diligence ignores browser APIs inside escaped HTML template', () {
    const script = r'''
async function execute(params) {
  const html = `<!DOCTYPE html><html><script>
    const row = \`<div>\${document.title}</div>\`;
    fetch('/api/query').then(() => window.location);
  </script></html>`;
  await System.writeVault("dashboard.html", html, "text/html");
  return "ok";
}
''';
    final scan = AgentVerificationService().scanScript(script);
    expect(scan.passed, isTrue, reason: scan.findings.join('; '));
  });

  test('due diligence does not turn malformed dashboard syntax into DOM finding',
      () {
    const malformed = r'''
async function execute(params) {
  const html = `<!DOCTYPE html><html><script>
    const row = `<div>\${document.title}</div>`;
    fetch('/api/query');
  </script></html>`;
  return html;
}
''';
    final scan = AgentVerificationService().scanScript(malformed);
    expect(scan.passed, isTrue, reason: scan.findings.join('; '));
  });
}
