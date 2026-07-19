import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/config/app_config.dart';
import 'package:project_aur_bhai/core/pipeline/authoring_trace.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_fixture_report.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_workspace.dart';
import 'package:project_aur_bhai/core/services/bro_call_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('authoringTrace redacts secrets and caps turns', () {
    final turns = List.generate(
      AppConfig.authoringTraceMaxTurns + 5,
      (i) => AuthoringTurn(
        role: i.isEven ? 'user' : 'assistant',
        text: i == 0 ? 'api_key=sk-secret-should-hide' : 'turn $i',
        at: DateTime.now().toUtc(),
      ),
    );
    final trace = AuthoringTrace(
      agentName: 'Demo',
      provider: 'Google Gemini',
      modelId: 'gemini-2.0-flash',
      turns: turns,
      buildOutcome: 'built',
    ).sanitized();
    expect(trace.truncated, isTrue);
    expect(trace.turns.length, lessThanOrEqualTo(AppConfig.authoringTraceMaxTurns));
    expect(trace.turns.first.text, contains('***'));
    expect(trace.turns.first.text, isNot(contains('sk-secret')));
  });

  test('fixture bundle carries authoringTrace map', () {
    final at = DateTime.utc(2026, 7, 18);
    final report = BroCodeFixtureReport(
      exportedAt: at,
      appVersion: '1.0.0+1',
      workspace: BroCodeWorkspace(
        name: 'Demo',
        description: 'd',
        inputSchema: const {},
        script: 'async function execute(){ return "ok"; }',
      ),
      changeRequest: 'fix',
      failureMessage: 'x',
      authoringTrace: AuthoringTrace(
        agentName: 'Demo',
        turns: [
          AuthoringTurn(role: 'user', text: 'Build a counter', at: at),
        ],
        buildOutcome: 'built',
      ),
    );
    final json = report.toJson();
    expect(json['reportVersion'], 3);
    final bundle = BroCodeFixtureReport.reportToBundleJson(json);
    expect(bundle['authoringTrace'], isA<Map>());
    expect((bundle['authoringTrace'] as Map)['agentName'], 'Demo');
  });

  test('bro call ack detection', () {
    expect(BroCallService.textLooksLikeAck('Haan Bhai'), isTrue);
    expect(BroCallService.textLooksLikeAck('run calculator'), isFalse);
  });

  test('circle and issue copy for friends', () {
    expect(AppConfig.circleNotConfiguredHint.contains('Settings'), isTrue);
    expect(AppConfig.issueReporterNoteLabel.isNotEmpty, isTrue);
    expect(AppConfig.headsetRidingHint.contains('Bluetooth'), isTrue);
  });
}
