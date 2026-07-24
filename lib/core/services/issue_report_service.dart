import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../pipeline/bro_code_fixture_report.dart';
import 'circle_registry_service.dart';
import 'secure_secret_store.dart';

enum IssueReportStatus {
  received,
  diagnosing,
  needMoreInfo,
  fixedInBuild,
  closed,
}

IssueReportStatus issueStatusFromLabel(String? raw) {
  switch ((raw ?? '').toLowerCase()) {
    case 'diagnosing':
      return IssueReportStatus.diagnosing;
    case 'need-more-info':
    case 'need_more_info':
      return IssueReportStatus.needMoreInfo;
    case 'fixed':
    case 'fixed-in-build':
      return IssueReportStatus.fixedInBuild;
    case 'closed':
      return IssueReportStatus.closed;
    default:
      return IssueReportStatus.received;
  }
}

class IssueReport {
  final String id;
  final int? githubIssueNumber;
  final String title;
  final IssueReportStatus status;
  final String? statusNote;
  final DateTime createdAt;
  final String? agentName;

  const IssueReport({
    required this.id,
    required this.title,
    required this.status,
    required this.createdAt,
    this.githubIssueNumber,
    this.statusNote,
    this.agentName,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'githubIssueNumber': githubIssueNumber,
    'title': title,
    'status': status.name,
    'statusNote': statusNote,
    'createdAt': createdAt.toIso8601String(),
    'agentName': agentName,
  };

  factory IssueReport.fromJson(Map<String, dynamic> json) {
    return IssueReport(
      id: json['id'] as String? ?? '',
      githubIssueNumber: json['githubIssueNumber'] as int?,
      title: json['title'] as String? ?? '',
      status: IssueReportStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => IssueReportStatus.received,
      ),
      statusNote: json['statusNote'] as String?,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      agentName: json['agentName'] as String?,
    );
  }

  IssueReport copyWith({IssueReportStatus? status, String? statusNote}) =>
      IssueReport(
        id: id,
        githubIssueNumber: githubIssueNumber,
        title: title,
        status: status ?? this.status,
        statusNote: statusNote ?? this.statusNote,
        createdAt: createdAt,
        agentName: agentName,
      );
}

/// User-consented fixture → GitHub Issue → local status (MVP-S12).
class IssueReportService extends ChangeNotifier {
  IssueReportService(this._ref, {SecureSecretStore? secretStore})
    : _secrets =
          secretStore ??
          (Platform.environment.containsKey('FLUTTER_TEST')
              ? MemorySecureSecretStore()
              : FlutterSecureSecretStore());

  final Ref _ref;
  final SecureSecretStore _secrets;
  final http.Client _http = http.Client();
  final List<IssueReport> _reports = [];

