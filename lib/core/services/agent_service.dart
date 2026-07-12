import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../agents/agent_base.dart';

class AgentService extends ChangeNotifier {
  final List<AurBhaiAgent> _agents = [];

  void registerAgent(AurBhaiAgent agent) {
    // Replace any existing agent with the same name so re-authoring/imports refresh in place.
    _agents.removeWhere((a) => a.name.toLowerCase() == agent.name.toLowerCase());
    _agents.add(agent);
    notifyListeners();
    debugPrint('[AgentService] Registered agent: ${agent.name}');
  }

  bool removeAgent(String name) {
    final before = _agents.length;
    _agents.removeWhere((a) => a.name.toLowerCase() == name.toLowerCase());
    final removed = _agents.length != before;
    if (removed) {
      notifyListeners();
      debugPrint('[AgentService] Removed agent: $name');
    }
    return removed;
  }

  List<AurBhaiAgent> get agents => List.unmodifiable(_agents);

  AurBhaiAgent? findAgent(String name) {
    try {
      return _agents.firstWhere(
        (a) => a.name.toLowerCase() == name.toLowerCase(),
      );
    } catch (_) {
      return null;
    }
  }
}

final agentServiceProvider = ChangeNotifierProvider<AgentService>((ref) {
  return AgentService();
});
