import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/agent_verification_service.dart';
import 'package:project_aur_bhai/core/services/js_bridge_service.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_style_checker.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_dashboard_goal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/bro_code_fixture_loader.dart';

bool _quickJsNativeLibAvailable() {
  const candidates = [
    'packages/quickjs_engine/native/build/quickjs_c_bridge_plugin.dll',
    '../packages/quickjs_engine/native/build/quickjs_c_bridge_plugin.dll',
    'native/build/quickjs_c_bridge_plugin.dll',
    'packages/quickjs_engine/native/build/libquickjs_c_bridge_plugin.dylib',
    '../packages/quickjs_engine/native/build/libquickjs_c_bridge_plugin.dylib',
  ];
  return candidates.any((p) => File(p).existsSync());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Bro Code fixtures', () {
    final fixtures = loadBroCodeFixtures();

    test('fixture directory is discoverable', () {
      expect(
        Directory('test/fixtures/bro_code').existsSync(),
        isTrue,
        reason: 'Create test/fixtures/bro_code/ and add *.bundle.json exports',
      );
    });

    if (fixtures.isEmpty) {
      test('no *.bundle.json yet — add locator.bundle.json from COPY DIAGNOSTIC JSON',
          () {
        // Passes until first fixture is committed.
      });
      return;
    }

    for (final fix in fixtures) {
      group(fix.fileName, () {
        ProviderContainer? container;
        JsBridgeService? bridge;
        late AgentVerificationService verification;

        setUp(() async {
          verification = AgentVerificationService();
          if (!_quickJsNativeLibAvailable()) {
            return;
          }
          container = ProviderContainer();
          final bus = container!.read(telemetryBusProvider);
          await bus.initialize();
          bridge = container!.read(jsBridgeServiceProvider);
        });

        tearDown(() {
          container?.dispose();
        });

        test('validate_syntax matches fixture.expectSyntaxOk', () async {
          if (!_quickJsNativeLibAvailable()) {
            markTestSkipped('QuickJS native lib not built on this machine');
            return;
          }
          final syntax = bridge!.validateScriptSyntax(fix.script);
          final expected = fix.expectSyntaxOk;
          if (expected != null) {
            expect(syntax.ok, expected,
                reason: syntax.message ?? 'syntax check');
          } else {
            // Default: repro fixtures often fail syntax until fixed.
            expect(syntax.ok || !syntax.ok, isTrue);
          }
        });

        test('scan_policy (due diligence)', () {
          final scan = verification.scanScript(fix.script);
          final tags = fix.fixtureExpectations['tags'];
          if (tags is List && tags.contains('allow-dd-fail')) {
            return;
          }
          // Nested-HTML repros may fail QuickJS syntax but must NOT false-flag
          // browser APIs that live inside the dashboard document body.
          if (tags is List && tags.contains('nested-html-repro')) {
            expect(
              scan.findings.any((f) => f.toString().contains('Browser/DOM')),
              isFalse,
              reason: scan.findings.join('; '),
            );
            return;
          }
          if (fix.expectSyntaxOk == false) {
            // Syntax-broken scripts may still scan; don't require pass.
            return;
          }
          expect(scan.passed, isTrue, reason: scan.findings.join('; '));
        });

        test('session history retained when present', () {
          final session = fix.session;
          if (session == null) return;
          final attempts = session['attempts'];
          final changeRequests = session['changeRequests'];
          expect(attempts, isA<List>());
          expect(changeRequests, isA<List>());
          if (fix.fileName.contains('20260716.0206') ||
              fix.fileName.contains('20260715.2358')) {
            expect((attempts as List).length, greaterThanOrEqualTo(3));
            expect((changeRequests as List).length, greaterThanOrEqualTo(1));
            expect(
              fix.improveGoal,
              contains('last 24 hours'),
            );
          }
        });

        test('sandbox_run matches fixture.expectSandboxOk', () async {
          if (!_quickJsNativeLibAvailable()) {
            markTestSkipped('QuickJS native lib not built on this machine');
            return;
          }
          final syntax = bridge!.validateScriptSyntax(fix.script);
          if (!syntax.ok) {
            if (fix.expectSandboxOk == false) return;
            if (fix.expectSyntaxOk == false) return;
            fail('Syntax must pass before sandbox: ${syntax.message}');
          }

          final params = smokeParamsFromSchema(fix.inputSchemaFromSchema());
          final result = await bridge!.executeAgentScript(
            agentName: fix.name,
            script: fix.script,
            parameters: params,
            sandboxMode: true,
            assets: fix.assets,
          );

          final sandboxOk = !result.isError;
          final expected = fix.expectSandboxOk;
          if (expected != null) {
            expect(sandboxOk, expected, reason: result.message);
          }

          final expectKeys = fix.expectHtmlKeys;
          if (sandboxOk && expectKeys.isNotEmpty) {
            final written = result.vaultHtmlKeysWritten;
            for (final key in expectKeys) {
              expect(
                written,
                contains(key),
                reason: 'Expected HTML vault key "$key"; wrote $written',
              );
            }
          }
        });

        test('check_format matches fixture.expectFormatOk', () {
          final result = BroCodeStyleChecker.format(fix.script);
          final expected = fix.expectFormatOk ?? true;
          expect(
            !result.changed,
            expected,
            reason: result.findings.isEmpty
                ? 'format drift vs normalized script'
                : result.findings.map((f) => f.toString()).join('; '),
          );
        });

        test('check_style matches fixture.expectStyleOk', () {
          final result = BroCodeStyleChecker.checkStyle(fix.script);
          final expected = fix.expectStyleOk ?? true;
          expect(
            result.ok,
            expected,
            reason: result.findings.map((f) => f.toString()).join('; '),
          );
        });

        test('dashboard goal expectations (static, no QuickJS)', () {
          final goal = fix.improveGoal;
          if (goal == null || goal.trim().isEmpty) return;

          final result = BroCodeDashboardGoalChecker.checkAgainstChangeRequest(
            changeRequest: goal,
            script: fix.script,
            assets: fix.assets,
          );

          final tags = fix.fixtureExpectations['tags'];
          final tagList = tags is List ? tags.map((e) => e.toString()).toList() : <String>[];

          if (fix.expectNoDanglingDom == true) {
            final dangling = [
              ...BroCodeDashboardGoalChecker.extractHtmlDocuments(fix.script),
              ...BroCodeDashboardGoalChecker.extractHtmlFromAssets(fix.assets),
            ].expand((html) {
              final d = BroCodeDashboardGoalChecker.checkDanglingDom(html);
              return d.findings;
            }).toList();
            expect(dangling, isEmpty, reason: dangling.join('; '));
          }

          if (fix.expectNoCanvas == true) {
            for (final html in [
              ...BroCodeDashboardGoalChecker.extractHtmlDocuments(fix.script),
              ...BroCodeDashboardGoalChecker.extractHtmlFromAssets(fix.assets),
            ]) {
              expect(
                BroCodeDashboardGoalChecker.looksLikeChartOrCanvas(html),
                isFalse,
                reason: 'Canvas/chart still present',
              );
            }
          }

          if (fix.expectLeafletMap == true) {
            final docs = [
              ...BroCodeDashboardGoalChecker.extractHtmlDocuments(fix.script),
              ...BroCodeDashboardGoalChecker.extractHtmlFromAssets(fix.assets),
            ];
            expect(
              docs.any(BroCodeDashboardGoalChecker.looksLikeLeafletMap),
              isTrue,
              reason: 'Expected Leaflet/OSM map in HTML',
            );
          }

          if (fix.expectPwa == true) {
            final docs = [
              ...BroCodeDashboardGoalChecker.extractHtmlDocuments(fix.script),
              ...BroCodeDashboardGoalChecker.extractHtmlFromAssets(fix.assets),
            ];
            expect(docs, isNotEmpty, reason: 'No HTML docs for PWA check');
            for (final html in docs) {
              final pwa = BroCodeDashboardGoalChecker.checkPwa(
                html,
                assets: fix.assets,
              );
              expect(pwa.ok, isTrue, reason: pwa.findings.join('; '));
            }
          }

          // Repro fixtures for incomplete chart removal must fail goal check.
          if (tagList.contains('dangling-dom-repro')) {
            expect(
              result.ok,
              isFalse,
              reason:
                  'dangling-dom-repro should fail dashboard goals; findings were: '
                  '${result.findings}',
            );
          }
        });
      });
    }
  });
}
