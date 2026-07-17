import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/agents/agent_base.dart';
import 'package:project_aur_bhai/presentation/screens/ambient_hub.dart';

class _NamedBro extends BroCode {
  _NamedBro(this._name);
  final String _name;
  @override
  String get name => _name;
  @override
  String get description => '';
  @override
  Map<String, BroCodeParameter> get inputSchema => const {};
  @override
  Future<String> execute(Map<String, dynamic> parameters) async => '';
}

void main() {
  test('normalizeDashboardKeyStem strips html and Dashboard suffix', () {
    expect(normalizeDashboardKeyStem('Locator.html'), 'Locator');
    expect(normalizeDashboardKeyStem('LocatorDashboard.html'), 'Locator');
    expect(normalizeDashboardKeyStem('foo/bar/My_Map.html'), 'My Map');
  });

  test('findAgentForDashboardKey matches Locator.html → Locator', () {
    final agents = <BroCode>[
      _NamedBro('Calculator'),
      _NamedBro('Locator'),
    ];
    expect(findAgentForDashboardKey(agents, 'locator.html')?.name, 'Locator');
    expect(
      findAgentForDashboardKey(agents, 'LocatorDashboard.html')?.name,
      'Locator',
    );
    expect(findAgentForDashboardKey(agents, 'orphan.html'), isNull);
  });
}
