import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/sql_query_guard.dart';

void main() {
  group('SqlQueryGuard ENG3', () {
    test('allows aggregate telemetry without LIMIT', () {
      expect(
        () => SqlQueryGuard.validate('SELECT COUNT(*) AS c FROM telemetry'),
        returnsNormally,
      );
    });

    test('allows trailing semicolon on SELECT', () {
      expect(
        () => SqlQueryGuard.validate('SELECT COUNT(*) AS c FROM telemetry;'),
        returnsNormally,
      );
    });

    test('rejects unbounded telemetry dump', () {
      expect(
        () => SqlQueryGuard.validate('SELECT * FROM telemetry'),
        throwsA(isA<SqlQueryRejected>()),
      );
    });

    test('rejects writes and pragma', () {
      expect(
        () => SqlQueryGuard.validate('DELETE FROM telemetry'),
        throwsA(isA<SqlQueryRejected>()),
      );
      expect(
        () => SqlQueryGuard.validate('PRAGMA table_info(telemetry)'),
        throwsA(isA<SqlQueryRejected>()),
      );
    });

    test('rejects unknown tables', () {
      expect(
        () => SqlQueryGuard.validate('SELECT * FROM sqlite_master LIMIT 1'),
        throwsA(isA<SqlQueryRejected>()),
      );
    });
  });
}
