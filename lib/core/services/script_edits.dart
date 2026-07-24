import 'dart:convert';

/// Cline-style surgical search/replace edits for agent refine patches.
///
/// The model returns small [ScriptEdit]s; Dart applies them locally to vault
/// sources so large dashboard agents do not need a full-file rewrite.
class ScriptEdit {
  /// Exact substring that must appear in the target source.
  final String oldString;

  /// Replacement text (may be empty to delete).
  final String newString;

  /// When true, replace every occurrence; otherwise require exactly one match.
  final bool replaceAll;

  /// Optional vault asset id under `agent:<Name>:asset:<id>`.
  /// Null / empty means the main agent script.
  final String? asset;

  const ScriptEdit({
    required this.oldString,
    required this.newString,
    this.replaceAll = false,
    this.asset,
  });

  factory ScriptEdit.fromJson(Map<String, dynamic> json) {
    final oldB64 =
        json['oldStringBase64'] as String? ??
        json['old_string_base64'] as String?;
    final newB64 =
        json['newStringBase64'] as String? ??
        json['new_string_base64'] as String?;

    String? oldString;
    String? newString;

    if (oldB64 != null && oldB64.trim().isNotEmpty) {
      oldString = _decodeEditBase64(oldB64, field: 'oldStringBase64');
    } else {
      oldString = json['oldString'] as String? ?? json['old_string'] as String?;
    }
    if (newB64 != null && newB64.trim().isNotEmpty) {
      newString = _decodeEditBase64(newB64, field: 'newStringBase64');
    } else {
      newString = json['newString'] as String? ?? json['new_string'] as String?;
    }

    if (oldString == null || newString == null) {
      throw const FormatException(
        'Each edit needs oldStringBase64/newStringBase64 (preferred) or '
        'oldString/newString. Tap Retry — the app will repair automatically.',
      );
    }
    final assetRaw = json['asset'] as String? ?? json['file'] as String?;
    final asset = assetRaw?.trim();
    return ScriptEdit(
      oldString: oldString,
      newString: newString,
      replaceAll:
          json['replaceAll'] as bool? ?? json['replace_all'] as bool? ?? false,
      asset: (asset == null || asset.isEmpty) ? null : asset,
    );
  }

  /// True when this edit targets the main script (not a side asset).
  bool get isMainScript => asset == null || asset!.isEmpty;
}

String _decodeEditBase64(String b64, {required String field}) {
  final cleaned = b64.replaceAll(RegExp(r'\s+'), '');
  try {
    return utf8.decode(base64Decode(cleaned));
  } on FormatException catch (e) {
    throw FormatException('Invalid $field: ${e.message}');
  }
}

/// Applies [edits] sequentially to [source].
String applyScriptEdits(String source, List<ScriptEdit> edits) {
  if (edits.isEmpty) {
    throw const FormatException(
      'Model returned no edits. Tap Retry — the app will try another strategy.',
    );
  }

  var working = source;
  for (var i = 0; i < edits.length; i++) {
    final edit = edits[i];
    if (edit.oldString.isEmpty) {
      throw FormatException('Edit ${i + 1} has an empty oldString. Tap Retry.');
    }
    if (edit.oldString == edit.newString) {
      throw FormatException(
        'Edit ${i + 1} is a no-op (oldString equals newString). Tap Retry.',
      );
    }

    final applied = _applyOneEdit(working, edit, editIndex: i + 1);
    working = applied;
  }
  return working;
}

/// Exact match first; if none, fuzzy match ignoring runs of whitespace.
String _applyOneEdit(String source, ScriptEdit edit, {required int editIndex}) {
  final exact = _countOccurrences(source, edit.oldString);
  if (exact > 0) {
    if (!edit.replaceAll && exact > 1) {
      throw FormatException(
        'Edit $editIndex: oldString matched $exact times. '
        'Use a longer unique snippet or replaceAll.',
      );
    }
    if (edit.replaceAll) {
      return source.replaceAll(edit.oldString, edit.newString);
    }
    return source.replaceFirst(edit.oldString, edit.newString);
  }

  final fuzzy = findFuzzyWhitespaceMatch(source, edit.oldString);
  if (fuzzy == null) {
    throw FormatException(
      'Edit $editIndex: oldString not found in the script. Tap Retry.',
    );
  }
  if (!edit.replaceAll && fuzzy.matchCount > 1) {
    throw FormatException(
      'Edit $editIndex: fuzzy oldString matched ${fuzzy.matchCount} times. '
      'Use a longer unique snippet or replaceAll.',
    );
  }
  // Apply using the actual span from the source (preserves surrounding text).
  if (edit.replaceAll) {
    final pattern = _whitespaceFlexiblePattern(edit.oldString);
    if (pattern == null) {
      throw FormatException(
        'Edit $editIndex: oldString not found in the script. Tap Retry.',
      );
    }
    final matches = RegExp(
      pattern,
      multiLine: true,
    ).allMatches(source).toList();
    var working = source;
    for (final m in matches.reversed) {
      working = working.replaceRange(m.start, m.end, edit.newString);
    }
    return working;
  }
  return source.replaceRange(fuzzy.start, fuzzy.end, edit.newString);
}

