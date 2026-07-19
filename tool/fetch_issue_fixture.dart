/// Fetch a friend fixture from a private circle GitHub Issue into
/// `test/fixtures/bro_code/`.
///
/// Usage (from Flutter project root; requires `gh` auth):
///   dart run tool/fetch_issue_fixture.dart --issue 42
///   dart run tool/fetch_issue_fixture.dart --agent Locator --latest
///   dart run tool/fetch_issue_fixture.dart --latest
///
/// Env: CIRCLE_OWNER, CIRCLE_REPO (default aur-bhai-circle)
library;

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final issueArg = _flag(args, '--issue');
  final agentArg = _flag(args, '--agent');
  final latest = args.contains('--latest') ||
      (issueArg == null && agentArg == null);

  final owner = Platform.environment['CIRCLE_OWNER'] ?? '';
  final repo = Platform.environment['CIRCLE_REPO'] ?? 'aur-bhai-circle';
  if (owner.isEmpty) {
    stderr.writeln('Set CIRCLE_OWNER (and optional CIRCLE_REPO).');
    exit(2);
  }

  final repoSlug = '$owner/$repo';
  final issues = await _ghJson(
    ['api', 'repos/$repoSlug/issues', '--jq', '.', '-f', 'state=open', '-f', 'labels=aur-bhai-report', '-f', 'per_page=50'],
  );
  if (issues is! List) {
    stderr.writeln('Unexpected gh response for issues list.');
    exit(1);
  }

  Map<String, dynamic>? chosen;
  if (issueArg != null) {
    final n = int.tryParse(issueArg.replaceAll('#', ''));
    if (n == null) {
      stderr.writeln('--issue must be a number');
      exit(2);
    }
    final one = await _ghJson(['api', 'repos/$repoSlug/issues/$n']);
    if (one is Map<String, dynamic>) chosen = one;
  } else {
    final matches = <Map<String, dynamic>>[];
    for (final e in issues.whereType<Map>()) {
      final m = Map<String, dynamic>.from(e);
      final body = (m['body'] as String? ?? '').toLowerCase();
      final title = (m['title'] as String? ?? '').toLowerCase();
      if (agentArg != null) {
        final a = agentArg.toLowerCase();
        if (!body.contains('agent: `$a`') &&
            !body.contains('agent: $a') &&
            !title.contains(a)) {
          continue;
        }
      }
      matches.add(m);
    }
    if (matches.isEmpty) {
      stderr.writeln(
        agentArg == null
            ? 'No open aur-bhai-report issues.'
            : 'No open aur-bhai-report issues matching agent=$agentArg. Ask which issue.',
      );
      exit(1);
    }
    if (!latest && matches.length > 1) {
      stderr.writeln('Ambiguous (${matches.length} matches). Pass --issue N or --latest.');
      for (final m in matches) {
        stderr.writeln('  #${m['number']} ${m['title']}');
      }
      exit(1);
    }
    matches.sort((a, b) => (b['number'] as int).compareTo(a['number'] as int));
    chosen = matches.first;
  }

  if (chosen == null) {
    stderr.writeln('Issue not found.');
    exit(1);
  }

  final number = chosen['number'] as int;
  final body = chosen['body'] as String? ?? '';
  final labels = ((chosen['labels'] as List?) ?? const [])
      .map((e) => e is Map ? e['name']?.toString() ?? '' : '$e')
      .toList();
  if (!labels.contains('aur-bhai-report') &&
      !body.contains('Aur Bhai fixture report')) {
    stderr.writeln('Issue #$number is not an aur-bhai-report fixture.');
    exit(1);
  }

  final jsonBlock = _extractJsonFence(body);
  if (jsonBlock == null) {
    stderr.writeln('Issue #$number has no ```json fixture fence.');
    exit(1);
  }

  late final Map<String, dynamic> bundle;
  try {
    bundle = jsonDecode(jsonBlock) as Map<String, dynamic>;
  } catch (e) {
    stderr.writeln('Fixture JSON parse failed: $e');
    exit(1);
  }

  final agent = (bundle['name'] as String? ?? 'agent')
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final stamp = DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(':', '')
      .replaceAll('.', '');
  final dir = Directory('test/fixtures/bro_code');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final destName = 'issue.$number.$agent.$stamp.bundle.json';
  final dest = File('${dir.path}${Platform.pathSeparator}$destName');
  dest.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(bundle));

  stdout.writeln(
    'Locked fixture: Issue #$number | agent=$agent | '
    'title=${chosen['title']} | path=${dest.path}',
  );
  stdout.writeln('Next: dart run tool/install_issue_fixture.dart --path ${dest.path}');
}

String? _flag(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return null;
  return args[i + 1];
}

String? _extractJsonFence(String body) {
  final re = RegExp(r'```json\s*([\s\S]*?)```', multiLine: true);
  final m = re.firstMatch(body);
  return m?.group(1)?.trim();
}

Future<dynamic> _ghJson(List<String> ghArgs) async {
  final r = await Process.run('gh', ghArgs, runInShell: true);
  if (r.exitCode != 0) {
    stderr.writeln(r.stderr);
    throw Exception('gh failed: ${r.exitCode}');
  }
  final out = (r.stdout as String).trim();
  if (out.isEmpty) return null;
  return jsonDecode(out);
}
