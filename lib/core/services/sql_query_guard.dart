/// Shared read-only SQL gate for `/api/query` and `System.querySQL`.
///
/// Rejects writes, multi-statement, pragma/attach, disallowed tables, and
/// unbounded telemetry row dumps (aggregates may omit LIMIT).
class SqlQueryGuard {
  SqlQueryGuard._();

  static const int defaultMaxRows = 2000;
  static const Set<String> allowedTables = {
    'telemetry',
    'imu_telemetry',
    'sovereign_vault',
  };

  static const _forbiddenKeywords = [
    'INSERT',
    'UPDATE',
    'DELETE',
    'DROP',
    'ALTER',
    'CREATE',
    'ATTACH',
    'DETACH',
    'REPLACE',
    'TRUNCATE',
    'PRAGMA',
    'VACUUM',
    'REINDEX',
    'GRANT',
    'REVOKE',
  ];

  /// Validates [sql]. Throws [SqlQueryRejected] on failure.
  static void validate(String sql, {int maxRows = defaultMaxRows}) {
    final trimmed = sql.trim();
    if (trimmed.isEmpty) {
      throw const SqlQueryRejected('Empty SQL');
    }
    final upper = trimmed.toUpperCase();

    // Allow a single trailing semicolon; reject any other ';'.
    final withoutTrailingSemi = trimmed.replaceFirst(RegExp(r';\s*$'), '');
    if (withoutTrailingSemi.contains(';')) {
      throw const SqlQueryRejected('Multi-statement SQL is not allowed');
    }

    if (!RegExp(r'^\s*SELECT\b', caseSensitive: false).hasMatch(trimmed)) {
      throw const SqlQueryRejected('Only SELECT queries are permitted');
    }

    for (final word in _forbiddenKeywords) {
      if (RegExp('\\b$word\\b').hasMatch(upper)) {
        throw SqlQueryRejected('Forbidden keyword: $word');
      }
    }

    final tables = _extractFromTables(upper);
    if (tables.isEmpty) {
      // SELECT without FROM (e.g. SELECT 1) — allow.
    } else {
      for (final t in tables) {
        if (!allowedTables.contains(t.toLowerCase())) {
          throw SqlQueryRejected('Table not allowlisted: $t');
        }
      }
    }

    final touchesTelemetry = tables.any(
      (t) =>
          t.toLowerCase() == 'telemetry' || t.toLowerCase() == 'imu_telemetry',
    );
    if (touchesTelemetry &&
        !_isAggregateOnlySelect(trimmed) &&
        !RegExp(r'\bLIMIT\b', caseSensitive: false).hasMatch(trimmed)) {
      throw const SqlQueryRejected(
        'Telemetry SELECT requires LIMIT (or use COUNT/SUM/AVG/MIN/MAX only)',
      );
    }

    final limitMatch = RegExp(
      r'\bLIMIT\s+(\d+)',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (limitMatch != null) {
      final n = int.tryParse(limitMatch.group(1) ?? '') ?? 0;
      if (n > maxRows) {
        throw SqlQueryRejected('LIMIT $n exceeds max $maxRows');
      }
    }
  }

  static List<String> _extractFromTables(String upperSql) {
    final out = <String>[];
    final re = RegExp(r'\bFROM\s+([A-Z_][A-Z0-9_]*)', caseSensitive: false);
    for (final m in re.allMatches(upperSql)) {
      out.add(m.group(1)!);
    }
    final joinRe = RegExp(r'\bJOIN\s+([A-Z_][A-Z0-9_]*)', caseSensitive: false);
    for (final m in joinRe.allMatches(upperSql)) {
      out.add(m.group(1)!);
    }
    return out;
  }

  static bool _isAggregateOnlySelect(String sql) {
    final s = sql.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final m = RegExp(
      r'select\s+(.+?)\s+from\s+(telemetry|imu_telemetry)\b',
    ).firstMatch(s);
    if (m == null) return false;
    final projection = m.group(1)!;
    if (RegExp(r'(^|,)\s*\*\s*(,|$)').hasMatch(projection)) return false;
    final withoutAggs = projection.replaceAll(
      RegExp(r'\b(count|sum|avg|min|max)\s*\([^)]*\)(\s+as\s+[a-z_][\w]*)?'),
      '',
    );
    return RegExp(r'^[\s,]*$').hasMatch(withoutAggs);
  }
}

class SqlQueryRejected implements Exception {
  final String message;
  const SqlQueryRejected(this.message);

  @override
  String toString() => 'SqlQueryRejected: $message';
}
