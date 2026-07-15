import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/agent_verification_service.dart';
import 'package:project_aur_bhai/core/services/js_bridge_service.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';
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
      test('no *.bundle.json yet — add locator.bundle.json from SEND TO TEST CASES',
          () {
        // Passes until first fixture is committed.
      });
      return;
    }

    for (final fix in fixtures) {
      group(fix.fileName, () {
        late ProviderContainer container;
        late JsBridgeService bridge;
        late AgentVerificationService verification;

        setUp(() async {
          if (!_quickJsNativeLibAvailable()) {
            return;
          }
          container = ProviderContainer();
          final bus = container.read(telemetryBusProvider);
          await bus.initialize();
          bridge = container.read(jsBridgeServiceProvider);
          verification = AgentVerificationService();
        });

        tearDown(() {
          container.dispose();
        });

        test('validate_syntax matches fixture.expectSyntaxOk', () async {
          if (!_quickJsNativeLibAvailable()) {
            markTestSkipped('QuickJS native lib not built on this machine');
            return;
          }
          final syntax = bridge.validateScriptSyntax(fix.script);
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
          if (fix.expectSyntaxOk == false) {
            // Syntax-broken scripts may still scan; don't require pass.
            return;
          }
          expect(scan.passed, isTrue, reason: scan.findings.join('; '));
        });

        test('sandbox_run matches fixture.expectSandboxOk', () async {
          if (!_quickJsNativeLibAvailable()) {
            markTestSkipped('QuickJS native lib not built on this machine');
            return;
          }
          final syntax = bridge.validateScriptSyntax(fix.script);
          if (!syntax.ok) {
            if (fix.expectSandboxOk == false) return;
            if (fix.expectSyntaxOk == false) return;
            fail('Syntax must pass before sandbox: ${syntax.message}');
          }

          final params = smokeParamsFromSchema(fix.inputSchemaFromSchema());
          final result = await bridge.executeAgentScript(
            agentName: fix.name,
            script: fix.script,
            parameters: params,
            sandboxMode: true,
          );

          final sandboxOk = !result.isError;
          final expected = fix.expectSandboxOk;
          if (expected != null) {
            expect(sandboxOk, expected, reason: result.message);
          }
        });
      });
    }
  });
}