  List<IssueReport> get reports => List.unmodifiable(_reports);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(AppConfig.issuePrefsLocalKey);
    _reports.clear();
    if (raw == null || raw.isEmpty) {
      notifyListeners();
      return;
    }
    try {
      final list = jsonDecode(raw) as List;
      for (final e in list.whereType<Map>()) {
        _reports.add(IssueReport.fromJson(Map<String, dynamic>.from(e)));
      }
    } catch (e) {
      debugPrint('[IssueReport] load: $e');
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AppConfig.issuePrefsLocalKey,
      jsonEncode(_reports.map((e) => e.toJson()).toList()),
    );
  }

  /// Create GitHub Issue with fixture JSON body (consent already obtained in UI).
  Future<IssueReport> sendReport({
    required BroCodeFixtureReport report,
    required String title,
    String? reporterNote,
  }) async {
    final circle = _ref.read(circleRegistryProvider);
    await circle.loadConfig();
    if (!circle.isConfigured) {
      throw Exception(
        'Configure circle GitHub owner / repo / token in Settings first.',
      );
    }

    final prefs = await SharedPreferences.getInstance();
    final owner = prefs.getString(AppConfig.circlePrefsOwnerKey) ?? '';
    final repo =
        prefs.getString(AppConfig.circlePrefsRepoKey) ??
        AppConfig.circleDefaultRepo;
    final token = await _secrets.read(AppConfig.circlePrefsTokenKey) ?? '';

    final bundle = BroCodeFixtureReport.reportToBundleJson(report.toJson());
    final agentName = report.workspace.name;
    final note = (reporterNote ?? '').trim();
    final body = StringBuffer()
      ..writeln('## Aur Bhai fixture report')
      ..writeln()
      ..writeln('- Agent: `$agentName`')
      ..writeln('- Created: ${DateTime.now().toUtc().toIso8601String()}')
      ..writeln();
    if (note.isNotEmpty) {
      body
        ..writeln('### Reporter note')
        ..writeln()
        ..writeln(note)
        ..writeln();
    }
    body
      ..writeln('<details><summary>fixture bundle</summary>')
      ..writeln()
      ..writeln('```json')
      ..writeln(const JsonEncoder.withIndent('  ').convert(bundle))
      ..writeln('```')
      ..writeln()
      ..writeln('</details>');

    final issueTitle = note.isEmpty
        ? title
        : (note.length > 72 ? '${note.substring(0, 72)}…' : note);
    final uri = Uri.parse('https://api.github.com/repos/$owner/$repo/issues');
    final res = await _http.post(
      uri,
      headers: {
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $token',
        'X-GitHub-Api-Version': '2022-11-28',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'title': note.isEmpty ? title : '[$agentName] $issueTitle',
        'body': body.toString(),
        'labels': ['aur-bhai-report', 'received'],
      }),
    );
    if (res.statusCode != 201) {
      throw Exception(
        'Create issue failed: HTTP ${res.statusCode} ${res.body}',
      );
    }
    final created = jsonDecode(res.body) as Map<String, dynamic>;
    final number = created['number'] as int?;
    final local = IssueReport(
      id: 'rpt-${DateTime.now().microsecondsSinceEpoch}',
      githubIssueNumber: number,
      title: title,
      status: IssueReportStatus.received,
      createdAt: DateTime.now().toUtc(),
      agentName: agentName,
    );
    _reports.insert(0, local);
    await _persist();
    notifyListeners();
    return local;
  }

  /// Refresh status from GitHub labels (open-on-resume / pull-to-refresh).
  Future<void> refreshStatuses() async {
    final circle = _ref.read(circleRegistryProvider);
    await circle.loadConfig();
    if (!circle.isConfigured) return;

    final prefs = await SharedPreferences.getInstance();
    final owner = prefs.getString(AppConfig.circlePrefsOwnerKey) ?? '';
    final repo =
        prefs.getString(AppConfig.circlePrefsRepoKey) ??
        AppConfig.circleDefaultRepo;
    final token = await _secrets.read(AppConfig.circlePrefsTokenKey) ?? '';

    for (var i = 0; i < _reports.length; i++) {
      final r = _reports[i];
      final n = r.githubIssueNumber;
      if (n == null) continue;
      try {
        final uri = Uri.parse(
          'https://api.github.com/repos/$owner/$repo/issues/$n',
        );
        final res = await _http.get(
          uri,
          headers: {
            'Accept': 'application/vnd.github+json',
            'Authorization': 'Bearer $token',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        );
        if (res.statusCode != 200) continue;
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final labels =
            (body['labels'] as List?)
                ?.map((e) => (e is Map ? e['name'] : e)?.toString() ?? '')
                .toList() ??
            const <String>[];
        IssueReportStatus status = IssueReportStatus.received;
        for (final label in labels) {
          final mapped = issueStatusFromLabel(label);
          if (mapped != IssueReportStatus.received) {
            status = mapped;
            break;
          }
        }
        if (body['state'] == 'closed') {
          status = IssueReportStatus.closed;
        }
        final note = body['body'] as String?;
        _reports[i] = r.copyWith(
          status: status,
          statusNote: note != null && note.length > 120
              ? '${note.substring(0, 120)}…'
              : note,
        );
      } catch (e) {
        debugPrint('[IssueReport] refresh #$n: $e');
      }
    }
    await _persist();
    notifyListeners();
  }
}

final issueReportServiceProvider = ChangeNotifierProvider<IssueReportService>((
  ref,
) {
  final svc = IssueReportService(ref);
  unawaited(svc.load());
  return svc;
});
