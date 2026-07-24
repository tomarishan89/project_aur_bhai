import 'dart:io';

/// Pull the latest on-device Capture Fixture into `test/fixtures/bro_code/`.
///
/// Usage (phone connected via USB, debug build installed):
///   dart run tool/pull_bro_code_fixture.dart
///
/// Optional:
///   dart run tool/pull_bro_code_fixture.dart --name locator.my_repro.bundle.json
///   dart run tool/pull_bro_code_fixture.dart --serial R58T...
///
/// Does not require clipboard paste. Requires `adb` on PATH.
void main(List<String> args) async {
  String? outName;
  String? serial;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--name' && i + 1 < args.length) {
      outName = args[i + 1];
    }
    if ((args[i] == '--serial' || args[i] == '-s') && i + 1 < args.length) {
      serial = args[i + 1];
    }
  }

  const pkg = 'com.example.project_aur_bhai';
  const remoteDir = 'app_flutter/bro_code_fixtures';

  final fixturesDir = Directory('test/fixtures/bro_code');
  if (!fixturesDir.existsSync()) {
    stderr.writeln(
      'Missing ${fixturesDir.path} — run from the Flutter project root.',
    );
    exit(1);
  }

  final adb = await _which('adb');
  if (adb == null) {
    stderr.writeln('adb not found on PATH. Install Android platform-tools.');
    exit(1);
  }

  serial ??= await _pickDeviceSerial(adb);
  if (serial == null) {
    stderr.writeln(
      'No adb device found. Plug in the phone and enable USB debugging.',
    );
    exit(1);
  }
  stdout.writeln('Using device: $serial');

  List<String> adbArgs(List<String> rest) => ['-s', serial!, ...rest];

  // Prefer LATEST.name.txt (written by newer CAPTURE FIXTURE builds).
  // Note: `adb exec-out run-as cat missing` often exits 0 and puts the error
  // on stdout — treat that as a miss.
  String? deviceFileName;
  final nameResult = await Process.run(
    adb,
    adbArgs(['exec-out', 'run-as', pkg, 'cat', '$remoteDir/LATEST.name.txt']),
  );
  if (nameResult.exitCode == 0) {
    final raw = (nameResult.stdout as String).trim();
    final looksMissing =
        raw.contains('No such file') ||
        raw.contains('Permission denied') ||
        raw.contains('cat:') ||
        raw.contains('\n');
    if (raw.isNotEmpty && !looksMissing && raw.endsWith('.bundle.json')) {
      deviceFileName = raw;
    }
  }

  // Fallback: list captures and pick the newest timestamped *.bundle.json
  // (skips LATEST.bundle.json itself).
  if (deviceFileName == null) {
    final ls = await Process.run(
      adb,
      adbArgs(['exec-out', 'run-as', pkg, 'ls', remoteDir]),
    );
    if (ls.exitCode != 0) {
      stderr.writeln(
        'No captures on device yet.\n'
        'Hot-reload / rebuild, tap CAPTURE FIXTURE, then retry.\n'
        'adb stderr: ${ls.stderr}',
      );
      exit(1);
    }
    // Android `ls` often prints multiple names per line (columns).
    final names =
        (ls.stdout as String)
            .split(RegExp(r'\s+'))
            .map((e) => e.trim())
            .where(
              (e) => e.endsWith('.bundle.json') && e != 'LATEST.bundle.json',
            )
            .toList()
          ..sort();
    if (names.isEmpty) {
      stderr.writeln(
        'bro_code_fixtures/ is empty on device. Tap CAPTURE FIXTURE first.',
      );
      exit(1);
    }
    deviceFileName = names.last;
    stdout.writeln(
      'Note: LATEST.name.txt missing (older build). Using newest: $deviceFileName',
    );
  }

  final destName = outName ?? deviceFileName;
  if (!destName.endsWith('.bundle.json')) {
    stderr.writeln('Output name must end with .bundle.json (got: $destName)');
    exit(1);
  }

  // Prefer LATEST.bundle.json body when present; else the timestamped file.
  final remoteCandidates = [
    '$remoteDir/LATEST.bundle.json',
    '$remoteDir/$deviceFileName',
  ];

  final dest = File('${fixturesDir.path}${Platform.pathSeparator}$destName');
  var pulled = false;
  String? lastErr;
  for (final remote in remoteCandidates) {
    stdout.writeln('Trying $remote …');
    final pull = await Process.start(
      adb,
      adbArgs(['exec-out', 'run-as', pkg, 'cat', remote]),
    );
    final sink = dest.openWrite();
    await pull.stdout.pipe(sink);
    lastErr = await pull.stderr.transform(SystemEncoding().decoder).join();
    final code = await pull.exitCode;
    await sink.close();
    if (code == 0 && dest.existsSync() && dest.lengthSync() >= 8) {
      final head = dest.readAsStringSync().trimLeft();
      if (head.startsWith('{')) {
        pulled = true;
        break;
      }
    }
    if (dest.existsSync()) dest.deleteSync();
  }

  if (!pulled) {
    stderr.writeln('Pull failed. Last adb stderr: $lastErr');
    exit(1);
  }

  stdout.writeln('OK: ${dest.path} (${dest.lengthSync()} bytes)');
  stdout.writeln('');
  stdout.writeln('Next (no copy-paste):');
  stdout.writeln('  flutter test test/bro_code_fixtures_test.dart');
  stdout.writeln(
    '  Ask Cursor: "Investigate the new fixture $destName and fix the agent."',
  );
}

Future<String?> _pickDeviceSerial(String adb) async {
  final result = await Process.run(adb, ['devices']);
  if (result.exitCode != 0) return null;
  final lines = (result.stdout as String)
      .split(RegExp(r'\r?\n'))
      .skip(1)
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty && e.contains('\tdevice'))
      .toList();
  if (lines.isEmpty) return null;
  if (lines.length == 1) {
    return lines.first.split(RegExp(r'\s+')).first;
  }
  // Prefer a physical phone over emulator when several are connected.
  for (final line in lines) {
    final serial = line.split(RegExp(r'\s+')).first;
    if (!serial.startsWith('emulator-')) return serial;
  }
  return lines.first.split(RegExp(r'\s+')).first;
}

Future<String?> _which(String cmd) async {
  final result = await Process.run(Platform.isWindows ? 'where' : 'which', [
    cmd,
  ], runInShell: true);
  if (result.exitCode != 0) return null;
  final lines = (result.stdout as String)
      .split(RegExp(r'\r?\n'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty);
  return lines.isEmpty ? null : lines.first;
}
