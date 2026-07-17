import 'dart:convert';
import 'dart:io';

/// Repairs phone-exported locator.bundle.json that contains unescaped quotes
/// inside the script string, then tags it for dangling-DOM regression.
void main() {
  final file = File('test/fixtures/bro_code/locator.bundle.json');
  final raw = file.readAsStringSync();

  Map<String, dynamic>? parsed;
  try {
    parsed = jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    parsed = null;
  }

  if (parsed == null) {
    // Manual extraction for broken export: find broCode.script between markers.
    final scriptStart = raw.indexOf('"script": "');
    if (scriptStart < 0) {
      stderr.writeln('Cannot find script field');
      exit(1);
    }
    var i = scriptStart + '"script": "'.length;
    final scriptBuf = StringBuffer();
    // Read until we hit `", "schema"` at the broCode level — heuristics after
    // a newline-terminated `}` of execute, looking for `", "schema"`.
    final endMarker = '", "schema"';
    final endAt = raw.indexOf(endMarker, i);
    if (endAt < 0) {
      stderr.writeln('Cannot find end of script');
      exit(1);
    }
    // Between i and endAt the content used raw " without escapes.
    scriptBuf.write(raw.substring(i, endAt));
    // Unescape \" that may already be present for HTML attrs.
    var script = scriptBuf.toString().replaceAll(r'\"', '"');

    final nameMatch = RegExp(r'"name":\s*"([^"]+)"').firstMatch(raw);
    final goalMatch =
        RegExp(r'"improveGoal":\s*"([^"]*)"').firstMatch(raw) ??
            RegExp(r'"changeRequest":\s*"([^"]*)"').firstMatch(raw);

    parsed = {
      'reportVersion': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'appVersion': '1.0.0+1',
      'broCode': {
        'name': nameMatch?.group(1) ?? 'Locator',
        'script': script,
        'schema': {
          'name': nameMatch?.group(1) ?? 'Locator',
          'description': 'locator',
          'inputSchema': {},
        },
      },
      'improve': {
        'changeRequest':
            goalMatch?.group(1) ?? 'Remove Device Map (Relative Canvas) graph',
        'dueDiligenceFindings': [],
        'agentActivity': [],
        'failureMessage':
            'Agent used 12 turns without a verified result. Tap Retry to continue.',
        'turnsUsed': 12,
        'estimatedTokensUsed': 0,
        'diagnostics': {'failingObservations': []},
      },
      'fixture': {
        'expectSyntaxOk': false,
        'expectSandboxOk': false,
        'improveGoal':
            goalMatch?.group(1) ?? 'Remove Device Map (Relative Canvas) graph',
        'tags': ['repro', 'improve-failed', 'dangling-dom-repro'],
        'expectNoDanglingDom': false,
      },
    };
    stdout.writeln('Repaired invalid JSON export into valid fixture.');
  } else {
    final fixture = Map<String, dynamic>.from(
      parsed['fixture'] as Map? ?? {},
    );
    final tags = [
      ...((fixture['tags'] as List?)?.map((e) => e.toString()) ??
          const <String>[]),
    ];
    for (final t in ['repro', 'improve-failed', 'dangling-dom-repro']) {
      if (!tags.contains(t)) tags.add(t);
    }
    fixture['tags'] = tags;
    fixture['expectNoDanglingDom'] = false;
    parsed['fixture'] = fixture;
    stdout.writeln('Updated fixture tags on already-valid JSON.');
  }

  file.writeAsStringSync(jsonEncode(parsed));
  stdout.writeln('Wrote ${file.path} (${file.lengthSync()} bytes)');
}
