import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:project_aur_bhai/core/agents/agent_base.dart';
import 'package:project_aur_bhai/core/agents/js_agent_adapter.dart';
import 'package:project_aur_bhai/core/models/lineage_entry.dart';
import 'package:project_aur_bhai/core/services/bhai_code_origin.dart';
import 'package:project_aur_bhai/core/services/byok_service.dart';
import 'package:project_aur_bhai/core/services/secure_secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Sovereign Identity & ByokService Handle Management', () {
    test('defaults userHandle to @you when unconfigured', () async {
      SharedPreferences.setMockInitialValues({});
      final store = MemorySecureSecretStore();
      final byok = ByokService(secretStore: store);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(byok.userHandle, '@you');
    });

    test('loads saved handle with @ prefix normalization', () async {
      SharedPreferences.setMockInitialValues({
        'user_identity_handle': 'ishan_dev',
      });
      final store = MemorySecureSecretStore();
      final byok = ByokService(secretStore: store);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(byok.userHandle, '@ishan_dev');
    });

    test('updateUserHandle normalizes and persists to SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final store = MemorySecureSecretStore();
      final byok = ByokService(secretStore: store);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Update with no @ prefix
      await byok.updateUserHandle('satya');
      expect(byok.userHandle, '@satya');

      final prefs1 = await SharedPreferences.getInstance();
      expect(prefs1.getString('user_identity_handle'), '@satya');

      // Update with existing @ and leading whitespace
      await byok.updateUserHandle('  @neo  ');
      expect(byok.userHandle, '@neo');

      final prefs2 = await SharedPreferences.getInstance();
      expect(prefs2.getString('user_identity_handle'), '@neo');

      // Update with empty string falls back to @you
      await byok.updateUserHandle('   ');
      expect(byok.userHandle, '@you');
    });
  });

  group('BhaiCodeOrigin & JsAgentAdapter Sovereign Handle Resolution', () {
    test('BhaiCodeOrigin.formatHandle handles edge cases', () {
      expect(BhaiCodeOrigin.formatHandle(null), '@you');
      expect(BhaiCodeOrigin.formatHandle(''), '@you');
      expect(BhaiCodeOrigin.formatHandle('   '), '@you');
      expect(BhaiCodeOrigin.formatHandle('user1'), '@user1');
      expect(BhaiCodeOrigin.formatHandle('@user2'), '@user2');
      expect(BhaiCodeOrigin.formatHandle('  @user3  '), '@user3');
      expect(BhaiCodeOrigin.formatHandle(null, fallback: '@guest'), '@guest');
    });

    test('BhaiCodeOrigin.handleFor resolves based on source and author', () {
      // Pool seed catalog
      expect(
        BhaiCodeOrigin.handleFor(source: BhaiCodeOrigin.pool, author: 'Aur Bhai Team'),
        '@core',
      );
      expect(
        BhaiCodeOrigin.handleFor(source: BhaiCodeOrigin.pool, author: '@core'),
        '@core',
      );

      // Self authored
      expect(
        BhaiCodeOrigin.handleFor(source: BhaiCodeOrigin.self, author: null, userHandle: '@ishan'),
        '@ishan',
      );
      expect(
        BhaiCodeOrigin.handleFor(source: BhaiCodeOrigin.self, author: 'alice', userHandle: '@ishan'),
        '@alice',
      );

      // Friend circle
      expect(
        BhaiCodeOrigin.handleFor(source: BhaiCodeOrigin.friendCircle, author: 'bob'),
        '@bob',
      );
      expect(
        BhaiCodeOrigin.handleFor(source: BhaiCodeOrigin.friendCircle, author: null),
        '@friend',
      );
    });

    test('JsAgentAdapter displayHandle respects author field and fallback', () {
      final dummyProvider = Provider<Ref>((ref) => ref);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ref = container.read(dummyProvider);

      final coreAgent = JsAgentAdapter(
        ref: ref,
        name: 'Calc',
        description: '',
        inputSchema: {},
        script: '',
        source: BhaiCodeOrigin.pool,
        author: '@core',
      );
      expect(coreAgent.displayHandle(), '@core');

      final userAgent = JsAgentAdapter(
        ref: ref,
        name: 'MyNotes',
        description: '',
        inputSchema: {},
        script: '',
        source: BhaiCodeOrigin.self,
        author: '@ishan',
      );
      expect(userAgent.displayHandle(), '@ishan');

      final customAuthorAgent = JsAgentAdapter(
        ref: ref,
        name: 'QuickDraft',
        description: '',
        inputSchema: {},
        script: '',
        source: BhaiCodeOrigin.self,
        author: '@neo',
      );
      expect(customAuthorAgent.displayHandle(), '@neo');

      final defaultAuthorAgent = JsAgentAdapter(
        ref: ref,
        name: 'DefaultDraft',
        description: '',
        inputSchema: {},
        script: '',
        source: BhaiCodeOrigin.self,
      );
      expect(defaultAuthorAgent.displayHandle(), '@you');
    });
  });
}
