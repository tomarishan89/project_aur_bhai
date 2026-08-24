import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/config/app_config.dart';
import 'package:project_aur_bhai/core/services/circle_registry_service.dart';
import 'package:project_aur_bhai/core/services/issue_report_service.dart';
void main() {
  test('wake privacy copy and free-engine labels', () {
    expect(AppConfig.wakePrivacyBody.contains('does not save'), isTrue);
    expect(AppConfig.wakeWordInterimBuiltIn, 'Hey Jarvis');
    expect(AppConfig.wakeCustomPpnHint.toLowerCase(), contains('openwakeword'));
  });

  test('circle listing bundle round-trip JSON', () {
    const listing = CircleListing(
      id: 'hello',
      name: 'Hello',
      description: 'desc',
      license: 'remix_free',
      revisionId: 'rev-1',
      author: 'tester',
      script: 'async function execute(){ return "ok"; }',
    );
    final again = CircleListing.fromBundleJson(listing.toBundleJson());
    expect(again.name, 'Hello');
    expect(again.license, 'remix_free');
    expect(again.toMarketplaceListing().license, 'remix_free');
  });

  test('issue status label mapping', () {
    expect(issueStatusFromLabel('diagnosing'), IssueReportStatus.diagnosing);
    expect(
      issueStatusFromLabel('fixed-in-build'),
      IssueReportStatus.fixedInBuild,
    );
    expect(issueStatusFromLabel('received'), IssueReportStatus.received);
    final r = IssueReport(
      id: '1',
      title: 't',
      status: IssueReportStatus.received,
      createdAt: DateTime.now(),
      githubIssueNumber: 3,
    );
    expect(jsonDecode(jsonEncode(r.toJson()))['githubIssueNumber'], 3);
  });

  test('app config centralizes circle and free wake labels', () {
    expect(AppConfig.circleIndexPath, 'commons/index.json');
    expect(AppConfig.circleDefaultRepo, 'aur_bhai_circle');
    expect(AppConfig.wakeWordInterimBuiltIn, 'Hey Jarvis');
  });
}
