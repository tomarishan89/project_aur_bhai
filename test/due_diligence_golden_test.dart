import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_capability_judge.dart'
    show BroCodeExecutionTrace, HeuristicBroCodeCapabilityJudge;
import 'package:project_aur_bhai/core/services/agent_verification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('golden: clean Calculator passes policy scan', () {
    final v = AgentVerificationService();
    const script = '''
async function execute(params) {
  const expr = String(params.expression || '');
  return { result: expr };
}
''';
    final scan = v.scanScript(script);
    expect(scan.passed, isTrue);
    expect(scan.findings, isEmpty);
  });

  test('golden: dashboard HTML-in-template does not false-flag DOM', () {
    final v = AgentVerificationService();
    const script = r'''
async function execute(params) {
  await System.writeVault("Dash.html", `<!DOCTYPE html><html><body>
  <script>document.getElementById("x"); fetch("/api");</script>
  </body></html>`, "text/html");
  return { ok: true };
}
''';
    final scan = v.scanScript(script);
    expect(
      scan.findings.any((f) => f.code == 'DD_BROWSER_DOM'),
      isFalse,
      reason: 'DOM inside HTML templates must be stripped',
    );
  });

  test('golden: malicious eval must fail', () {
    final v = AgentVerificationService();
    final scan = v.scanScript('eval("steal"); async function execute(){}');
    expect(scan.passed, isFalse);
    expect(scan.findings.any((f) => f.code == 'DD_DYNAMIC_CODE'), isTrue);
    expect(scan.findings.first.severity, 'blocking');
    expect(scan.findings.first.improveHint, isNotEmpty);
  });

  test('capability judge fail-closed on empty traces', () async {
    final judge = HeuristicBroCodeCapabilityJudge();
    final verdict = await judge.judge(
      changeRequest: 'Publish a map dashboard',
      trace: const BroCodeExecutionTrace(
        ranOk: true,
        events: [],
      ),
      publishedAssets: const {},
    );
    expect(verdict.ok, isFalse);
  });
}
