/// Install a locked fixture bundle into the local sovereign vault as C4 Bro Code
/// so you can RUN it on your machine/phone after `flutter run`.
///
/// Prefers writing via a small JSON side-file that the debug app can import,
/// OR prints Import Agent paste instructions when vault path is unavailable.
///
/// Usage:
///   dart run tool/install_issue_fixture.dart --path test/fixtures/bro_code/issue.42….bundle.json
///   dart run tool/install_issue_fixture.dart --issue 42   # fetches then installs
///
/// Writes: `tool/.friend_install_queue.json` for the next app cold-start import
/// (see JsAgentRegistry.consumeFriendInstallQueueIfPresent).
library;

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  var path = _flag(args, '--path');
  final issue = _flag(args, '--issue');
  if (path == null && issue != null) {
    final r = await Process.run('dart', [
      'run',
      'tool/fetch_issue_fixture.dart',
      '--issue',
      issue,
    ], runInShell: true);
    stdout.write(r.stdout);
    stderr.write(r.stderr);
    if (r.exitCode != 0) exit(r.exitCode);
    final m = RegExp(r'path=(\S+)').firstMatch(r.stdout as String);
    path = m?.group(1);
  }
  if (path == null) {
    stderr.writeln('Pass --path <bundle.json> or --issue N');
    exit(2);
  }

  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('Missing $path');
    exit(1);
  }
  final bundle = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final name = bundle['name'] as String? ?? '';
  final script = bundle['script'] as String? ?? '';
  final schema = Map<String, dynamic>.from(bundle['schema'] as Map? ?? {});
  if (name.isEmpty || script.isEmpty) {
    stderr.writeln('Bundle missing name/script');
    exit(1);
  }

  final installName = name.startsWith('Friend_') ? name : 'Friend_$name';
  final queueFile = File('tool/.friend_install_queue.json');
  final payload = {
    'queuedAt': DateTime.now().toUtc().toIso8601String(),
    'sourcePath': path,
    'name': installName,
    'originalName': name,
    'description': schema['description'] ?? 'Installed from friend fixture',
    'script': script,
    'inputSchema': schema['inputSchema'] ?? {},
    'authoringTrace': bundle['authoringTrace'],
    'session': bundle['session'],
    'note': 'Do not Publish unless intentional.',
  };
  queueFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(payload),
  );
  stdout.writeln('Queued install → ${queueFile.path}');
  stdout.writeln('Agent will register as $installName (C4) on next app start.');
  stdout.writeln('Locked source: $path');
  if (bundle['authoringTrace'] != null) {
    stdout.writeln('authoringTrace: present');
  } else {
    stdout.writeln('authoringTrace: missing');
  }
}

String? _flag(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return null;
  return args[i + 1];
}