/// Span of a fuzzy whitespace-insensitive match inside [source].
class FuzzyMatchSpan {
  final int start;
  final int end;
  final int matchCount;

  const FuzzyMatchSpan({
    required this.start,
    required this.end,
    required this.matchCount,
  });
}

/// Match [needle] in [source] allowing any whitespace run to match any other.
///
/// Returns the first span and total match count, or null if none.
FuzzyMatchSpan? findFuzzyWhitespaceMatch(String source, String needle) {
  if (needle.isEmpty) return null;
  final pattern = _whitespaceFlexiblePattern(needle);
  if (pattern == null) return null;
  final re = RegExp(pattern, multiLine: true);
  final all = re.allMatches(source).toList();
  if (all.isEmpty) return null;
  final first = all.first;
  return FuzzyMatchSpan(
    start: first.start,
    end: first.end,
    matchCount: all.length,
  );
}

/// Build a RegExp source that treats each whitespace run in [needle] as `\s+`.
String? _whitespaceFlexiblePattern(String needle) {
  final buf = StringBuffer();
  var i = 0;
  var sawNonWs = false;
  while (i < needle.length) {
    final c = needle[i];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      while (i < needle.length &&
          (needle[i] == ' ' ||
              needle[i] == '\t' ||
              needle[i] == '\n' ||
              needle[i] == '\r')) {
        i++;
      }
      if (sawNonWs) buf.write(r'\s+');
      continue;
    }
    sawNonWs = true;
    buf.write(RegExp.escape(c));
    i++;
  }
  final src = buf.toString();
  if (src.isEmpty || src == r'\s+') return null;
  return src;
}

int _countOccurrences(String source, String needle) {
  if (needle.isEmpty) return 0;
  var count = 0;
  var start = 0;
  while (true) {
    final index = source.indexOf(needle, start);
    if (index < 0) break;
    count++;
    start = index + needle.length;
  }
  return count;
}

/// Parses `edits` array from refine JSON. Returns null if the key is absent.
List<ScriptEdit>? parseScriptEdits(Map<String, dynamic> decoded) {
  if (!decoded.containsKey('edits')) return null;
  final raw = decoded['edits'];
  if (raw is! List) {
    throw const FormatException('edits must be an array. Tap Retry.');
  }
  if (raw.isEmpty) {
    throw const FormatException(
      'Model returned no edits. Tap Retry — the app will try another strategy.',
    );
  }
  return raw
      .whereType<Map>()
      .map((e) => ScriptEdit.fromJson(Map<String, dynamic>.from(e)))
      .toList();
}

/// Groups edits by asset id (`null` key = main script).
Map<String?, List<ScriptEdit>> groupEditsByAsset(List<ScriptEdit> edits) {
  final grouped = <String?, List<ScriptEdit>>{};
  for (final edit in edits) {
    final key = edit.isMainScript ? null : edit.asset;
    grouped.putIfAbsent(key, () => []).add(edit);
  }
  return grouped;
}

/// Max decoded size for legacy full-file `scriptBase64` fallback on refine.
const int kMaxLegacyRefineScriptChars = 12000;

/// Max model turns inside one IMPROVE verify/repair loop.
const int kMaxRefineModelTurns = 3;

/// Parsed QuickJS `<eval>:LINE:COL` location, if present.
class ScriptErrorLocation {
  final int line; // 1-based
  final int column; // 1-based

  const ScriptErrorLocation(this.line, this.column);
}

