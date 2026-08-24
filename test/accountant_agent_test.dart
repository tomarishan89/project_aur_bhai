import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:project_aur_bhai/core/services/js_bridge_service.dart';
import 'package:project_aur_bhai/core/services/marketplace_catalog.dart';
import 'package:project_aur_bhai/core/services/telemetry_bus.dart';

bool _quickJsNativeLibAvailable() {
  final override = Platform.environment['LIBQUICKJSC_TEST_PATH'];
  if (override != null && override.isNotEmpty && File(override).existsSync()) {
    return true;
  }
  const candidates = [
    'packages/quickjs_engine/native/build/quickjs_c_bridge_plugin.dll',
    '../packages/quickjs_engine/native/build/quickjs_c_bridge_plugin.dll',
    'native/build/quickjs_c_bridge_plugin.dll',
  ];
  return candidates.any((p) => File(p).existsSync());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final quickJsAvailable = _quickJsNativeLibAvailable();

  late ProviderContainer container;
  late TelemetryBusService bus;
  late JsBridgeService bridge;
  late MarketplaceCatalog catalog;
  late String accountantScript;
  late String accountantDashboardHtml;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    accountantScript =
        File('assets/bro_code/accountant/script.js').readAsStringSync();
    accountantDashboardHtml =
        File('assets/bro_code/accountant/dashboard.html').readAsStringSync();
  });

  setUp(() async {
    container = ProviderContainer();
    bus = container.read(telemetryBusProvider);
    await bus.openSandbox(reset: true);
    bridge = container.read(jsBridgeServiceProvider);
    catalog = container.read(marketplaceCatalogProvider);
  });

  tearDown(() async {
    await bus.closeAndSeal();
    container.dispose();
  });

  group('TelemetryBus Expense Ledger CRUD', () {
    test('adds, retrieves, and totals expenses in SQLite vault', () async {
      await bus.addExpense(
        item: 'Flowers',
        amount: 70.0,
        category: 'Shopping',
      );
      await bus.addExpense(item: 'Biscuit', amount: 20.0, category: 'Food');
      await bus.addExpense(item: 'Tea', amount: 15.0, category: 'Food');

      final all = await bus.getExpenses();
      expect(all.length, 3);
      expect(all[0]['item'], 'Tea');
      expect(all[1]['item'], 'Biscuit');
      expect(all[2]['item'], 'Flowers');

      final totalAll = await bus.getTotalExpenses();
      expect(totalAll, 105.0);

      final totalFood = await bus.getTotalExpenses(category: 'Food');
      expect(totalFood, 35.0);

      final firstId = all.first['id'] as String;
      await bus.deleteExpense(firstId);
      final remaining = await bus.getExpenses();
      expect(remaining.length, 2);
      expect(await bus.getTotalExpenses(), 90.0);
    });
  });

  group('Accountant Asset Bundle Integrity', () {
    test('script.js and dashboard.html contain required functionality', () {
      expect(accountantScript, contains('parseExpensesFromText'));
      expect(accountantScript, contains('CATEGORY_MAP'));
      expect(accountantScript, contains('accountant_ledger.json'));
      expect(accountantScript, contains('accountant.html'));
      expect(
        accountantScript,
        contains('Anything else to add, or is that all?'),
      );

      expect(accountantDashboardHtml, contains('ACCOUNTANT'));
      expect(accountantDashboardHtml, contains('c-donut'));
      expect(accountantDashboardHtml, contains('c-trend'));
      expect(accountantDashboardHtml, contains('exportCSV'));
      expect(accountantDashboardHtml, contains('saveManualExpense'));
    });
  });

  group('Accountant Bro Code JS Execution', () {
    test(
      'parses multi-item voice phrases and returns conversational confirmation',
      () async {
        final sidecars = {'dashboard.html': accountantDashboardHtml};

        // Test multi-item feed execution
        final result = await bridge.executeAgentScript(
          agentName: 'Accountant',
          script: accountantScript,
          parameters: {
            'text': 'Tell Accountant I spent 70 on Flowers, 20 on biscuit',
          },
          assets: sidecars,
        );

        expect(result.isError, isFalse);
        final output = result.message;
        expect(output, contains('Logged ₹70 on Flowers'));
        expect(output, contains('₹20 on Biscuit'));
        expect(output, contains('total 90 rupees'));
        expect(output, contains('Anything else to add, or is that all?'));

        // Verify that accountant_ledger.json and accountant.html were written to vault
        final ledgerRaw = await bus.readVaultData('accountant_ledger.json');
        expect(ledgerRaw, isNotNull);
        final ledgerData = jsonDecode(ledgerRaw!['value']!);
        expect(ledgerData['expenses'].length, 2);

        final dashboardData = await bus.readVaultData('accountant.html');
        expect(dashboardData, isNotNull);
        expect(dashboardData!['value'], contains('ACCOUNTANT'));
      },
      skip: quickJsAvailable
          ? false
          : 'QuickJS native library not built on host (executes on target device)',
    );

    test(
      'answers spending questions accurately based on recorded expenses',
      () async {
        final sidecars = {'dashboard.html': accountantDashboardHtml};

        // 1. First record some expenses
        await bridge.executeAgentScript(
          agentName: 'Accountant',
          script: accountantScript,
          parameters: {
            'text': 'spent 120 on Groceries and 50 on coffee and 300 on shoes',
          },
          assets: sidecars,
        );

        // 2. Ask question about category
        final catQuery = await bridge.executeAgentScript(
          agentName: 'Accountant',
          script: accountantScript,
          parameters: {'query': 'How much did I spend on food?'},
          assets: sidecars,
        );
        expect(catQuery.message, contains('₹50 on Food'));

        // 3. Ask question about total
        final totalQuery = await bridge.executeAgentScript(
          agentName: 'Accountant',
          script: accountantScript,
          parameters: {'query': 'What is my total expenditure?'},
          assets: sidecars,
        );
        expect(totalQuery.message, contains('₹470 across 3 entries'));

        // 4. Ask about highest spend
        final highestQuery = await bridge.executeAgentScript(
          agentName: 'Accountant',
          script: accountantScript,
          parameters: {'query': 'What was my highest spend?'},
          assets: sidecars,
        );
        expect(highestQuery.message, contains('₹300 on Shoes'));
      },
      skip: quickJsAvailable
          ? false
          : 'QuickJS native library not built on host (executes on target device)',
    );

    test(
      'launches dashboard when requested via voice',
      () async {
        final sidecars = {'dashboard.html': accountantDashboardHtml};

        final res = await bridge.executeAgentScript(
          agentName: 'Accountant',
          script: accountantScript,
          parameters: {'action': 'dashboard'},
          assets: sidecars,
        );

        expect(res.isError, isFalse);
        expect(res.message, contains('Opening your expenditure dashboard'));
        expect(res.vaultHtmlKeysWritten, contains('accountant.html'));
      },
      skip: quickJsAvailable
          ? false
          : 'QuickJS native library not built on host (executes on target device)',
    );
  });

  group('Marketplace Catalog & Bundles', () {
    test(
      'seed catalog contains Accountant and Telemeter without placeholders',
      () {
        final listings = catalog.listings();
        final ids = listings.map((l) => l.id).toList();

        expect(ids, contains('pool-accountant'));
        expect(ids, contains('pool-telemeter'));
        expect(ids, isNot(contains('pool-tip-jar')));
        expect(ids, isNot(contains('pool-hello-counter')));
      },
    );
  });
}
