import 'package:flutter_test/flutter_test.dart';

import 'package:project_aur_bhai/core/pipeline/bro_code_workspace.dart';
import 'package:project_aur_bhai/core/pipeline/context_estimate.dart';
import 'package:project_aur_bhai/core/services/script_edits.dart';

void main() {
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
}
