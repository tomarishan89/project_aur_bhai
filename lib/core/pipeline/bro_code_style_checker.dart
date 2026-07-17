/// On-device Bro Code format + style checks (no Node / ESLint).
///
/// Format transforms are deterministic and safe. Style findings are coded so
/// the IMPROVE agent can fix them after observation — not leave them as noise.
library;

enum BroCodeStyleSeverity { info, warning, error }

class BroCodeStyleFinding {
  final String code;
  final String message;
  final int? line;
  final BroCodeStyleSeverity severity;

  const BroCodeStyleFinding({
    required this.code,
    required this.message,
    this.line,
    this.severity = BroCodeStyleSeverity.error,
  });

  Map<String, dynamic> toJson() => {
        'code': code,
        'message': message,
        if (line != null) 'line': line,
        'severity': severity.name,
      };

  @override
  String toString() {
    final loc = line != null ? 'L$line: ' : '';
    return '[$code] $loc$message';
  }
}

class BroCodeFormatResult {
  final List<BroCodeStyleFinding> findings;
  final String formattedScript;
  final bool changed;

  const BroCodeFormatResult({
    required this.findings,
    required this.formattedScript,
    required this.changed,
  });

  bool get ok => !changed && findings.isEmpty;
}

class BroCodeStyleResult {
  final List<BroCodeStyleFinding> findings;

  const BroCodeStyleResult({this.findings = const []});

  bool get ok =>
      findings.every((f) => f.severity != BroCodeStyleSeverity.error);

  List<BroCodeStyleFinding> get blocking => findings
      .where((f) => f.severity == BroCodeStyleSeverity.error)
      .toList();
}

/// Pure-Dart format + style checker for Bro Code JavaScript.
class BroCodeStyleChecker {
  static const int maxLineLength = 120;

  /// Deterministic safe format: CRLF→LF, strip trailing WS, single EOF newline.
  static BroCodeFormatResult format(String script) {
    final findings = <BroCodeStyleFinding>[];
    var body = script;

    if (body.contains('\r\n') || body.contains('\r')) {
      findings.add(const BroCodeStyleFinding(
        code: 'CRLF',
        message: 'Script uses CR/LF endings; normalize to LF.',
        severity: BroCodeStyleSeverity.warning,
      ));
      body = body.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    }

    final lines = body.split('\n');
    final stripped = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmedRight = line.replaceFirst(RegExp(r'[ \t]+$'), '');
      if (trimmedRight != line) {
        findings.add(BroCodeStyleFinding(
          code: 'TRAILING_WS',
          message: 'Trailing whitespace.',
          line: i + 1,
          severity: BroCodeStyleSeverity.warning,
        ));
      }
      stripped.add(trimmedRight);
    }

    // Drop empty trailing lines, then ensure exactly one trailing newline.
    while (stripped.isNotEmpty && stripped.last.isEmpty) {
      stripped.removeLast();
    }
    final formatted = '${stripped.join('\n')}\n';

    return BroCodeFormatResult(
      findings: findings,
      formattedScript: formatted,
      changed: formatted != script,
    );
  }

  /// Style lint outside HTML template strings. Blocking severities fail `done`.
  static BroCodeStyleResult checkStyle(String script) {
    final findings = <BroCodeStyleFinding>[];
    final sandbox = stripEmbeddedHtmlTemplates(script);
    final lines = sandbox.split('\n');

    var hasSpacesIndent = false;
    var hasTabsIndent = false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty) continue;
      final indent = RegExp(r'^([ \t]+)').firstMatch(line)?.group(1);
      if (indent == null) continue;
      if (indent.contains(' ') && indent.contains('\t')) {
        findings.add(BroCodeStyleFinding(
          code: 'MIXED_INDENT',
          message: 'Line mixes tabs and spaces in indentation.',
          line: i + 1,
        ));
      }
      if (indent.contains(' ')) hasSpacesIndent = true;
      if (indent.contains('\t')) hasTabsIndent = true;
    }
    if (hasSpacesIndent && hasTabsIndent) {
      findings.add(const BroCodeStyleFinding(
        code: 'MIXED_INDENT',
        message:
            'Script mixes tab-indented and space-indented lines outside HTML templates.',
      ));
    }

    for (var i = 0; i < lines.length; i++) {
      if (lines[i].length > maxLineLength) {
        findings.add(BroCodeStyleFinding(
          code: 'LINE_LENGTH',
          message: 'Line exceeds $maxLineLength characters (${lines[i].length}).',
          line: i + 1,
          severity: BroCodeStyleSeverity.warning,
        ));
      }
    }

    final executeMatches =
        RegExp(r'\basync\s+function\s+execute\s*\(').allMatches(sandbox).length;
    if (executeMatches == 0) {
      findings.add(const BroCodeStyleFinding(
        code: 'MISSING_EXECUTE',
        message: 'Missing `async function execute(...)` entry point.',
      ));
    } else if (executeMatches > 1) {
      findings.add(BroCodeStyleFinding(
        code: 'DUPLICATE_EXECUTE',
        message:
            'Found $executeMatches `async function execute` declarations; expected one.',
      ));
    }

    final consoleLog = RegExp(r'\bconsole\.log\s*\(');
    for (final m in consoleLog.allMatches(sandbox)) {
      findings.add(BroCodeStyleFinding(
        code: 'CONSOLE_LOG',
        message:
            'console.log outside HTML templates — use System.log in the QuickJS sandbox.',
        line: _lineOfOffset(sandbox, m.start),
      ));
    }

    return BroCodeStyleResult(findings: findings);
  }

  static int _lineOfOffset(String source, int offset) {
    var line = 1;
    final end = offset.clamp(0, source.length);
    for (var i = 0; i < end; i++) {
      if (source.codeUnitAt(i) == 0x0a) line++;
    }
    return line;
  }

  /// Strip backtick HTML templates so browser APIs inside dashboards are ignored.
  /// Mirrors the AgentVerificationService approach for Locator-like scripts.
  static String stripEmbeddedHtmlTemplates(String script) {
    final htmlDocuments = script.replaceAllMapped(
      RegExp(
        r'`\s*<!doctype[\s\S]*?</html>\s*`',
        caseSensitive: false,
        multiLine: true,
      ),
      (_) => '``',
    );

    final out = StringBuffer();
    var cursor = 0;
    while (cursor < htmlDocuments.length) {
      final start = htmlDocuments.indexOf('`', cursor);
      if (start < 0) {
        out.write(htmlDocuments.substring(cursor));
        break;
      }

      var end = start + 1;
      while (end < htmlDocuments.length) {
        if (htmlDocuments.codeUnitAt(end) == 0x60 &&
            !_isEscaped(htmlDocuments, end)) {
          break;
        }
        end++;
      }
      if (end >= htmlDocuments.length) {
        out.write(htmlDocuments.substring(cursor));
        break;
      }

      out.write(htmlDocuments.substring(cursor, start));
      final template = htmlDocuments.substring(start, end + 1);
      final lower = template.toLowerCase();
      final isHtml = lower.contains('<!doctype') ||
          lower.contains('<html') ||
          lower.contains('<head') ||
          lower.contains('<body') ||
          lower.contains('<script');
      out.write(isHtml ? '``' : template);
      cursor = end + 1;
    }
    return out.toString();
  }

  static bool _isEscaped(String source, int index) {
    var slashes = 0;
    for (var i = index - 1; i >= 0 && source.codeUnitAt(i) == 0x5c; i--) {
      slashes++;
    }
    return slashes.isOdd;
  }
}
