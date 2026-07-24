import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'bro_code_fixture_report.dart';

/// Result of writing a Bro Code fixture to disk (dev-loop capture).
class BroCodeFixtureCaptureResult {
  final String path;
  final bool wroteToRepoFixtures;
  final String bundleFileName;

  /// One-liner for the host PC to pull this capture into the repo (Android).
  final String pullHint;

  const BroCodeFixtureCaptureResult({
    required this.path,
    required this.wroteToRepoFixtures,
    required this.bundleFileName,
    this.pullHint = '',
  });
}

/// Dev-mode exporter: dump IMPROVE workspace + diagnostics to a `*.bundle.json`.
///
/// Prefer writing into the repo's `test/fixtures/bro_code/` when the process
/// cwd (or an ancestor) is the Flutter project root. Otherwise fall back to
/// the app documents directory so mobile/emulator captures are still usable.
class BroCodeFixtureCapture {
  BroCodeFixtureCapture._();

  /// Sanitize Bro Code name for a file stem.
  static String safeStem(String name) {
    final cleaned = name
        .trim()
        .replaceAll(RegExp(r'[^\w\-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return cleaned.isEmpty ? 'bro_code' : cleaned.toLowerCase();
  }

  /// Walk [start] and parents looking for `pubspec.yaml` + `test/fixtures/bro_code`.
  static Directory? findRepoFixturesDir([Directory? start]) {
    var dir = start ?? Directory.current;
    for (var i = 0; i < 8; i++) {
      final pubspec = File('${dir.path}${Platform.pathSeparator}pubspec.yaml');
      final fixtures = Directory(
        '${dir.path}${Platform.pathSeparator}test'
        '${Platform.pathSeparator}fixtures'
        '${Platform.pathSeparator}bro_code',
      );
      if (pubspec.existsSync() && fixtures.existsSync()) {
        return fixtures;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  /// Write [report] as a committed-style bundle JSON.
  ///
  /// When [forceDocuments] is true, always use app documents (tests can set
  /// this). In release builds this still works but UI should only call from
  /// `kDebugMode`.
  static Future<BroCodeFixtureCaptureResult> writeBundle(
    BroCodeFixtureReport report, {
    bool forceDocuments = false,
    Directory? overrideDir,
  }) async {
    final stem = safeStem(report.workspace.name);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '')
        .replaceAll('-', '')
        .substring(0, 15);
    final fileName = '$stem.$stamp.bundle.json';

    final bundle = BroCodeFixtureReport.reportToBundleJson(report.toJson());
    // Keep a compact improve snapshot for E2E / notes without full report noise.
    bundle['capture'] = {
      'exportedAt': report.exportedAt.toIso8601String(),
      'appVersion': report.appVersion,
      'failureMessage': report.failureMessage,
      'turnsUsed': report.turnsUsed,
      'tags': ['dev-capture', 'repro'],
    };

    Directory target;
    var wroteToRepo = false;
    if (overrideDir != null) {
      target = overrideDir;
    } else if (!forceDocuments) {
      final repo = findRepoFixturesDir();
      if (repo != null) {
        target = repo;
        wroteToRepo = true;
      } else {
        target = await getApplicationDocumentsDirectory();
        target = Directory(
          '${target.path}${Platform.pathSeparator}bro_code_fixtures',
        );
      }
    } else {
      target = await getApplicationDocumentsDirectory();
      target = Directory(
        '${target.path}${Platform.pathSeparator}bro_code_fixtures',
      );
    }

    if (!target.existsSync()) {
      target.createSync(recursive: true);
    }

    final encoded = const JsonEncoder.withIndent('  ').convert(bundle);
    final file = File('${target.path}${Platform.pathSeparator}$fileName');
    await file.writeAsString(encoded);

    // Stable pointer so `dart run tool/pull_bro_code_fixture.dart` can find
    // the newest capture without knowing the timestamped name.
    final latest = File(
      '${target.path}${Platform.pathSeparator}LATEST.bundle.json',
    );
    await latest.writeAsString(encoded);
    final latestName = File(
      '${target.path}${Platform.pathSeparator}LATEST.name.txt',
    );
    await latestName.writeAsString(fileName);

    if (kDebugMode) {
      debugPrint('[BroCodeFixtureCapture] wrote ${file.path}');
      debugPrint('[BroCodeFixtureCapture] also wrote ${latest.path}');
    }

    final pullHint = wroteToRepo
        ? 'Already in repo: test/fixtures/bro_code/$fileName'
        : 'On your PC (device connected):\n'
              '  dart run tool/pull_bro_code_fixture.dart\n'
              'This pulls LATEST.bundle.json from the phone into '
              'test/fixtures/bro_code/$fileName';

    return BroCodeFixtureCaptureResult(
      path: file.path,
      wroteToRepoFixtures: wroteToRepo,
      bundleFileName: fileName,
      pullHint: pullHint,
    );
  }

  /// Relative path under the Android app data dir (for `adb run-as`).
  static const androidRelativeDir = 'app_flutter/bro_code_fixtures';
  static const androidPackageId = 'com.example.project_aur_bhai';
}
