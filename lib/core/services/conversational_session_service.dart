import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../pipeline/authoring_trace.dart';
import 'app_spec.dart';
import 'author_prompts.dart';

/// User response during confirm / scope phases.
enum SessionResponseIntent { affirm, deny, amend, cancel, buildShortcut, other }

enum SessionKind { none, author, refine }

enum SessionPhase { eliciting, review, compiling }

/// Holds multi-turn conversational state across handshakes (Arch v3.7).
class ConversationalSessionService extends ChangeNotifier {
  SessionKind _kind = SessionKind.none;
  SessionPhase _phase = SessionPhase.eliciting;

  AppSpec _appSpec = AppSpec();
  List<AppSpecSlot> _lastEchoedSlots = [];

  String? _refineTarget;
  String? _refineIssue;
  String? _refineLoadedScript;
  Map<String, dynamic>? _refineLoadedSchema;
  String? _refineLoadedDescription;
  String? _pendingPatchDescription;
  String? _pendingPatchScript;
  String? _pendingPatchAgentDescription;
  Map<String, dynamic>? _pendingPatchInputSchema;
  Map<String, String> _pendingAssetUpdates = const {};

  SessionKind get kind => _kind;
  SessionPhase get phase => _phase;
  bool get isActive => _kind != SessionKind.none;

  AppSpec get appSpec => _appSpec;

  /// Back-compat alias.
  AuthoringSpec get authorSpec => AuthoringSpec(
    purpose: _appSpec.purpose.value,
    triggers: _appSpec.invocationPrompt.value,
    name: _appSpec.name.value,
  );

  List<AppSpecSlot> get lastEchoedSlots => List.unmodifiable(_lastEchoedSlots);

  String? get refineTarget => _refineTarget;
  String? get refineIssue => _refineIssue;
  String? get refineLoadedScript => _refineLoadedScript;
  Map<String, dynamic>? get refineLoadedSchema => _refineLoadedSchema;
  String? get refineLoadedDescription => _refineLoadedDescription;
  String? get pendingPatchDescription => _pendingPatchDescription;
  String? get pendingPatchScript => _pendingPatchScript;
  String? get pendingPatchAgentDescription => _pendingPatchAgentDescription;
  Map<String, dynamic>? get pendingPatchInputSchema => _pendingPatchInputSchema;
  Map<String, String> get pendingAssetUpdates =>
      Map.unmodifiable(_pendingAssetUpdates);

  /// Last due-diligence findings surfaced during review/build (for UI).
  DueDiligenceSnapshot? _lastScan;
  DueDiligenceSnapshot? get lastScan => _lastScan;

  /// In-session authoring form log (typed/spoken). Frozen to vault on BUILD.
  final List<AuthoringTurn> _authoringTurns = [];
  String? _authorProvider;
  String? _authorModelId;

  List<AuthoringTurn> get authoringTurns => List.unmodifiable(_authoringTurns);

  void setAuthorModel({String? provider, String? modelId}) {
    _authorProvider = provider;
    _authorModelId = modelId;
  }

  void appendAuthoringTurn({
    required String role,
    required String text,
    String? phase,
  }) {
    if (_kind != SessionKind.author) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _authoringTurns.add(
      AuthoringTurn(
        role: role,
        text: trimmed,
        at: DateTime.now().toUtc(),
        phase: phase ?? _phase.name,
        provider: _authorProvider,
        modelId: _authorModelId,
        llmSlot: 'author',
      ),
    );
  }

  AuthoringTrace buildAuthoringTrace({
    required String agentName,
    required String buildOutcome,
    Map<String, dynamic>? appSpecAtBuild,
  }) {
    return AuthoringTrace(
      agentName: agentName,
      provider: _authorProvider,
      modelId: _authorModelId,
      llmSlot: 'author',
      turns: List.unmodifiable(_authoringTurns),
      appSpecAtBuild: appSpecAtBuild,
      buildOutcome: buildOutcome,
    ).sanitized();
  }

  void setLastScan({required bool passed, required List<String> findings}) {
    _lastScan = DueDiligenceSnapshot(passed: passed, findings: findings);
    notifyListeners();
  }

  void clearLastScan() {
    _lastScan = null;
    notifyListeners();
  }

