import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Universal Bro Code Asset Integrity Test', () {
    test('all assets/bro_code subdirectories contain valid scripts and dashboards', () {
      final broCodeDir = Directory('assets/bro_code');
      expect(
        broCodeDir.existsSync(),
        isTrue,
        reason: 'assets/bro_code directory must exist',
      );

      final subdirs = broCodeDir
          .listSync()
          .whereType<Directory>()
          .toList();

      expect(
        subdirs.isNotEmpty,
        isTrue,
        reason: 'At least one Bro Code bundle must exist in assets/bro_code',
      );

      for (final dir in subdirs) {
        final agentName = dir.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .last;

        final scriptFile = File('${dir.path}/script.js');
        expect(
          scriptFile.existsSync(),
          isTrue,
          reason: 'Bro Code "$agentName" must have a script.js',
        );

        final script = scriptFile.readAsStringSync().trim();
        expect(
          script.isNotEmpty,
          isTrue,
          reason: 'script.js for "$agentName" must not be empty',
        );

        // Enforce execute function signature for QuickJS Bridge compliance
        final hasExecute = RegExp(r'(async\s+)?function\s+execute\s*\(').hasMatch(script) ||
            RegExp(r'(const|let|var)\s+execute\s*=\s*(async\s*)?\(').hasMatch(script);

        expect(
          hasExecute,
          isTrue,
          reason:
              'Bro Code "$agentName" script.js MUST define an execute(params) function to prevent QuickJS boot crashes.',
        );

        final dashboardFile = File('${dir.path}/dashboard.html');
        if (dashboardFile.existsSync()) {
          final html = dashboardFile.readAsStringSync().trim();
          expect(
            html.isNotEmpty,
            isTrue,
            reason: 'dashboard.html for "$agentName" must not be empty',
          );
          expect(
            html.toLowerCase(),
            contains('<html'),
            reason: 'dashboard.html for "$agentName" must contain an <html> tag',
          );
        }
      }
    });
  });
}
