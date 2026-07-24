import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_fixture_capture.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_fixture_report.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_workspace.dart';
import 'package:project_aur_bhai/core/pipeline/bro_code_workspace_snapshot.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BroCodeFixtureCapture', () {
    test('safeStem sanitizes names', () {
      expect(
        BroCodeFixtureCapture.safeStem('Locator Dashboard'),
        'locator_dashboard',
      );
      expect(BroCodeFixtureCapture.safeStem(''), 'bro_code');
    });

    test('findRepoFixturesDir finds test/fixtures/bro_code', () {
      final dir = BroCodeFixtureCapture.findRepoFixturesDir();
      expect(dir, isNotNull);
      expect(dir!.path, contains('fixtures'));
      expect(dir.path, contains('bro_code'));
    });

    test(
      'writeBundle writes loadable *.bundle.json under overrideDir',
      () async {
        final tmp = await Directory.systemTemp.createTemp('bro_capture_');
        addTearDown(() => tmp.delete(recursive: true));

        final report = BroCodeFixtureReport(
          exportedAt: DateTime.now(),
          appVersion: 'test',
          workspace: BroCodeWorkspace(
            name: 'DemoCapture',
            description: 'd',
            inputSchema: const {},
            script: 'async function execute(params) { return "x"; }\n',
          ),
          changeRequest: 'fix me',
          failureMessage: 'not verified',
          expectSyntaxOk: false,
          expectSandboxOk: false,
        );

        final result = await BroCodeFixtureCapture.writeBundle(
          report,
          overrideDir: tmp,
        );
        expect(result.bundleFileName, contains('democapture'));
        expect(result.bundleFileName, endsWith('.bundle.json'));
        final file = File(result.path);
        expect(file.existsSync(), isTrue);
        final body = file.readAsStringSync();
        expect(body, contains('"name": "DemoCapture"'));
        expect(body, contains('dev-capture'));
      },
    );
  });

  group('BroCodeSnapshotStore', () {
    test('capture links parent and restore moves head', () {
      final store = BroCodeSnapshotStore();
      final ws = BroCodeWorkspace(
        name: 'SnapDemo',
        description: '',
        inputSchema: const {},
        script: 'v1',
      );
      final a = store.capture(workspace: ws, action: 'baseline');
      ws.script = 'v2';
      final b = store.capture(workspace: ws, action: 'apply_edit', turn: 1);
      expect(b.parentId, a.id);
      expect(store.headId, b.id);
      expect(store.snapshots.length, 2);

      final restored = store.restore(a.id);
      expect(restored?.script, 'v1');
      expect(store.headId, a.id);

      BroCodeSnapshotStore.applyToWorkspace(ws, restored!);
      expect(ws.script, 'v1');
    });

    test('toJson / loadFromJson round-trip', () {
      final store = BroCodeSnapshotStore();
      final ws = BroCodeWorkspace(
        name: 'SnapDemo',
        description: '',
        inputSchema: const {},
        script: 'abc',
        assets: const {'a.html': '<html></html>'},
      );
      store.capture(workspace: ws, action: 'baseline', gatesGreen: true);
      final json = store.toJson();
      final other = BroCodeSnapshotStore()..loadFromJson(json);
      expect(other.snapshots.length, 1);
      expect(other.head?.script, 'abc');
      expect(other.head?.assets['a.html'], contains('html'));
      expect(other.head?.gatesGreen, isTrue);
    });
  });
}
