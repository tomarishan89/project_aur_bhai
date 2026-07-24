import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/config/app_config.dart';
import 'package:project_aur_bhai/core/services/circle_registry_service.dart';
import 'package:project_aur_bhai/core/services/issue_report_service.dart';
import 'package:project_aur_bhai/core/services/wake_word_service.dart';
import 'package:project_aur_bhai/core/services/secure_secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('wake listen path never persists audio', () async {
    final wake = WakeWordService(secretStore: MemorySecureSecretStore());
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(wake.listenPathPersistsAudio, isFalse);
    expect(AppConfig.wakePrivacyBody.contains('does not save'), isTrue);
    await wake.acknowledgePrivacy();
    expect(wake.privacyAcknowledged, isTrue);
    // Enabling without access key must not start native listen.
    await wake.setListenEnabled(true);
    expect(wake.isListening, isFalse);
    expect(wake.lastError, isNotNull);
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

  test('app config centralizes circle and wake keys', () {
    expect(AppConfig.circleIndexPath, 'commons/index.json');
    expect(AppConfig.circleDefaultRepo, 'aur_bhai_circle');
    expect(AppConfig.wakeWordInterimBuiltIn, 'Jarvis');
  });
}
