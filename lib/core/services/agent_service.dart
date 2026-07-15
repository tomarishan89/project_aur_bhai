import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../agents/agent_base.dart';

/// In-memory registry of installed Bro Code units (Bhai log).
class BroCodeService extends ChangeNotifier {
  final List<BroCode> _items = [];

  void register(BroCode broCode) {
    _items.removeWhere(
      (a) => a.name.toLowerCase() == broCode.name.toLowerCase(),
    );
    _items.add(broCode);
    notifyListeners();
    debugPrint('[BroCodeService] Registered: ${broCode.name}');
  }

  /// @Deprecated Use [register].
  void registerAgent(BroCode agent) => register(agent);

  bool remove(String name) {
    final before = _items.length;
    _items.removeWhere((a) => a.name.toLowerCase() == name.toLowerCase());
    final removed = _items.length != before;
    if (removed) {
      notifyListeners();
      debugPrint('[BroCodeService] Removed: $name');
    }
    return removed;
  }

  /// @Deprecated Use [remove].
  bool removeAgent(String name) => remove(name);

  List<BroCode> get all => List.unmodifiable(_items);

  /// @Deprecated Use [all].
  List<BroCode> get agents => all;

  BroCode? find(String name) {
    try {
      return _items.firstWhere(
        (a) => a.name.toLowerCase() == name.toLowerCase(),
      );
    } catch (_) {
      return null;
    }
  }

  /// @Deprecated Use [find].
  BroCode? findAgent(String name) => find(name);
}

/// @Deprecated Use [BroCodeService].
typedef AgentService = BroCodeService;

final broCodeServiceProvider = ChangeNotifierProvider<BroCodeService>((ref) {
  return BroCodeService();
});

/// @Deprecated Use [broCodeServiceProvider].
final agentServiceProvider = broCodeServiceProvider;
