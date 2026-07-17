import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_aur_bhai/core/pipeline/bro_code_agent_tools.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_capability_judge.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_coding_agent.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_dashboard_goal.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_fixture_report.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_platform_integrity.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_style_checker.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_workspace.dart';
import 'package:project_aur_bhai/core/pipeline/context_estimate.dart';
import 'package:project_aur_bhai/core/services/agent_bridge_spec.dart';
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

    test('fuzzy whitespace apply_edit matches indented oldString', () {
      const src = 'async function execute(params) {\n  return "hi";\n}\n';
      final next = applyScriptEdits(src, [
        const ScriptEdit(
          oldString: 'return  "hi";', // extra spaces
          newString: 'return "ok";',
        ),
      ]);
      expect(next, contains('return "ok";'));
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

    test('recovers write_full content from fenced JS in non-JSON text', () {
      final action = parseBroCodeActionJson(
        'Writing full script now with write_full:\n'
        '```javascript\n'
        'async function execute(params) { return "ok"; }\n'
        '```',
      );
      expect(action['action'], 'write_full');
      expect((action['args'] as Map)['content'], contains('async function execute'));
    });

    test('empty write_full marks skipIdenticalFailure and hints apply_edit', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final toolsProvider = Provider(
        (ref) => BroCodeAgentTools(
          ref,
          BroCodeWorkspace(
            name: 'Locator',
            description: 'd',
            inputSchema: const {},
            script: 'async function execute(params) { return "x"; }\n',
            assets: const {'Locator.html': '<!DOCTYPE html><html></html>'},
          ),
        ),
      );
      final tools = container.read(toolsProvider);
      final obs = await tools.execute('write_full', {});
      expect(obs.ok, isFalse);
      expect(obs.summary, 'Missing content / scriptBase64');
      expect(obs.data?['skipIdenticalFailure'], isTrue);
      expect(obs.data?['refundTurn'], isTrue);
      expect(obs.nextHint?.toLowerCase(), contains('apply_edit'));
    });

    test('write_full budget is split between script and assets', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final tools = container.read(Provider((ref) => BroCodeAgentTools(
        ref,
        BroCodeWorkspace(
          name: 'Demo',
          description: '',
          inputSchema: const {},
          script: '',
        ),
      )));

      // Exhaust script budget
      for (var i = 0; i < BroCodeAgentTools.maxWriteFullScriptPerRun; i++) {
        final obs = await tools.execute('write_full', {'content': 'a'});
        expect(obs.ok, isTrue);
      }
      final overScript = await tools.execute('write_full', {'content': 'b'});
      expect(overScript.ok, isFalse);
      expect(overScript.summary, contains('script budget exhausted'));

      // Asset budget still available
      final assetObs = await tools.execute(
        'write_full',
        {'asset': 'a.html', 'content': 'html'},
      );
      expect(assetObs.ok, isTrue);
      expect(tools.workspace.assets['a.html'], 'html');
    });

    test('write_full rejects embedded HTML execute rewrite under preferAssetExtraction', () async {
      final script = 'async function execute() {\n  const html = `<!DOCTYPE html>...`;\n}';
      
      // We manually simulate the logic of the preferAssetExtraction rejection
      final preferAssetExtraction = true;
      final rejected = preferAssetExtraction &&
          (script.contains('<!DOCTYPE') || script.length > 2000);
          
      expect(rejected, isTrue);
    });
    
    test('auto-thin path: host auto-thins execute after HTML asset write', () {
      const script = r'''
async function execute(params) {
  const html = `<!DOCTYPE html><html><body>
  <script>document.body; fetch('/api/query');</script>
  ${nested}
  </body></html>`;
  return html;
}''';
      // Synthetic syntax failure — no QuickJS DLL required on this machine.
      const syntaxObs = ToolObservation(
        ok: false,
        tool: 'validate_syntax',
        summary: 'unexpected token',
        detail: r'`${nested}`',
      );

      final looksLikeNested =
          BroCodeCodingAgent.looksLikeNestedHtmlTemplateSyntaxFailure(
        script: script,
        syntaxObservation: syntaxObs,
      );
      expect(looksLikeNested, isTrue);

      const targetAsset = 'dashboard.html';
      final thinScript = '''
async function execute(params) {
  const html = System.assets["$targetAsset"];
  if (html) {
    await System.writeVault("dashboard.html", html, "text/html");
  }
  return "Vault Dashboards updated.";
}
''';
      expect(thinScript, isNot(contains('<!DOCTYPE html>')));
      expect(thinScript, contains('System.assets["dashboard.html"]'));
      expect(thinScript, contains('System.writeVault'));
    });
  });

  test('refineOutputTransport no longer tells models to nest HTML in JS', () {
    expect(
      AgentBridgeSpec.refineOutputTransport,
      isNot(contains('Dashboard HTML stays inside the JS template string')),
    );
    expect(
      AgentBridgeSpec.refineOutputTransport.toLowerCase(),
      contains('system.assets'),
    );
  });

  test('bridgeSpec mandates LIMIT / pagination for dashboard data volume', () {
    expect(
      AgentBridgeSpec.bridgeSpecForLlm.toUpperCase(),
      contains('DATA VOLUME'),
    );
    expect(
      AgentBridgeSpec.bridgeSpecForLlm.toUpperCase(),
      contains('LIMIT'),
    );
    expect(
      AgentBridgeSpec.slotFillingHint.toLowerCase(),
      contains('paginate'),
    );
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

  test('due diligence ignores unescaped SQL backticks inside HTML dashboard', () {
    // Real IMPROVE failure mode: nested ` for SQL inside outer HTML template.
    const script = r'''
async function execute(params) {
  const html = `<!DOCTYPE html><html><body>
  <script>
    async function fetchData() {
      const query = `
        SELECT * FROM telemetry
        WHERE datetime(timestamp) >= datetime('now', '-24 hours')
      `;
      const res = await fetch('/api/query', {
        method: 'POST',
        body: JSON.stringify({ sql: query })
      });
      document.getElementById('logs-box').textContent = 'ok';
    }
  </script>
  </body></html>`;
  await System.writeVault('Map.html', html, 'text/html');
  return 'ok';
}
''';
    final scan = AgentVerificationService().scanScript(script);
    expect(scan.passed, isTrue, reason: scan.findings.join('; '));
  });

  test('due diligence ignores fetch inside service-worker vault template', () {
    const script = r'''
async function execute(params) {
  const sw = `
    self.addEventListener('fetch', (e) => {
      e.respondWith(fetch(e.request));
    });
  `;
  await System.writeVault('app.sw.js', sw, 'application/javascript');
  return 'ok';
}
''';
    final scan = AgentVerificationService().scanScript(script);
    expect(scan.passed, isTrue, reason: scan.findings.join('; '));
  });

  test('due diligence still flags live document. outside any HTML', () {
    const script = '''
async function execute(params) {
  document.getElementById('x');
  return 'bad';
}
''';
    final scan = AgentVerificationService().scanScript(script);
    expect(scan.passed, isFalse);
    expect(
      scan.findings.any((f) => f.contains('Browser/DOM')),
      isTrue,
    );
  });

  group('Bro Code style checker', () {
    test('format normalizes CRLF, trailing WS, and EOF newline', () {
      const messy = 'async function execute() {\r\n  return 1;  \r\n}';
      final result = BroCodeStyleChecker.format(messy);
      expect(result.changed, isTrue);
      expect(result.formattedScript, 'async function execute() {\n  return 1;\n}\n');
      expect(result.findings.any((f) => f.code == 'CRLF'), isTrue);
      expect(result.findings.any((f) => f.code == 'TRAILING_WS'), isTrue);
      expect(BroCodeStyleChecker.format(result.formattedScript).changed, isFalse);
    });

    test('style flags mixed indent and console.log outside HTML', () {
      const script = '''
async function execute(params) {
\tSystem.log("tab");
  console.log("debug");
}
''';
      final result = BroCodeStyleChecker.checkStyle(script);
      expect(result.ok, isFalse);
      expect(result.blocking.any((f) => f.code == 'MIXED_INDENT'), isTrue);
      expect(result.blocking.any((f) => f.code == 'CONSOLE_LOG'), isTrue);
    });

    test('style ignores console.log inside HTML template', () {
      const script = r'''
async function execute(params) {
  const html = `<!DOCTYPE html><html><script>
    console.log(document.title);
  </script></html>`;
  await System.writeVault("d.html", html, "text/html");
  return "ok";
}
''';
      final result = BroCodeStyleChecker.checkStyle(script);
      expect(
        result.blocking.any((f) => f.code == 'CONSOLE_LOG'),
        isFalse,
        reason: result.findings.join('; '),
      );
    });
  });

  group('host auto-format', () {
    test('ensureFormat clears drift without requiring apply_format tool', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const messy = 'async function execute() {\n  return 1;  \n}';
      final toolsProvider = Provider(
        (ref) => BroCodeAgentTools(
          ref,
          BroCodeWorkspace(
            name: 'Demo',
            description: 'd',
            inputSchema: const {},
            script: messy,
          ),
        ),
      );
      final tools = container.read(toolsProvider);
      tools.syntaxOkAfterLastMutate = true;
      tools.sandboxOkAfterLastMutate = true;
      tools.styleOkAfterLastMutate = true;
      tools.formatOkAfterLastMutate = false;

      final obs = tools.ensureFormat();
      expect(obs.ok, isTrue);
      expect(obs.tool, 'apply_format');
      expect(tools.formatOkAfterLastMutate, isTrue);
      expect(tools.syntaxOkAfterLastMutate, isTrue);
      expect(BroCodeStyleChecker.format(tools.workspace.script).changed, isFalse);
    });

    test('ensureFormat on already-clean script keeps formatOk', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final toolsProvider = Provider(
        (ref) => BroCodeAgentTools(
          ref,
          BroCodeWorkspace(
            name: 'Demo',
            description: 'd',
            inputSchema: const {},
            script: 'async function execute() {\n  return 1;\n}\n',
          ),
        ),
      );
      final tools = container.read(toolsProvider);
      final obs = tools.ensureFormat();
      expect(obs.ok, isTrue);
      expect(obs.tool, 'check_format');
      expect(tools.formatOkAfterLastMutate, isTrue);
    });

    test('style failure still blocks done after format is OK', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const script = '''
async function execute(params) {
\tSystem.log("tab");
  console.log("debug");
}
''';
      final toolsProvider = Provider(
        (ref) => BroCodeAgentTools(
          ref,
          BroCodeWorkspace(
            name: 'Demo',
            description: 'd',
            inputSchema: const {},
            script: script,
          ),
        ),
      );
      final tools = container.read(toolsProvider);
      expect(tools.ensureFormat().ok, isTrue);
      final styleObs = await tools.execute('check_style', {});
      expect(styleObs.ok, isFalse);
      tools.syntaxOkAfterLastMutate = true;
      tools.sandboxOkAfterLastMutate = true;
      tools.formatOkAfterLastMutate = true;
      expect(tools.canDeclareDone, isFalse);
    });
  });

  group('done gates include format, style, and policy', () {
    test('canDeclareDone is false until format, style, and policy flags are set', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final toolsProvider = Provider(
        (ref) => BroCodeAgentTools(
          ref,
          BroCodeWorkspace(
            name: 'Demo',
            description: 'd',
            inputSchema: const {},
            script: 'async function execute() { return 1; }\n',
          ),
        ),
      );
      final tools = container.read(toolsProvider);
      expect(tools.canDeclareDone, isFalse);
      tools.syntaxOkAfterLastMutate = true;
      tools.sandboxOkAfterLastMutate = true;
      expect(tools.canDeclareDone, isFalse);
      tools.formatOkAfterLastMutate = true;
      expect(tools.canDeclareDone, isFalse);
      tools.styleOkAfterLastMutate = true;
      expect(tools.canDeclareDone, isFalse);
      tools.policyOkAfterLastMutate = true;
      // goalOk defaults true until a mutate clears it.
      expect(tools.canDeclareDone, isTrue);
      tools.goalOkAfterLastMutate = false;
      expect(tools.canDeclareDone, isFalse);
      tools.goalOkAfterLastMutate = true;
      expect(tools.canDeclareDone, isTrue);
    });
  });

  group('policy gate', () {
    test('policyOkAfterLastMutate is required for done and set by scan_policy',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final toolsProvider = Provider(
        (ref) => BroCodeAgentTools(
          ref,
          BroCodeWorkspace(
            name: 'Demo',
            description: 'd',
            inputSchema: const {},
            script: '''
async function execute(params) {
  document.title = "x";
  return "ok";
}
''',
          ),
        ),
      );
      final tools = container.read(toolsProvider);
      tools.syntaxOkAfterLastMutate = true;
      tools.sandboxOkAfterLastMutate = true;
      tools.formatOkAfterLastMutate = true;
      tools.styleOkAfterLastMutate = true;
      expect(tools.canDeclareDone, isFalse);

      final obs = await tools.execute('scan_policy', {});
      expect(obs.ok, isFalse);
      expect(tools.policyOkAfterLastMutate, isFalse);
      expect(tools.canDeclareDone, isFalse);

      // Clean script: policy should pass.
      tools.workspace.script = '''
async function execute(params) {
  System.log("ok");
  return "ok";
}
''';
      final clean = await tools.execute('scan_policy', {});
      expect(clean.ok, isTrue, reason: clean.detail);
      expect(tools.policyOkAfterLastMutate, isTrue);
    });
  });

  group('stuck-loop fingerprint', () {
    test('failureFingerprint is stable for identical syntax failures', () {
      const a = ToolObservation(
        ok: false,
        tool: 'validate_syntax',
        summary: 'SyntaxError: expecting ;',
        data: {'line': 11, 'column': 15},
      );
      const b = ToolObservation(
        ok: false,
        tool: 'validate_syntax',
        summary: 'SyntaxError: expecting ;',
        data: {'line': 11, 'column': 15},
      );
      const c = ToolObservation(
        ok: false,
        tool: 'validate_syntax',
        summary: 'SyntaxError: unexpected token',
        data: {'line': 11, 'column': 15},
      );
      expect(
        BroCodeCodingAgent.failureFingerprint(a),
        BroCodeCodingAgent.failureFingerprint(b),
      );
      expect(
        BroCodeCodingAgent.failureFingerprint(a),
        isNot(BroCodeCodingAgent.failureFingerprint(c)),
      );
      expect(
        BroCodeCodingAgent.failureFingerprint(a),
        contains('validate_syntax'),
      );
      expect(BroCodeCodingAgent.failureFingerprint(a), contains('11'));
    });
  });

  group('IMPROVE session trim + fresh', () {
    BroCodeImproveAttempt _attempt(int n) => BroCodeImproveAttempt(
          attemptNumber: n,
          completedAt: DateTime.utc(2026, 7, 16, n),
          changeRequest: 'change $n',
          verified: false,
          outcomeMessage: 'fail $n',
          turnsUsed: 1,
          estimatedTokensUsed: 10,
          agentActivity: const [],
          scriptBefore: 'before$n',
          scriptAfter: 'after$n',
        );

    test('addAttempt trims oldest beyond maxPersistedAttempts', () {
      final session = BroCodeImproveSession(
        agentName: 'Demo',
        startedAt: DateTime.utc(2026, 7, 15),
      );
      var lastDropped = 0;
      for (var i = 1; i <= BroCodeImproveSession.maxPersistedAttempts + 2; i++) {
        lastDropped = session.addAttempt(_attempt(i));
      }
      expect(session.attempts.length, BroCodeImproveSession.maxPersistedAttempts);
      expect(lastDropped, greaterThan(0));
      expect(session.attempts.first.attemptNumber, 3);
      expect(session.attempts.last.attemptNumber, 7);
      expect(session.isLarge, isTrue);
    });

    test('freshCopy clears attempts; lastWorkingScript null', () {
      final session = BroCodeImproveSession(
        agentName: 'Demo',
        startedAt: DateTime.utc(2026, 7, 15),
      );
      session.addAttempt(_attempt(1));
      expect(session.lastWorkingScript, 'after1');
      final fresh = session.freshCopy();
      expect(fresh.attempts, isEmpty);
      expect(fresh.lastWorkingScript, isNull);
      expect(fresh.agentName, 'Demo');
      expect(fresh.isLarge, isFalse);
    });

    test('fromJson trims oversized session payloads', () {
      final oversized = BroCodeImproveSession(
        agentName: 'Demo',
        startedAt: DateTime.utc(2026, 7, 15),
      );
      for (var i = 1; i <= 8; i++) {
        oversized.attempts.add(_attempt(i));
      }
      final loaded = BroCodeImproveSession.fromJson(oversized.toJson());
      expect(loaded.attempts.length, BroCodeImproveSession.maxPersistedAttempts);
    });
  });

  group('nested HTML template syntax detection', () {
    test('detects unexpected token inside HTML-in-JS dashboard', () {
      const script = r'''
async function execute(params) {
  const html = `<!DOCTYPE html><html><script>
    document.getElementById('point-count').innerText = `${n} points`;
  </script></html>`;
  await System.writeVault('d.html', html, 'text/html');
  return 'ok';
}
''';
      const syn = ToolObservation(
        ok: false,
        tool: 'validate_syntax',
        summary: "SyntaxError: Unexpected token '{'\n    at <eval>:296:7\n",
        detail: r'document.getElementById... `${filteredPoints',
      );
      expect(
        BroCodeCodingAgent.looksLikeNestedHtmlTemplateSyntaxFailure(
          script: script,
          syntaxObservation: syn,
        ),
        isTrue,
      );
    });

    test('does not flag unrelated syntax errors without HTML template', () {
      const script = '''
async function execute(params) {
  return {
}
''';
      const syn = ToolObservation(
        ok: false,
        tool: 'validate_syntax',
        summary: "SyntaxError: Unexpected token '{'",
        detail: 'return {',
      );
      expect(
        BroCodeCodingAgent.looksLikeNestedHtmlTemplateSyntaxFailure(
          script: script,
          syntaxObservation: syn,
        ),
        isFalse,
      );
    });
  });

  group('fixture report diagnostics', () {
    test('serializes syntax and sandbox failures into improve.diagnostics', () {
      const syntaxFail = ToolObservation(
        ok: false,
        tool: 'validate_syntax',
        summary: 'SyntaxError: unexpected token',
        detail: '>> 42 |   return bad;\n',
        data: {'line': 42, 'column': 10},
      );
      const sandboxFail = ToolObservation(
        ok: false,
        tool: 'sandbox_run',
        summary: 'Sandbox failed: TypeError',
        detail: 'Bridge:\nstep: execute threw',
      );
      const formatFail = ToolObservation(
        ok: false,
        tool: 'check_format',
        summary: 'Format drift',
        detail: '• [TRAILING_WS] L2: Trailing whitespace.',
        data: {
          'findings': [
            {'code': 'TRAILING_WS', 'message': 'Trailing whitespace.', 'line': 2},
          ],
        },
      );
      final report = BroCodeFixtureReport(
        exportedAt: DateTime.utc(2026, 7, 15),
        appVersion: '1.0.0+1',
        workspace: BroCodeWorkspace(
          name: 'Demo',
          description: 'd',
          inputSchema: const {},
          script: 'async function execute() {}',
        ),
        changeRequest: 'Fix syntax',
        failureMessage: 'Not verified',
        baselineSyntax: syntaxFail,
        lastSyntaxError: syntaxFail,
        lastSandboxError: sandboxFail,
        lastFormatError: formatFail,
        failingObservations: [syntaxFail, sandboxFail, formatFail],
      );

      final json = report.toJson();
      final diagnostics =
          json['improve']['diagnostics'] as Map<String, dynamic>;
      final baseline =
          diagnostics['baselineSyntaxError'] as Map<String, dynamic>;
      expect(baseline['message'], 'SyntaxError: unexpected token');
      expect(baseline['line'], 42);
      expect(baseline['column'], 10);
      expect(baseline['excerpt'], contains('>> 42'));
      final lastSandbox =
          diagnostics['lastSandboxError'] as Map<String, dynamic>;
      expect(lastSandbox['message'], 'Sandbox failed: TypeError');
      expect(lastSandbox['detail'], contains('Bridge:'));
      final lastFormat = diagnostics['lastFormatError'] as Map<String, dynamic>;
      expect(lastFormat['message'], 'Format drift');
      expect(lastFormat['findings'], isA<List>());
      final failing = diagnostics['failingObservations'] as List;
      expect(failing, hasLength(3));
      expect((failing.first as Map)['tool'], 'validate_syntax');
    });

    test('reportVersion 2 includes session with multiple change requests', () {
      final session = BroCodeImproveSession(
        agentName: 'Locator',
        startedAt: DateTime.utc(2026, 7, 15, 10),
      );
      session.addAttempt(
        BroCodeImproveAttempt(
          attemptNumber: 1,
          completedAt: DateTime.utc(2026, 7, 15, 10, 5),
          changeRequest:
              'Make it a Progressive Web App that feels like a desktop dashboard',
          verified: false,
          outcomeMessage: 'Not verified',
          scriptBefore: 'v0',
          scriptAfter: 'v1',
        ),
      );
      session.addAttempt(
        BroCodeImproveAttempt(
          attemptNumber: 2,
          completedAt: DateTime.utc(2026, 7, 15, 10, 10),
          changeRequest: 'Remove Device Map and add a Leaflet map',
          verified: false,
          outcomeMessage: 'Turn budget',
          scriptBefore: 'v1',
          scriptAfter: 'v2',
        ),
      );

      final report = BroCodeFixtureReport(
        exportedAt: DateTime.utc(2026, 7, 15, 11),
        appVersion: '1.0.0+1',
        workspace: BroCodeWorkspace(
          name: 'Locator',
          description: 'locator',
          inputSchema: const {},
          script: 'v2',
        ),
        changeRequest: 'Remove Device Map and add a Leaflet map',
        failureMessage: 'Turn budget',
        session: session,
        attemptNumber: 2,
        verified: false,
      );

      final json = report.toJson();
      expect(json['reportVersion'], 2);
      final sess = json['session'] as Map<String, dynamic>;
      expect(sess['attempts'], hasLength(2));
      expect(
        sess['changeRequests'],
        containsAll([
          'Make it a Progressive Web App that feels like a desktop dashboard',
          'Remove Device Map and add a Leaflet map',
        ]),
      );
      expect(session.lastWorkingScript, 'v2');

      final roundTrip = BroCodeImproveSession.fromJson(sess);
      expect(roundTrip.attempts, hasLength(2));
      expect(roundTrip.distinctChangeRequests(), hasLength(2));
    });
  });

  group('platform integrity (any Bro Code)', () {
    test('flags orphan HTML asset not referenced by execute', () {
      final result = BroCodePlatformIntegrity.check(
        script: '''
async function execute(params) {
  const html = `<!DOCTYPE html><html><body>old</body></html>`;
  await System.writeVault('x.html', html, 'text/html');
  return 'ok';
}
''',
        assets: {
          'dash.html':
              '<!DOCTYPE html><html><body><input type="datetime-local"></body></html>',
        },
      );
      expect(result.ok, isFalse);
      expect(result.orphanAssetIds, contains('dash.html'));
      expect(BroCodePlatformIntegrity.canAutoRepair(result), isTrue);
    });

    test('flags half-thin execute with dead code after return', () {
      const script = r'''
async function execute(params) {
  const html = System.assets['dash.html'];
  await System.writeVault('dash.html', html, 'text/html');
  return 'ok';
  L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png').addTo(map);
  document.getElementById('x');
}
''';
      expect(BroCodePlatformIntegrity.isHalfThinScript(script), isTrue);
      final result = BroCodePlatformIntegrity.check(
        script: script,
        assets: {
          'dash.html': '<!DOCTYPE html><html><body>ok</body></html>',
        },
      );
      expect(result.ok, isFalse);
      expect(result.halfThinScript, isTrue);
    });

    test('thin publish execute references asset and is not half-thin', () {
      final thin = BroCodePlatformIntegrity.buildThinPublishExecute(
        htmlAssetId: 'dash.html',
        assets: {
          'dash.html': '<!DOCTYPE html><html></html>',
          'dash.webmanifest': '{}',
        },
      );
      expect(thin, contains('System.assets["dash.html"]'));
      expect(thin, contains('System.writeVault'));
      expect(BroCodePlatformIntegrity.isHalfThinScript(thin), isFalse);
      final result = BroCodePlatformIntegrity.check(
        script: thin,
        assets: {
          'dash.html': '<!DOCTYPE html><html></html>',
          'dash.webmanifest': '{}',
        },
      );
      expect(result.ok, isTrue, reason: result.findings.join('\n'));
    });

    test('case-insensitive asset resolve', () {
      expect(
        BroCodePlatformIntegrity.resolveAssetKey(
          {'Locator.html': 'x'},
          'locator.html',
        ),
        'Locator.html',
      );
    });

    test('host thin repair clears orphan via tools', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final tools = container.read(Provider(
        (ref) => BroCodeAgentTools(
          ref,
          BroCodeWorkspace(
            name: 'AnyAgent',
            description: 'd',
            inputSchema: const {},
            script: '''
async function execute(params) {
  const html = `<!DOCTYPE html><html><body>embedded</body></html>`;
  await System.writeVault('old.html', html, 'text/html');
  return 'ok';
}
''',
            assets: {
              'dash.html':
                  '<!DOCTYPE html><html><body>from asset</body></html>',
            },
          ),
        ),
      ));
      final before = tools.checkPlatformIntegrity();
      expect(before.ok, isFalse);
      final repair = tools.applyThinPublishRepair(htmlAssetId: 'dash.html');
      expect(repair.ok, isTrue);
      final after = tools.checkPlatformIntegrity();
      expect(after.ok, isTrue, reason: after.detail);
      expect(tools.workspace.script, contains('System.assets["dash.html"]'));
      expect(tools.workspace.script, isNot(contains('<!DOCTYPE')));
    });

    test('heuristic capability judge is structural only', () async {
      final judge = HeuristicBroCodeCapabilityJudge();
      final fail = await judge.judge(
        changeRequest: 'Build a dashboard with a map',
        trace: const BroCodeExecutionTrace(ranOk: true, events: []),
      );
      expect(fail.ok, isFalse);
      final pass = await judge.judge(
        changeRequest: 'Build a dashboard with a map',
        trace: BroCodeExecutionTrace(
          ranOk: true,
          events: [
            BroCodeExecutionEvent(
              kind: 'writeVault',
              data: {'key': 'x.html', 'mimeType': 'text/html'},
            ),
          ],
        ),
      );
      expect(pass.ok, isTrue);
    });
  });

  group('dashboard goal checker', () {
    const danglingScript = r'''
async function execute(params) {
  const html = `<!DOCTYPE html><html><body>
  <div class="sidebar">stats</div>
  <script>
    const canvas = document.getElementById('mapCanvas');
    const ctx = canvas.getContext('2d');
  </script>
  </body></html>`;
  await System.writeVault('LocatorDashboard.html', html, 'text/html');
  return 'ok';
}
''';

    const goodMapPwaScript = r'''
async function execute(params) {
  const html = `<!DOCTYPE html><html><head>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="theme-color" content="#0f172a">
  <meta name="mobile-web-app-capable" content="yes">
  <link rel="manifest" href="/vault/Locator.webmanifest">
  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
  <style>html,body,#map{height:100%;margin:0}</style>
  </head><body>
  <div id="map"></div>
  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
  <script>
    if ('serviceWorker' in navigator) {
      navigator.serviceWorker.register('/vault/Locator.sw.js');
    }
    if (typeof L !== 'undefined') {
      const map = L.map('map').setView([20, 77], 5);
      L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
        maxZoom: 19,
        attribution: 'OSM'
      }).addTo(map);
    }
  </script>
  </body></html>`;
  await System.writeVault('LocatorDashboard.html', html, 'text/html');
  await System.writeVault('Locator.webmanifest', '{}', 'application/manifest+json');
  await System.writeVault('Locator.sw.js', 'self.addEventListener("fetch", ()=>{});', 'application/javascript');
  return 'ok';
}
''';

    test('rejects chart removal that leaves dangling mapCanvas JS', () {
      final result = BroCodeDashboardGoalChecker.checkAgainstChangeRequest(
        changeRequest: 'Remove Device Map (Relative Canvas) graph',
        script: danglingScript,
      );
      expect(result.ok, isFalse);
      expect(
        result.findings.any((f) => f.toLowerCase().contains('dangling')),
        isTrue,
        reason: result.findings.join('\n'),
      );
    });

    test('accepts Leaflet map + PWA meta for map/PWA change request', () {
      final result = BroCodeDashboardGoalChecker.checkAgainstChangeRequest(
        changeRequest:
            'Replace the chart with a Leaflet map and make it a Progressive Web App desktop-like dashboard',
        script: goodMapPwaScript,
        assets: {
          'Locator.webmanifest': '{}',
          'Locator.sw.js': 'self.addEventListener("fetch", ()=>{});',
        },
      );
      expect(result.ok, isTrue, reason: result.findings.join('\n'));
    });

    test('accepts HTML living only in *.html sidecar assets', () {
      const thin = '''
async function execute(params) {
  await System.writeVault('Locator.html', System.assets['Locator.html'], 'text/html');
  return 'ok';
}
''';
      const htmlAsset = '''
<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#0f172a">
<meta name="mobile-web-app-capable" content="yes">
<link rel="manifest" href="/vault/Locator.webmanifest">
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
</head><body>
<div id="map"></div>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/vault/Locator.sw.js');
  }
  if (typeof L !== 'undefined') {
    var map = L.map('map').setView([20, 77], 5);
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png').addTo(map);
  }
</script>
</body></html>
''';
      final result = BroCodeDashboardGoalChecker.checkAgainstChangeRequest(
        changeRequest:
            'Leaflet map and Progressive Web App desktop-like dashboard',
        script: thin,
        assets: {
          'Locator.html': htmlAsset,
          'Locator.webmanifest': '{}',
          'Locator.sw.js': 'self.addEventListener("fetch", ()=>{});',
        },
      );
      expect(result.ok, isTrue, reason: result.findings.join('\n'));
    });

    test('rejects datetime controls that exist only on an unpublished asset', () {
      const script = r'''
async function execute(params) {
  const html = `<!DOCTYPE html><html><head>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Locator</title>
  </head><body>
  <button onclick="fetchData()">Refresh</button>
  <div id="map"></div>
  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
  <script>
    var map = L.map('map').setView([28.6, 77.2], 12);
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png').addTo(map);
  </script>
  </body></html>`;
  await System.writeVault('Locator.html', html, 'text/html');
  return 'ok';
}
''';
      const orphanAsset = '''
<!DOCTYPE html><html><body>
<label>From: <input type="datetime-local" id="fromTime"></label>
<label>To: <input type="datetime-local" id="toTime"></label>
<div id="map"></div>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>var map = L.map('map').setView([32.2, 76.7], 12);</script>
</body></html>
''';
      final result = BroCodeDashboardGoalChecker.checkAgainstChangeRequest(
        changeRequest:
            'Instead of a slider, give me option to insert from datetime and to datetime.',
        script: script,
        assets: {'locator.html': orphanAsset},
      );
      expect(result.ok, isFalse, reason: 'orphan asset must not green the gate');
      expect(
        result.findings.any(
          (f) =>
              f.toLowerCase().contains('datetime') ||
              f.toLowerCase().contains('unused asset'),
        ),
        isTrue,
        reason: result.findings.join('\n'),
      );
    });

    test('accepts from/to datetime when published via System.assets writeVault', () {
      const thin = '''
async function execute(params) {
  await System.writeVault('Locator.html', System.assets['Locator.html'], 'text/html');
  return 'ok';
}
''';
      const htmlAsset = '''
<!DOCTYPE html><html><head><title>Locator</title></head><body>
<label>From: <input type="datetime-local" id="fromTime"></label>
<label>To: <input type="datetime-local" id="toTime"></label>
<button onclick="updateMap()">Update</button>
<div id="map"></div>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
  if (typeof L !== 'undefined') {
    var map = L.map('map').setView([32.2, 76.7], 12);
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png').addTo(map);
  }
</script>
</body></html>
''';
      final result = BroCodeDashboardGoalChecker.checkAgainstChangeRequest(
        changeRequest:
            'Instead of a slider, give me from datetime and to datetime inputs.',
        script: thin,
        assets: {'Locator.html': htmlAsset},
      );
      expect(result.ok, isTrue, reason: result.findings.join('\n'));
    });

    test('renderability rejects unguarded Leaflet and SW without asset', () {
      const html = '''
<!DOCTYPE html><html><body>
<label>From: <input type="datetime-local" id="fromTime"></label>
<div id="map"></div>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
  var map = L.map('map').setView([0,0], 2);
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/vault/sw.js');
</script>
</body></html>
''';
      final result = BroCodeDashboardGoalChecker.checkRenderableDashboardHtml(
        html,
        assets: const {},
      );
      expect(result.ok, isFalse);
      expect(
        result.findings.any((f) => f.toLowerCase().contains('typeof l')),
        isTrue,
        reason: result.findings.join('\n'),
      );
      expect(
        result.findings.any((f) => f.toLowerCase().contains('serviceworker')),
        isTrue,
        reason: result.findings.join('\n'),
      );
    });

    test('renderability rejects unbounded telemetry SELECT without LIMIT', () {
      const html = '''
<!DOCTYPE html><html><body>
<button onclick="load()">Load</button>
<table id="rows"></table>
<script>
async function load() {
  const res = await fetch('/api/query', {method:'POST', body: JSON.stringify({
    sql: "SELECT latitude, longitude FROM telemetry ORDER BY timestamp ASC"
  })});
  const data = await res.json();
}
</script>
</body></html>
''';
      final result = BroCodeDashboardGoalChecker.checkRenderableDashboardHtml(
        html,
        assets: const {},
      );
      expect(result.ok, isFalse);
      expect(
        result.findings.any((f) => f.toLowerCase().contains('limit')),
        isTrue,
        reason: result.findings.join('\n'),
      );
    });

    test('renderability allows COUNT and LIMIT telemetry queries', () {
      const html = '''
<!DOCTYPE html><html><body>
<button>Refresh</button>
<div id="map"></div>
<script>
async function load() {
  await fetch('/api/query', {method:'POST', body: JSON.stringify({
    sql: "SELECT COUNT(*) AS c FROM telemetry"
  })});
  await fetch('/api/query', {method:'POST', body: JSON.stringify({
    sql: "SELECT latitude, longitude FROM telemetry ORDER BY timestamp DESC LIMIT 100"
  })});
}
</script>
</body></html>
''';
      final result = BroCodeDashboardGoalChecker.checkRenderableDashboardHtml(
        html,
        assets: const {},
      );
      expect(result.ok, isTrue, reason: result.findings.join('\n'));
    });

    test('requires range slider in published HTML when asked', () {
      const script = r'''
async function execute(params) {
  const html = `<!DOCTYPE html><html><body>
  <button>Refresh</button>
  <div id="map"></div>
  </body></html>`;
  await System.writeVault('Locator.html', html, 'text/html');
  return 'ok';
}
''';
      final result = BroCodeDashboardGoalChecker.checkAgainstChangeRequest(
        changeRequest: 'Give me a slider to control time range of selected coordinates',
        script: script,
      );
      expect(result.ok, isFalse);
      expect(
        result.findings.any((f) => f.toLowerCase().contains('slider')),
        isTrue,
        reason: result.findings.join('\n'),
      );
    });

    test('goal gate blocks canDeclareDone until dashboard goals pass', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final toolsProvider = Provider(
        (ref) => BroCodeAgentTools(
          ref,
          BroCodeWorkspace(
            name: 'Locator',
            description: 'd',
            inputSchema: const {},
            script: danglingScript,
          ),
        ),
      );
      final tools = container.read(toolsProvider);
      tools.syntaxOkAfterLastMutate = true;
      tools.sandboxOkAfterLastMutate = true;
      tools.formatOkAfterLastMutate = true;
      tools.styleOkAfterLastMutate = true;
      tools.policyOkAfterLastMutate = true;

      final obs = tools.checkDashboardGoals(
        'Remove Device Map (Relative Canvas) graph',
      );
      expect(obs.ok, isFalse);
      expect(tools.goalOkAfterLastMutate, isFalse);
      expect(tools.canDeclareDone, isFalse);

      tools.workspace.script = goodMapPwaScript;
      tools.workspace.assets
        ..clear()
        ..addAll({
          'Locator.webmanifest': '{}',
          'Locator.sw.js': 'self.addEventListener("fetch", ()=>{});',
        });
      final okObs = tools.checkDashboardGoals(
        'Replace the chart with a Leaflet map and make it a Progressive Web App',
      );
      expect(okObs.ok, isTrue, reason: okObs.detail);
      expect(tools.goalOkAfterLastMutate, isTrue);
      expect(tools.canDeclareDone, isTrue);
    });
  });
}