  /// English fast-path for confirmation / objection / build shortcut.
  static SessionResponseIntent classifyResponseLocal(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return SessionResponseIntent.other;

    bool hasWord(String w) =>
        RegExp('\\b${RegExp.escape(w)}\\b').hasMatch(t) || t == w;

    const buildPhrases = [
      'build it',
      'build now',
      'go ahead and build',
      'create it',
      'make it',
      'ship it',
    ];
    for (final p in buildPhrases) {
      if (t.contains(p)) return SessionResponseIntent.buildShortcut;
    }

    const affirm = [
      'yes',
      'yeah',
      'yep',
      'yup',
      'sure',
      'ok',
      'okay',
      'cool',
      'perfect',
      'correct',
      'right',
      'exactly',
      'proceed',
      'please',
    ];
    const affirmPhrases = [
      'sounds good',
      'go ahead',
      'do it',
      'please do',
      'yes please',
      'that is right',
      "that's right",
      'looks good',
    ];
    for (final p in affirmPhrases) {
      if (t.contains(p)) return SessionResponseIntent.affirm;
    }
    for (final w in affirm) {
      if (hasWord(w) || t.startsWith('$w '))
        return SessionResponseIntent.affirm;
    }

    const amend = [
      'change',
      'amend',
      'actually',
      'instead',
      'rather',
      'edit',
      'update',
      'modify',
      'fix',
      'different',
      'no wait',
      'not quite',
      'wrong',
    ];
    for (final w in amend) {
      if (hasWord(w) || t.contains(w)) return SessionResponseIntent.amend;
    }

    const deny = ['nope', 'incorrect'];
    for (final w in deny) {
      if (hasWord(w) && !t.contains('know')) return SessionResponseIntent.deny;
    }
    if (t == 'no' || t.startsWith('no ')) return SessionResponseIntent.deny;

    const cancel = ['cancel', 'abort', 'quit'];
    for (final w in cancel) {
      if (hasWord(w)) return SessionResponseIntent.cancel;
    }
    if (t.contains('never mind') || t.contains('forget it')) {
      return SessionResponseIntent.cancel;
    }

    return SessionResponseIntent.other;
  }

  String summarize() {
    if (_kind == SessionKind.author) {
      if (_phase == SessionPhase.review || _appSpec.allRelevantConfirmed) {
        return _appSpec.consolidationSummary();
      }
      if (!_appSpec.purpose.hasValue) {
        return AuthorPrompts.slotQuestion(AppSpecSlot.purpose);
      }
      return _appSpec.consolidationSummary();
    }

    if (_kind == SessionKind.refine) {
      final target = _refineTarget ?? 'the agent';
      final parts = <String>['Refining $target.'];
      if (_refineIssue != null && _refineIssue!.trim().isNotEmpty) {
        parts.add('Requested change: $_refineIssue.');
      }
      if (_pendingPatchDescription != null) {
        parts.add('Prepared patch: $_pendingPatchDescription.');
      }
      parts.add(AuthorPrompts.refineProceedHint);
      return parts.join(' ');
    }

    return '';
  }

  void startAuthor({AppSpec? initialSpec}) {
    _kind = SessionKind.author;
    _phase = SessionPhase.eliciting;
    _appSpec = initialSpec ?? AppSpec();
    _lastEchoedSlots = [];
    _lastScan = null;
    _authoringTurns.clear();
    _authorProvider = null;
    _authorModelId = null;
    _clearRefine();
    notifyListeners();
    debugPrint('[ConversationalSession] Started AUTHOR session');
  }

  void startRefine(String agentName, {String? initialPayload}) {
    _kind = SessionKind.refine;
    _phase = SessionPhase.eliciting;
    _refineTarget = agentName;
    _refineIssue = initialPayload?.trim().isNotEmpty == true
        ? initialPayload!.trim()
        : null;
    _appSpec = AppSpec();
    _lastEchoedSlots = [];
    _pendingPatchDescription = null;
    notifyListeners();
    debugPrint('[ConversationalSession] Started REFINE session for $agentName');
  }

  void applyAppSpec(AppSpec spec) {
    _appSpec = spec;
    notifyListeners();
  }

  void mergeAppSpec(AppSpec incoming) {
    _appSpec.mergeFrom(incoming);
    notifyListeners();
  }

  /// Back-compat.
  void applyAuthorSpec(AuthoringSpec spec) {
    _appSpec = spec.asAppSpec;
    notifyListeners();
  }

  /// Implicit consent: confirm slots echoed on the previous turn unless user objected.
  void applyImplicitConsent({
    required SessionResponseIntent localIntent,
    String? objectedField,
  }) {
    if (_lastEchoedSlots.isEmpty) return;
    final objected =
        localIntent == SessionResponseIntent.amend ||
        localIntent == SessionResponseIntent.deny;
    if (objected) {
      if (objectedField != null) {
        final slot = _slotFromFieldName(objectedField);
        if (slot != null) _appSpec.reopenSlot(slot);
      }
      return;
    }
    if (localIntent == SessionResponseIntent.cancel ||
        localIntent == SessionResponseIntent.buildShortcut) {
      return;
    }
    _appSpec.confirmEchoedSlots(_lastEchoedSlots);
    _lastEchoedSlots = [];
    notifyListeners();
  }