/// Extracts `at <eval>:34:16` style locations from QuickJS / run errors.
ScriptErrorLocation? parseScriptErrorLocation(String? error) {
  if (error == null || error.trim().isEmpty) return null;
  final match = RegExp(r'<eval>:(\d+):(\d+)').firstMatch(error);
  if (match == null) return null;
  final line = int.tryParse(match.group(1)!);
  final col = int.tryParse(match.group(2)!);
  if (line == null || col == null || line < 1) return null;
  return ScriptErrorLocation(line, col);
}

/// Builds a line-numbered excerpt around [location] for LLM prompts.
String buildScriptExcerpt(
  String script, {
  required ScriptErrorLocation location,
  int radius = 15,
}) {
  final lines = script.split('\n');
  if (lines.isEmpty) return script;
  final idx = (location.line - 1).clamp(0, lines.length - 1);
  final start = (idx - radius).clamp(0, lines.length - 1);
  final end = (idx + radius).clamp(0, lines.length - 1);
  final out = StringBuffer();
  out.writeln(
    'SCRIPT EXCERPT (lines ${start + 1}-${end + 1} of ${lines.length}; '
    'error near line ${location.line}:col ${location.column}):',
  );
  for (var i = start; i <= end; i++) {
    final marker = i == idx ? '>>' : '  ';
    out.writeln('$marker${(i + 1).toString().padLeft(4)}| ${lines[i]}');
  }
  return out.toString();
}

/// Result of a local SyntaxError attempt (no LLM).
class LocalSyntaxFixResult {
  final String script;
  final String notes;

  const LocalSyntaxFixResult({required this.script, required this.notes});
}

/// Local candidates for `expecting ';'` at a reported line:col.
///
/// Caller must validate each with QuickJS.
List<LocalSyntaxFixResult> localSyntaxFixCandidates(
  String script,
  String? lastRunError,
) {
  final err = lastRunError ?? '';
  if (!err.toLowerCase().contains('syntaxerror') &&
      !err.toLowerCase().contains("expecting ';'")) {
    return const [];
  }
  final loc = parseScriptErrorLocation(err);
  if (loc == null) return const [];

  final lines = script.split('\n');
  if (loc.line < 1 || loc.line > lines.length) return const [];
  final lineIndex = loc.line - 1;
  final originalLine = lines[lineIndex];
  final lineCandidates = <String>[];

  final colIndex = (loc.column - 1).clamp(0, originalLine.length);
  lineCandidates.add(
    '${originalLine.substring(0, colIndex)};${originalLine.substring(colIndex)}',
  );

  final trimmed = originalLine.trimRight();
  if (trimmed.isNotEmpty &&
      !trimmed.endsWith(';') &&
      !trimmed.endsWith('{') &&
      !trimmed.endsWith(',')) {
    lineCandidates.add('$trimmed;');
  }

  final results = <LocalSyntaxFixResult>[];
  final seen = <String>{};
  for (final candidateLine in lineCandidates) {
    if (candidateLine == originalLine) continue;
    final newLines = List<String>.from(lines);
    newLines[lineIndex] = candidateLine;
    final joined = newLines.join('\n');
    if (!seen.add(joined)) continue;
    results.add(
      LocalSyntaxFixResult(
        script: joined,
        notes:
            'Local fix: adjusted line ${loc.line} for missing semicolon (col ${loc.column}).',
      ),
    );
  }

  if (lineIndex > 0) {
    final prev = lines[lineIndex - 1].trimRight();
    if (prev.isNotEmpty &&
        !prev.endsWith(';') &&
        !prev.endsWith('{') &&
        !prev.endsWith(',') &&
        !prev.endsWith('(')) {
      final newLines = List<String>.from(lines);
      newLines[lineIndex - 1] = '$prev;';
      final joined = newLines.join('\n');
      if (seen.add(joined)) {
        results.add(
          LocalSyntaxFixResult(
            script: joined,
            notes:
                'Local fix: inserted semicolon at end of line ${loc.line - 1}.',
          ),
        );
      }
    }
  }

  return results;
}

/// User-facing message when surgical edits fail to apply.
String scriptEditFailureMessage(Object error) {
  final msg = error.toString();
  if (error is FormatException) {
    return error.message;
  }
  if (msg.contains('FormatException')) {
    return msg.replaceFirst('FormatException: ', '');
  }
  return msg;
}

/// Truncate raw model output for progress logs.
String truncateForLog(String raw, {int max = 200}) {
  final t = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.length <= max) return t;
  return '${t.substring(0, max)}…';
}
