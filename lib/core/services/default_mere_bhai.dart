import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import 'llm_service.dart';

/// Sticky Command Center default Mere Bhai (voice + text).
class DefaultMereBhaiService extends ChangeNotifier {
  static const prefsKey = 'default_mere_bhai';

  String? _name;
  bool _loaded = false;

  String? get name => _name;
  bool get hasDefault => _name != null && _name!.trim().isNotEmpty;
  bool get isLoaded => _loaded;

  DefaultMereBhaiService() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKey)?.trim();
    _name = (raw == null || raw.isEmpty) ? null : raw;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setDefault(String? agentName) async {
    final trimmed = agentName?.trim();
    _name = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    final prefs = await SharedPreferences.getInstance();
    if (_name == null) {
      await prefs.remove(prefsKey);
    } else {
      await prefs.setString(prefsKey, _name!);
    }
    notifyListeners();
  }

  /// True when utterance already names a target via Ask/Tell.
  static bool hasExplicitAskTell(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    return RegExp(r'^(ask|tell)\s+\S+', caseSensitive: false).hasMatch(t);
  }

  /// Prefix for typed send when default is set and text has no Ask/Tell.
  String applyTextPrefix(String text) {
    final t = text.trim();
    if (!hasDefault || t.isEmpty) return t;
    if (hasExplicitAskTell(t)) return t;
    final target = _name!;
    final lower = t.toLowerCase();
    if (lower.contains(target.toLowerCase())) return t;
    return 'Ask $target: $t';
  }

  /// After LLM parse: force execute on default when appropriate.
  TurnParsedResponse applyToTurn(TurnParsedResponse turn) {
    if (!hasDefault) return turn;
    final target = _name!;
    if (turn.intent == AgentIntent.author ||
        turn.intent == AgentIntent.refine ||
        turn.intent == AgentIntent.feed) {
      return turn;
    }
    final explicit = turn.targetAgent?.trim();
    if (explicit != null && explicit.isNotEmpty) return turn;
    final transcript = turn.transcription.trim();
    if (hasExplicitAskTell(transcript)) return turn;

    return TurnParsedResponse(
      intent: AgentIntent.execute,
      targetAgent: target,
      parameters: turn.parameters ?? {'prompt': transcript},
      payload: turn.payload,
      transcription: turn.transcription,
      spec: turn.spec,
      assumptions: turn.assumptions,
      clarifyingQuestions: turn.clarifyingQuestions,
      readyToBuild: turn.readyToBuild,
      confirmation: turn.confirmation.isNotEmpty
          ? turn.confirmation
          : 'Running $target…',
      directResponse: turn.directResponse,
      reasoning: turn.reasoning,
      userObjected: turn.userObjected,
      objectedField: turn.objectedField,
    );
  }
}

final defaultMereBhaiProvider = ChangeNotifierProvider<DefaultMereBhaiService>((
  ref,
) {
  return DefaultMereBhaiService();
});
