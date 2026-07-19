import 'dart:io';

/// Prints S3 device-acceptance status vs automated evidence.
///
/// Run: `dart run tool/device_acceptance_status.dart`
///
/// Physical Test Cases C–F still require a phone + BYOK; this tool does not
/// flip Kanban Accept — it documents what the suite already covers so §5.1
/// reviews stay honest.
void main() {
  const rows = <(String, String, String)>[
    (
      'Test Case D — JS Bridge',
      'MS-JS-BRIDGE-*',
      'AUTO: test/js_bridge_test.dart (QuickJS). PHYSICAL: Command Center "Run telemetry counter".',
    ),
    (
      'Test Case E — Author + Dashboard',
      'MS-USER-ECOSYSTEM / MS-TELEMETRY-DASHBOARD',
      'AUTO: conversational_author + telemetry_dashboard tests. PHYSICAL: AI author + open vault URL. Locator browser gate still open.',
    ),
    (
      'Test Case F — Intent / Calculator / Author / Refine',
      'MS-CORE-INTENT / CORE-JS / CONV-AUTHOR / AGENT-REFINE',
      'AUTO: core JS + refine IMPROVE path. PHYSICAL: voice/text intents on device.',
    ),
    (
      'Test Case C — Audio handshake',
      'MS-AUDIO-DIRECT-UX5',
      'PHYSICAL only — tap/double-tap recording path.',
    ),
    (
      'LLM Agnostic',
      'MS-LLM-AGNOSTIC-*',
      'PHYSICAL: Settings provider swap smoke.',
    ),
  ];

  stdout.writeln('S3 device acceptance — evidence map');
  stdout.writeln('=' * 60);
  for (final r in rows) {
    stdout.writeln(r.$1);
    stdout.writeln('  IDs: ${r.$2}');
    stdout.writeln('  ${r.$3}');
    stdout.writeln('');
  }
  stdout.writeln(
    'Kanban Accept: only after physical SOP green (§5.1). '
    'Do not mark TELEMETRY-DASHBOARD Accepted until Locator map+badge loads.',
  );
}