  AppSpecSlot? _slotFromFieldName(String raw) {
    final key = raw.trim().toLowerCase();
    for (final slot in AppSpecSlot.values) {
      if (slot.name.toLowerCase() == key) return slot;
    }
    const aliases = {
      'purpose': AppSpecSlot.purpose,
      'name': AppSpecSlot.name,
      'invocation': AppSpecSlot.invocationPrompt,
      'invocationprompt': AppSpecSlot.invocationPrompt,
      'trigger': AppSpecSlot.invocationPrompt,
      'parameters': AppSpecSlot.parameters,
      'behavior': AppSpecSlot.behaviorResponse,
      'response': AppSpecSlot.behaviorResponse,
      'datasources': AppSpecSlot.dataSources,
      'outputs': AppSpecSlot.outputs,
      'triggers': AppSpecSlot.triggersBeyondVoice,
      'sensors': AppSpecSlot.sensorsPermissions,
      'external': AppSpecSlot.externalIntegrations,
      'example': AppSpecSlot.exampleSuccess,
      'edgecases': AppSpecSlot.edgeCases,
    };
    return aliases[key];
  }

  void recordEchoedSlots(List<AppSpecSlot> slots) {
    _lastEchoedSlots = List.from(slots);
    notifyListeners();
  }

  bool get readyToAutoBuild =>
      _kind == SessionKind.author && _appSpec.allRelevantConfirmed;

  bool get isInReview =>
      _kind == SessionKind.author && _phase == SessionPhase.review;

  void enterReview() {
    _phase = SessionPhase.review;
    notifyListeners();
  }

  void exitReviewToEliciting() {
    if (_phase == SessionPhase.review) {
      _phase = SessionPhase.eliciting;
      notifyListeners();
    }
  }

  void enterCompiling() {
    _phase = SessionPhase.compiling;
    notifyListeners();
  }

  /// UI / voice path: set a slot value and mark confirmed.
  void updateSlotValue(AppSpecSlot slot, String value) {
    _appSpec.updateSlotValue(slot, value);
    if (_phase == SessionPhase.review && !_appSpec.allRelevantConfirmed) {
      _phase = SessionPhase.eliciting;
    }
    notifyListeners();
  }

  void setRefineVaultData({
    required String script,
    required Map<String, dynamic> schema,
    required String description,
  }) {
    _refineLoadedScript = script;
    _refineLoadedSchema = schema;
    _refineLoadedDescription = description;
    notifyListeners();
  }

  void setRefineIssue(String issue) {
    _refineIssue = issue;
    notifyListeners();
  }

  void setPendingPatchDescription(String description) {
    _pendingPatchDescription = description;
    notifyListeners();
  }

  /// Caches the generated refine draft so affirm applies without a second LLM call.
  void setPendingRefineDraft({
    required String script,
    required String description,
    required Map<String, dynamic> inputSchema,
    String? notes,
    Map<String, String> assetUpdates = const {},
  }) {
    _pendingPatchScript = script;
    _pendingPatchAgentDescription = description;
    _pendingPatchInputSchema = inputSchema;
    _pendingPatchDescription = notes ?? description;
    _pendingAssetUpdates = Map<String, String>.from(assetUpdates);
    notifyListeners();
  }

  void cancel() {
    _kind = SessionKind.none;
    _phase = SessionPhase.eliciting;
    _appSpec = AppSpec();
    _lastEchoedSlots = [];
    _lastScan = null;
    _clearRefine();
    notifyListeners();
    debugPrint('[ConversationalSession] Session cancelled');
  }

  void complete() {
    _kind = SessionKind.none;
    _phase = SessionPhase.eliciting;
    _appSpec = AppSpec();
    _lastEchoedSlots = [];
    _lastScan = null;
    _clearRefine();
    notifyListeners();
    debugPrint('[ConversationalSession] Session completed');
  }

  void _clearRefine() {
    _refineTarget = null;
    _refineIssue = null;
    _refineLoadedScript = null;
    _refineLoadedSchema = null;
    _refineLoadedDescription = null;
    _pendingPatchDescription = null;
    _pendingPatchScript = null;
    _pendingPatchAgentDescription = null;
    _pendingPatchInputSchema = null;
    _pendingAssetUpdates = const {};
  }

  static bool isProceedCommand(String text) =>
      classifyResponseLocal(text) == SessionResponseIntent.affirm ||
      classifyResponseLocal(text) == SessionResponseIntent.buildShortcut;

  static bool isCancelCommand(String text) =>
      classifyResponseLocal(text) == SessionResponseIntent.cancel;
}

final conversationalSessionProvider =
    ChangeNotifierProvider<ConversationalSessionService>((ref) {
      return ConversationalSessionService();
    });

/// Lightweight scan result held on the session for the authoring panel.
class DueDiligenceSnapshot {
  final bool passed;
  final List<String> findings;

  const DueDiligenceSnapshot({required this.passed, this.findings = const []});
}
