import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/services/vault_dashboard_url.dart';

void main() {
  test('isVaultDashboardUrl accepts /vault/<key.html>', () {
    expect(
      isVaultDashboardUrl('http://192.168.29.218:8080/vault/locator.html'),
      isTrue,
    );
    expect(
      isVaultDashboardUrl('http://localhost:8080/vault/locator.html'),
      isTrue,
    );
  });

  test('isVaultDashboardUrl rejects server root and api', () {
    expect(isVaultDashboardUrl('http://192.168.29.218:8080/'), isFalse);
    expect(isVaultDashboardUrl('http://192.168.29.218:8080'), isFalse);
    expect(
      isVaultDashboardUrl('http://192.168.29.218:8080/api/status'),
      isFalse,
    );
    expect(isVaultDashboardUrl('http://192.168.29.218:8080/vault/'), isFalse);
    expect(isVaultDashboardUrl('http://192.168.29.218:8080/vault'), isFalse);
  });

  test('vaultDashboardUrlError explains root mistake', () {
    final err = vaultDashboardUrlError('http://192.168.29.218:8080/');
    expect(err, isNotNull);
    expect(err!.toLowerCase(), contains('not a dashboard'));
    expect(err, contains('/vault/'));
  });

  test('normalizeVaultKeyForUrl rejects empty', () {
    expect(() => normalizeVaultKeyForUrl(''), throwsArgumentError);
    expect(() => normalizeVaultKeyForUrl('  '), throwsArgumentError);
    expect(normalizeVaultKeyForUrl('locator.html'), 'locator.html');
  });
}
