import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:audio_session/audio_session.dart' hide AndroidAudioFocus;
import 'package:audioplayers/audioplayers.dart' hide AVAudioSessionCategory;
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../agents/agent_base.dart';
import '../agents/js_agent_adapter.dart';
import '../config/app_config.dart';
import '../config/wake_handshake_config.dart';
import 'llm_service.dart';
import 'agent_service.dart';
import 'byok_service.dart';
import 'call_busy_guard.dart';
import 'default_mere_bhai.dart';
import 'llm/llm_slot.dart';
import 'author_prompts.dart';
import 'app_spec.dart';
import 'conversational_session_service.dart';
import 'agent_verification_service.dart';
import 'js_agent_registry.dart';
import 'agent_feed_service.dart';
import 'model_studio/bro_code_ml_meta.dart';
import 'telemetry_bus.dart';
import 'bro_call_service.dart';
import '../pipeline/authoring_trace.dart';
import '../pipeline/bro_code_coding_agent.dart';
import '../pipeline/bro_code_workspace.dart';

enum VoiceState { idle, listening, processing, awaitingHandshake }

class LogEntry {
  final DateTime timestamp;
  final String title;
  final String message;
  final bool isError;
  LogEntry(this.title, this.message, {this.isError = false})
    : timestamp = DateTime.now();
}

class VoiceHandshakeEngine extends ChangeNotifier {
  final Ref _ref;
  VoiceState _state = VoiceState.idle;

  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioRecorder _audioRecorder = AudioRecorder();

  Timer? _handshakeTimer;

  VoidCallback? onFlashGlanceTriggered;
  VoidCallback? onWakeWordDetected;

  bool isMicListening = false;
  String lastTranscribedWords = "";
  String micStatusMessage = "Ready";
  String audioSource = "Default";

  bool isHoldToTalk = false;
  bool _stopHoldRequested = false;

  static const int _holdToTalkMaxSeconds = 120;

  final List<LogEntry> sessionLogs = [];

  void _addLog(String title, String message, {bool isError = false}) {
    sessionLogs.insert(0, LogEntry(title, message, isError: isError));
    if (sessionLogs.length > 30) sessionLogs.removeLast();
    notifyListeners();
  }

  Future<String> _runAgent(
    AurBhaiAgent agent,
    Map<String, dynamic> params,
  ) async {
    if (agent is JsAgentAdapter) {
      _addLog(
        'Javascript Agent',
        'Executing Javascript Agent: ${agent.name}...',
      );
      agent.bridgeLogSink = (step) => _addLog('JS Bridge', step);
    }

    final result = await agent.execute(params);

    if (agent is JsAgentAdapter) {
      agent.bridgeLogSink = null;
    }
    return result;
  }

  bool _isCapabilitiesQuery(String text) {
    final t = text.toLowerCase();
    return t.contains('what can agent') ||
        t.contains('what do agent') ||
        t.contains('what agents can') ||
        t.contains('what can you build') ||
        t.contains('capabilities') ||
        t.contains('examples of agent') ||
        t.contains('help me build');
  }

  Future<bool> _tryAnswerCapabilities(String utterance) async {
    if (!_isCapabilitiesQuery(utterance)) return false;
    try {
      final llm = _ref.read(llmServiceProvider);
      final answer = await llm.describeCapabilities();
      _addLog('Capabilities', answer);
      notifyListeners();
      await speak(answer);
      return true;
    } catch (e) {
      _addLog('Capabilities', AuthorPrompts.capabilitiesBlurb);
      await speak(AuthorPrompts.capabilitiesBlurb);
      return true;
    }
  }

  bool _isSessionRecapQuery(String text) {
    final t = text.toLowerCase();
    return t.contains('iterate') ||
        t.contains('summar') ||
        t.contains('recap') ||
        t.contains('consolidat') ||
        t.contains('what have i') ||
        t.contains('what did i') ||
        t.contains('so far') ||
        t.contains('repeat what') ||
        (t.contains('mentioned') && t.contains('asked'));
  }

  ConversationalSessionService get _session =>
      _ref.read(conversationalSessionProvider);

  /// Deterministic safety net: catch authoring phrasing the LLM misclassified as direct.
  static bool looksLikeAuthorRequest(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return false;
    final hasCreateVerb = RegExp(
      r'\b(build|make|create|author|write|generate|craft)\b',
    ).hasMatch(t);
    final hasWantVerb = RegExp(
      r'\b(i want|i need|get me|give me|help me (build|make|create))\b',
    ).hasMatch(t);
    final hasNoun = RegExp(
      r'\b(agent|app|application|tool|dashboard|bot|plugin)\b',
    ).hasMatch(t);
    return (hasCreateVerb || hasWantVerb) && hasNoun;
  }

  /// Central verb-intent dispatch (Arch v3.7 single-call).
  Future<void> _dispatchTurn(TurnParsedResponse turn) async {
    var effectiveIntent = turn.intent;
    if (!_session.isActive &&
        effectiveIntent == AgentIntent.direct &&
        looksLikeAuthorRequest(turn.transcription)) {
      effectiveIntent = AgentIntent.author;
      _addLog(
        'Intent Override',
        'Reclassified DIRECT → AUTHOR (author-verb safety net).',
      );
    }

    final intentLabel = effectiveIntent.name.toUpperCase();
    final target = turn.targetAgent;
    _addLog('Intent', target != null ? '$intentLabel -> $target' : intentLabel);
    if (turn.reasoning != null && turn.reasoning!.isNotEmpty) {
      _addLog('LLM Reasoning', turn.reasoning!);
    }
    notifyListeners();

    if (_session.isActive && _session.kind == SessionKind.author) {
      await _handleAuthorTurn(turn);
      return;
    }

    if (_session.isActive && _session.kind == SessionKind.refine) {
      await _handleRefineTurn(turn);
      return;
    }

    switch (effectiveIntent) {
      case AgentIntent.execute:
        await _dispatchExecute(turn.toLegacy());
        break;
      case AgentIntent.author:
        await _beginAuthorSession(turn);
        break;
      case AgentIntent.refine:
        await _beginRefineSession(
          turn.targetAgent,
          initialPayload: turn.payload,
        );
        break;
      case AgentIntent.feed:
        await _dispatchFeed(turn);
        break;
      case AgentIntent.direct:
        if (await _tryAnswerCapabilities(turn.transcription)) break;
        final reply = turn.directResponse ?? turn.confirmation;
        lastTranscribedWords = 'Direct response';
        _addLog('Direct Response', reply);
        notifyListeners();
        await speak(reply);
        break;
    }
  }

  Future<void> _dispatchFeed(TurnParsedResponse turn) async {
    final name = turn.targetAgent?.trim();
    final payload = (turn.payload?.trim().isNotEmpty ?? false)
        ? turn.payload!.trim()
        : turn.transcription.trim();
    if (name == null || name.isEmpty) {
      _addLog('Feed Intent', 'FEED had no target agent.', isError: true);
      await speak("I didn't catch which agent to tell.");
      return;
    }
    if (payload.isEmpty) {
      _addLog('Feed Intent', 'FEED had empty payload.', isError: true);
      await speak('What should I tell $name?');
      return;
    }

    try {
      final entry = await _ref
          .read(agentFeedServiceProvider)
          .push(agentName: name, text: payload, source: 'voice');
      lastTranscribedWords = 'Fed $name';
      _addLog(
        'Feed Intent',
        'Stored inbox entry ${entry.id} for $name: $payload',
      );
      notifyListeners();
      await speak('Got it. Told $name: $payload');
    } catch (e) {
      _addLog('Feed Intent', 'Failed: $e', isError: true);
      await speak("I couldn't save that for $name.");
    }
  }

  Future<void> _dispatchExecute(LlmParsedResponse response) async {
    final target = response.targetAgent;
    if (target == null) {
      _addLog(
        'Agent Error',
        'EXECUTE intent had no target agent.',
        isError: true,
      );
      await speak("I didn't catch which agent to use.");
      return;
    }

    final agentService = _ref.read(agentServiceProvider);
    final agent = agentService.findAgent(target);

    if (agent == null) {
      _addLog('Agent Error', 'Agent $target was not found.', isError: true);
      await speak('Agent $target was not found.');
      return;
    }

    if (agent is JsAgentAdapter && !agent.canExecute) {
      final msg =
          '${agent.name} is not verified yet (${agent.securityClass.id}). Promote it from the Agents page after due diligence before running.';
      lastTranscribedWords = 'Blocked ${agent.name}';
      _addLog('Execution Blocked', msg, isError: true);
      notifyListeners();
      await speak(msg);
      return;
    }

    final params = response.parameters ?? {};
    lastTranscribedWords = 'Executing ${agent.name}...';
    _addLog('Execution Started', 'Agent: ${agent.name}\nParams: $params');
    notifyListeners();

    final result = await _runAgent(agent, params);

    lastTranscribedWords = 'Executed ${agent.name}';
    _addLog('Execution Result', result);
    notifyListeners();

    await speak(result);
    onFlashGlanceTriggered?.call();
  }

  Future<void> _beginAuthorSession(TurnParsedResponse turn) async {
    lastTranscribedWords = 'Authoring session started';
    _addLog('Author Session', 'Arch v3.7: single-call elicitation started.');

    final initial = turn.spec ?? AppSpec();
    _session.startAuthor(initialSpec: initial);
    final authorCfg = _ref
        .read(byokServiceProvider)
        .configForSlot(LlmSlot.author);
    _session.setAuthorModel(
      provider: authorCfg.provider,
      modelId: authorCfg.modelName,
    );
    final kickoff = turn.transcription.trim();
    if (kickoff.isNotEmpty) {
      _session.appendAuthoringTurn(
        role: 'user',
        text: kickoff,
        phase: 'eliciting',
      );
    }
    if (turn.spec != null) {
      _session.mergeAppSpec(turn.spec!);
      _addLog('Author Spec', _session.appSpec.toAuthorRequest());
    }

    if (_session.readyToAutoBuild || turn.readyToBuild) {
      await _enterAuthorReview();
      return;
    }

    final justUpdated = _snapshotFilledSlots(_session.appSpec).toList();
    await _continueAuthorAfterTurn(turn, justUpdatedSlots: justUpdated);
  }

  Future<void> _handleAuthorTurn(TurnParsedResponse turn) async {
    final localIntent = ConversationalSessionService.classifyResponseLocal(
      turn.transcription,
    );
    final uttered = turn.transcription.trim();
    if (uttered.isNotEmpty) {
      _session.appendAuthoringTurn(
        role: 'user',
        text: uttered,
        phase: _session.phase.name,
      );
    }

    if (localIntent == SessionResponseIntent.cancel) {
      _session.cancel();
      _addLog('Session', 'Cancelled by user.');
      await speak(AuthorPrompts.sessionCancelled);
      notifyListeners();
      return;
    }

    // Explicit build during review phase (or build shortcut anytime).
    if (_session.isInReview ||
        localIntent == SessionResponseIntent.buildShortcut) {
      if (localIntent == SessionResponseIntent.buildShortcut ||
          localIntent == SessionResponseIntent.affirm) {
        await buildFromReview();
        return;
      }
      // User amended something while in review — fall through to merge + continue.
      if (_session.phase == SessionPhase.review &&
          (localIntent == SessionResponseIntent.amend ||
              localIntent == SessionResponseIntent.deny ||
              turn.userObjected)) {
        _session.exitReviewToEliciting();
      } else if (_session.isInReview) {
        // Still in review; re-speak the recap + build hint.
        final recap = _session.appSpec.capturedSlotsRecap();
        final spoken = '$recap ${AuthorPrompts.reviewBuildHint}';
        _addLog('Author Review', spoken);
        notifyListeners();
        await speak(spoken);
        return;
      }
    }

    if (turn.userObjected && turn.objectedField != null) {
      _session.applyImplicitConsent(
        localIntent: SessionResponseIntent.amend,
        objectedField: turn.objectedField,
      );
    } else {
      _session.applyImplicitConsent(localIntent: localIntent);
    }

    // Track which slots already had values before this merge (for concise echo).
    final beforeKeys = _snapshotFilledSlots(_session.appSpec);

    if (turn.spec != null) {
      _session.mergeAppSpec(turn.spec!);
      _addLog('Author Spec', _session.appSpec.toAuthorRequest());
    }

    final afterKeys = _snapshotFilledSlots(_session.appSpec);
    final justUpdated = afterKeys.difference(beforeKeys).toList();
    // Also include slots whose value changed among previously filled ones.
    for (final slot in AppSpecSlot.values) {
      if (slot == AppSpecSlot.parameters ||
          slot == AppSpecSlot.externalIntegrations) {
        continue;
      }
      if (beforeKeys.contains(slot) &&
          turn.spec != null &&
          turn.spec!.fieldFor(slot).hasValue) {
        if (!justUpdated.contains(slot)) justUpdated.add(slot);
      }
    }

    if (_session.readyToAutoBuild || turn.readyToBuild) {
      await _enterAuthorReview();
      return;
    }

    await _continueAuthorAfterTurn(turn, justUpdatedSlots: justUpdated);
  }

  Set<AppSpecSlot> _snapshotFilledSlots(AppSpec spec) {
    final filled = <AppSpecSlot>{};
    for (final slot in AppSpecSlot.values) {
      if (slot == AppSpecSlot.parameters) {
        if (spec.parameters.isNotEmpty) filled.add(slot);
      } else if (slot == AppSpecSlot.externalIntegrations) {
        if (spec.externalIntegrations.isNotEmpty) filled.add(slot);
      } else if (spec.fieldFor(slot).hasValue) {
        filled.add(slot);
      }
    }
    return filled;
  }

  Future<void> _continueAuthorAfterTurn(
    TurnParsedResponse turn, {
    List<AppSpecSlot> justUpdatedSlots = const [],
  }) async {
    if (_session.readyToAutoBuild || turn.readyToBuild) {
      await _enterAuthorReview();
      return;
    }

    final nextSlot = _session.appSpec.nextOpenSlot();
    final echoed = <AppSpecSlot>[];
    if (nextSlot != null) echoed.add(nextSlot);
    _session.recordEchoedSlots(echoed);

    final echo = justUpdatedSlots.isNotEmpty
        ? _session.appSpec.echoForSlots(justUpdatedSlots)
        : '';
    final question = nextSlot != null
        ? AuthorPrompts.slotQuestion(nextSlot)
        : '';
    final spoken = [echo, question].where((s) => s.isNotEmpty).join(' ');
    final fallback = spoken.isNotEmpty ? spoken : turn.confirmation;

    _addLog('Author Turn', fallback);
    notifyListeners();
    await speak(fallback);
  }

  /// Enter review phase — speak full recap once; do NOT write to vault.
  Future<void> _enterAuthorReview() async {
    final spec = _session.appSpec;
    if (!spec.purpose.hasValue || !spec.behaviorResponse.hasValue) {
      final next = spec.nextOpenSlot();
      final q = next != null
          ? AuthorPrompts.slotQuestion(next)
          : 'I still need a bit more detail before I can build the agent.';
      await speak(q);
      return;
    }

    _session.enterReview();
    final recap = spec.capturedSlotsRecap();
    final spoken = '$recap ${AuthorPrompts.reviewBuildHint}';
    _addLog('Author Review', spoken);
    notifyListeners();
    await speak(spoken);
  }

  /// Compile + due diligence + persist. Triggered by BUILD button or "build it".
  Future<void> buildFromReview() async {
    final spec = _session.appSpec;
    if (!spec.purpose.hasValue || !spec.behaviorResponse.hasValue) {
      final next = spec.nextOpenSlot();
      final q = next != null
          ? AuthorPrompts.slotQuestion(next)
          : 'I still need a bit more detail before I can build the agent.';
      await speak(q);
      return;
    }

    _session.enterCompiling();
    _addLog('Author Compile', 'Compiling spec via LLM...');
    notifyListeners();

    try {
      final llm = _ref.read(llmServiceProvider);
      final draft = await llm.authorAgent(spec.toAuthorRequest());
      final registryName = spec.normalizedRegistryName();
      final displayName = spec.name.value ?? draft.name;
      final registry = _ref.read(jsAgentRegistryProvider);

      var schemaParams = draft.toAgentParameters();
      final fromSpec = spec.toInputSchema();
      if (fromSpec.isNotEmpty) {
        schemaParams = fromSpec.map((key, value) {
          final field = value is Map ? value : <String, dynamic>{};
          return MapEntry(
            key,
            AgentParameter(
              type: field['type']?.toString() ?? 'string',
              description: field['description']?.toString() ?? '',
              required: field['required'] as bool? ?? true,
            ),
          );
        });
      }

      final verification = _ref.read(agentVerificationProvider);
      final scan = verification.scanScript(draft.script);
      _session.setLastScan(passed: scan.passed, findings: scan.findingMessages);
      final hasExternal = spec.externalIntegrations.isNotEmpty;
      _addLog(
        'Due Diligence',
        scan.passed
            ? hasExternal
                  ? 'Clean scan; external integrations require C2 promotion and platform keys in Settings.'
                  : 'Clean scan for $registryName.'
            : 'Flagged: ${scan.findingMessages.join(' ')}',
        isError: !scan.passed,
      );
      notifyListeners();

      // MS-MODEL-META-AGT1 — Path L slots when purpose implies classification.
      final purposeText = '${spec.purpose.value ?? ''} ${draft.description}'
          .toLowerCase();
      final wantsPathL = RegExp(
        r'classif|detect|pothole|label|sensor|accelerometer|ambient|train',
      ).hasMatch(purposeText);
      final mlMeta = wantsPathL
          ? const BroCodeMlMeta(
              usesModel: true,
              maturity: 'collecting',
              labelSchema: {
                'labels': ['positive', 'negative'],
              },
              capturePolicy: {'mode': 'ambient', 'fineWindowSeconds': 45},
              fineWindow: Duration(seconds: 45),
            )
          : null;

      await registry.saveAndRegisterAgent(
        name: registryName,
        description: spec.name.hasValue ? displayName : draft.description,
        inputSchema: schemaParams,
        script: draft.script,
        securityClass: AgentSecurityClass.c4Unverified,
        mlMeta: mlMeta,
      );
      if (mlMeta != null) {
        _addLog(
          'Model Studio',
          'Path L collecting mode proposed (usesModel) for $registryName.',
        );
      }

      // S15 — freeze authoring form interactions with this Bro Code.
      final trace = _session.buildAuthoringTrace(
        agentName: registryName,
        buildOutcome: 'built',
        appSpecAtBuild: spec.toJson(),
      );
      await _ref
          .read(telemetryBusProvider)
          .writeVaultData(
            AuthoringTrace.vaultKeyFor(registryName),
            trace.toJsonString(),
            mimeType: 'application/json',
          );
      _addLog(
        'Authoring Trace',
        'Frozen ${trace.turns.length} turn(s) for $registryName',
      );

      _session.complete();
      lastTranscribedWords = 'Agent $displayName created';
      notifyListeners();

      verification.requestPromotion(agentName: registryName, scan: scan);

      if (hasExternal) {
        await speak(
          'Agent $displayName is built at unverified tier. Due diligence ${scan.passed ? "passed" : "flagged concerns"}. It includes external posting — configure platform keys in Settings and promote to verified before it can post.',
        );
      } else if (scan.passed) {
        await speak(
          'Agent $displayName is built at unverified tier. Due diligence passed. You can promote it from the Agents page when ready.',
        );
      } else {
        await speak(
          'Agent $displayName is built, but due diligence flagged some concerns. Review the warning to promote.',
        );
      }
    } catch (e) {
      _addLog('Author Error', '$e', isError: true);
      await speak(AuthorPrompts.buildFailed);
    }
  }

  Future<void> _beginRefineSession(
    String? agentName, {
    String? initialPayload,
  }) async {
    if (agentName == null || agentName.trim().isEmpty) {
      _addLog('Refine Error', 'No target agent named.', isError: true);
      await speak('Which agent should I improve?');
      return;
    }

    final registry = _ref.read(jsAgentRegistryProvider);
    final bundle = await registry.readAgentBundle(agentName);
    if (bundle == null) {
      _addLog(
        'Refine Error',
        'Agent $agentName not found in vault.',
        isError: true,
      );
      await speak('I could not find agent $agentName in the vault.');
      return;
    }

    final schema = bundle['schema'] as Map<String, dynamic>? ?? {};
    _session.startRefine(agentName, initialPayload: initialPayload);
    _session.setRefineVaultData(
      script: bundle['script'] as String,
      schema: schema,
      description: bundle['description'] as String? ?? '',
    );

    lastTranscribedWords = 'Refining $agentName';
    _addLog('Refine Session', 'Loaded vault source for $agentName.');
    notifyListeners();

    if (initialPayload != null && initialPayload.trim().isNotEmpty) {
      _session.setRefineIssue(initialPayload.trim());
      await _proposeRefinePatch();
    } else {
      const q = "What's the issue, or what should I change?";
      _addLog('Refine Question', q);
      await speak(q);
    }
  }

  Future<void> _handleRefineTurn(TurnParsedResponse turn) async {
    final localIntent = ConversationalSessionService.classifyResponseLocal(
      turn.transcription,
    );

    if (localIntent == SessionResponseIntent.cancel) {
      _session.cancel();
      await speak(AuthorPrompts.sessionCancelled);
      notifyListeners();
      return;
    }

    if (localIntent == SessionResponseIntent.affirm &&
        _session.pendingPatchDescription != null) {
      await _finalizeRefine();
      return;
    }

    final issue = turn.payload ?? turn.transcription;
    if (issue.trim().isNotEmpty) {
      _session.setRefineIssue(issue.trim());
      await _proposeRefinePatch();
    } else {
      await speak(turn.confirmation);
    }
  }

  Future<void> _proposeRefinePatch() async {
    final target = _session.refineTarget;
    final issue = _session.refineIssue;
    final script = _session.refineLoadedScript;
    if (target == null || issue == null || script == null) return;

    _addLog('Coding Agent', 'Improving $target — live steps follow');
    notifyListeners();

    try {
      final registry = _ref.read(jsAgentRegistryProvider);
      final assets = await registry.readAgentAssets(target);
      final schema = _session.refineLoadedSchema?['inputSchema'];
      final workspace = BroCodeWorkspace(
        name: target,
        description: _session.refineLoadedDescription ?? '',
        inputSchema: schema is Map
            ? Map<String, dynamic>.from(schema)
            : <String, dynamic>{},
        script: script,
        assets: assets,
      );

      final result = await _ref
          .read(broCodeCodingAgentProvider)
          .improve(
            workspace: workspace,
            changeRequest: issue,
            lastRunError: (_session.lastScan?.findings.isNotEmpty ?? false)
                ? _session.lastScan!.findings.join('; ')
                : null,
            dueDiligenceFindings:
                _session.lastScan?.findings ?? const <String>[],
            onProgress: (msg) {
              _addLog('Agent', msg);
              notifyListeners();
            },
          );

      if (!result.verified || result.draft == null) {
        _addLog('Coding Agent', result.message, isError: true);
        notifyListeners();
        await speak(
          'The coding agent could not verify a fix yet. ${result.message} Try IMPROVE on the Bhai log page, or describe the change again.',
        );
        return;
      }

      final draft = result.draft!;
      _session.setPendingRefineDraft(
        script: draft.script,
        description: draft.description,
        inputSchema: draft.inputSchema,
        notes: draft.notes ?? issue,
        assetUpdates: draft.assetUpdates,
      );
      _addLog('Coding Agent', draft.notes ?? 'Verified draft ready.');
      notifyListeners();
      await speak(
        'I verified a fix in the sandbox. ${draft.notes ?? ''} ${AuthorPrompts.refineProceedHint}',
      );
    } catch (e) {
      _addLog('Coding Agent Error', '$e', isError: true);
      notifyListeners();
      await speak(
        'The coding agent hit an error. Please describe the change again.',
      );
    }
  }

  Future<void> _finalizeRefine() async {
    final target = _session.refineTarget;
    final cachedScript = _session.pendingPatchScript;
    if (target == null || cachedScript == null) {
      await speak(
        'I do not have a prepared patch yet. Describe the change first.',
      );
      return;
    }

    _session.enterCompiling();
    _addLog('Refine Apply', 'Applying cached patch to $target...');
    notifyListeners();

    try {
      final registry = _ref.read(jsAgentRegistryProvider);
      final inputSchema = _session.pendingPatchInputSchema;
      await registry.refineAndReregister(
        name: target,
        script: cachedScript,
        description: _session.pendingPatchAgentDescription,
        inputSchema: inputSchema?.map((key, value) {
          final field = value is Map ? value : <String, dynamic>{};
          return MapEntry(
            key,
            AgentParameter(
              type: field['type']?.toString() ?? 'string',
              description: field['description']?.toString() ?? '',
              required: field['required'] as bool? ?? true,
            ),
          );
        }),
        assetUpdates: _session.pendingAssetUpdates,
      );

      final verification = _ref.read(agentVerificationProvider);
      final scan = verification.scanScript(cachedScript);
      _addLog(
        'Due Diligence',
        scan.passed
            ? 'Clean scan after refine.'
            : 'Flagged after refine: ${scan.findingMessages.join(' ')}',
        isError: !scan.passed,
      );

      _session.complete();
      lastTranscribedWords = 'Refined $target';
      notifyListeners();

      verification.requestPromotion(
        agentName: target,
        scan: scan,
        isRefinement: true,
      );

      await speak(
        scan.passed
            ? '$target was updated. It is back at unverified tier until you promote it again.'
            : '$target was updated but flagged by due diligence. Review the warning before promoting.',
      );
    } catch (e) {
      _addLog('Refine Error', '$e', isError: true);
      await speak('Applying the patch failed. Try again or cancel.');
    }
  }

  VoiceHandshakeEngine(this._ref) {
    _initAudioSession();
    _initTts();
  }

  VoiceState get state => _state;

  Future<void> _initAudioSession() async {
    try {
      _audioSession = await AudioSession.instance;
      // Speech + BT-friendly; duck music during handshake turns.
      await _audioSession?.configure(
        AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.allowBluetooth |
              AVAudioSessionCategoryOptions.defaultToSpeaker,
          avAudioSessionMode: AVAudioSessionMode.spokenAudio,
          androidAudioAttributes: const AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            flags: AndroidAudioFlags.none,
            usage: AndroidAudioUsage.voiceCommunication,
          ),
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientMayDuck,
          // Duck must not become a hard pause — that was aborting mic turns.
          androidWillPauseWhenDucked: false,
        ),
      );

      _audioSession?.devicesChangedEventStream.listen((event) {
        _updateAudioSource();
      });
      _audioSession?.interruptionEventStream.listen((event) {
        if (!event.begin) return;
        // Duck / TTS / record focus handoffs look like LOSS to audio_session.
        // Ending the turn here was aborting our own mic (~300ms). Only bail on call.
        if (event.type == AudioInterruptionType.duck) return;
        if (_state != VoiceState.listening &&
            _state != VoiceState.processing) {
          return;
        }
        unawaited(() async {
          if (!await CallBusyGuard.isBusy()) return;
          if (_state != VoiceState.listening &&
              _state != VoiceState.processing) {
            return;
          }
          _addLog('Audio', 'Call busy — ending turn.', isError: true);
          await _audioRecorder.stop();
          await _endSpeechTurn();
          _fallbackToIdleSnooze();
        }());
      });
      _updateAudioSource();
    } catch (e) {
      debugPrint('[VoiceHandshake] AudioSession error: $e');
    }
  }

  Future<bool> _beginSpeechTurn() async {
    if (await CallBusyGuard.isBusy()) {
      _addLog('Busy', AppConfig.wakeCallBusyMessage, isError: true);
      micStatusMessage = AppConfig.wakeCallBusyMessage;
      notifyListeners();
      try {
        await speak(AppConfig.wakeCallBusyMessage);
      } catch (_) {}
      return false;
    }
    try {
      await _audioSession?.setActive(true);
    } catch (e) {
      debugPrint('[VoiceHandshake] setActive: $e');
    }
    return true;
  }

  Future<void> _endSpeechTurn() async {
    try {
      await _audioSession?.setActive(false);
    } catch (_) {}
  }

  AudioSession? _audioSession;

  Future<void> _updateAudioSource() async {
    if (_audioSession == null) return;
    try {
      final devices = await _audioSession!.getDevices();
      final outDevices = devices.where((d) => d.isOutput).toList();
      if (outDevices.isNotEmpty) {
        audioSource = outDevices.first.type.name;
        audioSource = audioSource[0].toUpperCase() + audioSource.substring(1);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[VoiceHandshake] Audio route error: $e');
    }
  }

  Future<void> setTtsGender(String gender) async {
    try {
      final wantFemale = gender.toLowerCase().trim() == 'female';
      final voices = await _tts.getVoices;
      Map<String, String>? picked;

      bool isFemaleName(String name) {
        final n = name.toLowerCase();
        // Whole-token / labeled female — never match via substring of "male".
        return RegExp(r'(^|[^a-z])female([^a-z]|$)').hasMatch(n) ||
            n.contains('woman') ||
            n.contains('girl');
      }

      bool isMaleName(String name) {
        final n = name.toLowerCase();
        if (isFemaleName(n)) return false;
        return RegExp(r'(^|[^a-z])male([^a-z]|$)').hasMatch(n) ||
            (n.contains('man') && !n.contains('woman')) ||
            n.contains('boy');
      }

      for (final voice in voices) {
        if (voice is! Map) continue;
        final map = Map<String, String>.from(
          voice.map((k, v) => MapEntry(k.toString(), v.toString())),
        );
        final locale = map['locale'] ?? '';
        if (!locale.toLowerCase().contains('en')) continue;
        final name = map['name'] ?? '';
        final genderField = (map['gender'] ?? '').toLowerCase();

        final female =
            genderField.contains('female') ||
            genderField == 'f' ||
            isFemaleName(name);
        final male =
            (genderField.contains('male') && !genderField.contains('female')) ||
            genderField == 'm' ||
            isMaleName(name);

        if (wantFemale && female) {
          picked = map;
          break;
        }
        if (!wantFemale && male) {
          picked = map;
          break;
        }
      }

      if (picked != null) {
        await _tts.setVoice({
          'name': picked['name']!,
          'locale': picked['locale']!,
        });
        // Slight pitch bias as a soft cue when the engine still ignores gender.
        await _tts.setPitch(wantFemale ? 1.05 : 0.9);
        debugPrint(
          '[VoiceHandshake] TTS voice → ${picked['name']} (${wantFemale ? "female" : "male"})',
        );
      } else {
        // No gendered label on this device — pitch-only fallback.
        await _tts.setPitch(wantFemale ? 1.15 : 0.85);
        debugPrint(
          '[VoiceHandshake] No gendered TTS voice for "$gender"; using pitch fallback',
        );
      }
    } catch (e) {
      debugPrint('[VoiceHandshake] TTS setGender error: $e');
    }
  }

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage('en-IN');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      _tts.awaitSpeakCompletion(true);
      await setTtsGender("Male");
    } catch (e) {
      debugPrint('[VoiceHandshake] TTS Init error: $e');
    }
  }

  /// Called when a speech turn returns to idle (e.g. restart wake listen).
  VoidCallback? onReturnedToIdle;

  /// Wake must drop SCO before ack/TTS media playback (avoids reclaim race).
  Future<void> Function()? onLoudPlaybackStarting;

  /// After TTS/ack, resume wake if still idle (late playback can abort reclaim).
  VoidCallback? onLoudPlaybackFinished;

  void resumeAmbientListening() {
    micStatusMessage = "Tap for Haan Bhai · Hold to speak";
    notifyListeners();
  }

  void updateState(VoiceState newState) {
    final wasIdle = _state == VoiceState.idle;
    _state = newState;
    notifyListeners();
    if (newState == VoiceState.idle) {
      resumeAmbientListening();
      if (!wasIdle) onReturnedToIdle?.call();
    }
  }

  /// Leave Bluetooth SCO / call-mode so acks & TTS use A2DP media volume
  /// (media slider). Wake listen forces MODE_IN_COMMUNICATION + SCO, which
  /// routes playback to the quieter in-call stream even when media is maxed.
  Future<void> _prepareLoudPlayback() async {
    try {
      await onLoudPlaybackStarting?.call();
    } catch (_) {}
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final am = AndroidAudioManager();
        try {
          await am.clearCommunicationDevice();
        } catch (_) {}
        try {
          await am.stopBluetoothSco();
        } catch (_) {}
        try {
          await am.setBluetoothScoOn(false);
        } catch (_) {}
        try {
          await am.setMode(AndroidAudioHardwareMode.normal);
        } catch (_) {}
      }
      await _audioSession?.configure(
        AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.allowBluetoothA2dp,
          avAudioSessionMode: AVAudioSessionMode.spokenAudio,
          androidAudioAttributes: const AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            usage: AndroidAudioUsage.media,
          ),
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientMayDuck,
          androidWillPauseWhenDucked: false,
        ),
      );
      await _audioSession?.setActive(true);
      await _audioPlayer.setVolume(1.0);
      await _audioPlayer.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            isSpeakerphoneOn: false,
            audioMode: AndroidAudioMode.normal,
            stayAwake: true,
            contentType: AndroidContentType.speech,
            usageType: AndroidUsageType.media,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[VoiceHandshake] prepareLoudPlayback: $e');
    }
  }

  Future<void> speak(String text) async {
    if (_session.isActive && _session.kind == SessionKind.author) {
      _session.appendAuthoringTurn(
        role: 'assistant',
        text: text,
        phase: _session.phase.name,
      );
    }
    try {
      await _prepareLoudPlayback();
      // Re-apply Settings gender on every utterance (wake, errors, replies).
      final gender = _ref.read(byokServiceProvider).voiceGender;
      await setTtsGender(gender);
      await _tts.setVolume(1.0);
      await _tts.speak(text);
    } catch (e) {
      debugPrint('[VoiceHandshake TTS Error] $e');
    } finally {
      if (_state == VoiceState.idle) {
        onLoudPlaybackFinished?.call();
      }
    }
  }

  /// Tap / wake ack (Spoken / Sound / Silent). Never used for hold.
  Future<void> playCustomResponseOrFallback() async {
    final byok = _ref.read(byokServiceProvider);
    final mode = byok.tapResponseMode;
    if (mode == WakeHandshakeConfig.tapSilent) return;

    await _prepareLoudPlayback();

    if (mode == WakeHandshakeConfig.tapSound) {
      await SystemSound.play(SystemSoundType.click);
      return;
    }

    final word = byok.responseWord.trim().isEmpty
        ? "Haan bhai"
        : byok.responseWord.trim();
    try {
      await speak(word);
    } catch (e) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/custom_response.m4a');
        if (await file.exists()) {
          await _audioPlayer.play(DeviceFileSource(file.path));
        }
      } catch (_) {}
    }
  }

  /// Hold ack: Haptic / Beep / Silent — never spoken Response Word.
  Future<void> playHoldAck() async {
    final mode = _ref.read(byokServiceProvider).holdResponseMode;
    switch (mode) {
      case WakeHandshakeConfig.holdSilent:
        return;
      case WakeHandshakeConfig.holdBeep:
        await SystemSound.play(SystemSoundType.click);
        return;
      case WakeHandshakeConfig.holdHaptic:
      default:
        await HapticFeedback.mediumImpact();
    }
  }

  DateTime? _listeningStartedAt;

  Future<void> onMicSingleTap() async {
    if (_state == VoiceState.idle || _state == VoiceState.awaitingHandshake) {
      if (!await _beginSpeechTurn()) return;
      _handshakeTimer?.cancel();
      updateState(VoiceState.listening);
      _listeningStartedAt = DateTime.now();

      _addLog("Wake Word", "Triggered via tap / wake / headset short.");
      await playCustomResponseOrFallback();
      if (_ref.read(byokServiceProvider).vibrateOnWake) {
        await HapticFeedback.lightImpact();
      }

      onFlashGlanceTriggered?.call();
      _startAudioCommandRecording();
    } else if (_state == VoiceState.listening) {
      final started = _listeningStartedAt;
      final ms = started == null
          ? 9999
          : DateTime.now().difference(started).inMilliseconds;
      // Ignore bounce from MediaSession onPlay + UI tap within the same press.
      if (ms < 800) return;
      _addLog("Recording", "Ended early by user tap.");
      await _audioRecorder.stop();
    }
  }

  Future<void> onMicDoubleTap() async {
    if (_state == VoiceState.listening) {
      _addLog("Recording", "Cancelled by user double tap.", isError: true);
      await _audioRecorder.cancel();
      await _endSpeechTurn();
      _fallbackToIdleSnooze();
    }
  }

  Future<void> onMicHoldStart() async {
    if (_state != VoiceState.idle && _state != VoiceState.awaitingHandshake) {
      return;
    }
    if (!await _beginSpeechTurn()) return;
    _handshakeTimer?.cancel();
    isHoldToTalk = true;
    _stopHoldRequested = false;
    updateState(VoiceState.listening);

    _addLog("Wake Word", "Hold-to-talk engaged.");
    await playHoldAck();
    onFlashGlanceTriggered?.call();
    await _startHoldToTalkRecording();
  }

  Future<void> onMicHoldEnd() async {
    if (!isHoldToTalk) return;
    isHoldToTalk = false;
    if (_state == VoiceState.listening) {
      _addLog("Recording", "Hold released — processing.");
      _stopHoldRequested = true;
    }
  }

  Future<void> _startHoldToTalkRecording() async {
    if (!await _audioRecorder.hasPermission()) {
      micStatusMessage = "Mic permission denied for recording.";
      isHoldToTalk = false;
      _fallbackToIdleSnooze();
      return;
    }

    lastTranscribedWords = "";
    micStatusMessage = "Recording… release to send.";
    notifyListeners();

    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/current_command.m4a';

      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          numChannels: 1,
          sampleRate: 16000,
        ),
        path: path,
      );

      for (int i = 0; i < _holdToTalkMaxSeconds * 10; i++) {
        if (_stopHoldRequested) break;
        if (_state != VoiceState.listening ||
            !await _audioRecorder.isRecording()) {
          break;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }

      await _audioRecorder.stop();

      final file = File(path);
      if (await file.exists() && _state == VoiceState.listening) {
        _processAudioCommand(path);
      } else if (_state == VoiceState.listening) {
        await _endSpeechTurn();
        _fallbackToIdleSnooze();
      }
    } catch (e) {
      debugPrint('[VoiceHandshake] Hold record error: $e');
      isHoldToTalk = false;
      await _endSpeechTurn();
      _fallbackToIdleSnooze();
    }
  }

  Future<void> _startAudioCommandRecording() async {
    if (await _audioRecorder.hasPermission()) {
      lastTranscribedWords = "";
      micStatusMessage = "Recording command audio...";
      notifyListeners();

      try {
        final dir = await getApplicationDocumentsDirectory();
        final path = '${dir.path}/current_command.m4a';

        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.aacLc,
            numChannels: 1,
            sampleRate: 16000,
          ),
          path: path,
        );

        final byok = _ref.read(byokServiceProvider);
        final maxSeconds = byok.maxRecordingSeconds;

        bool stoppedEarly = false;
        for (int i = 0; i < maxSeconds * 10; i++) {
          if (_state != VoiceState.listening ||
              !await _audioRecorder.isRecording()) {
            stoppedEarly = true;
            break;
          }
          await Future.delayed(const Duration(milliseconds: 100));
        }

        if (!stoppedEarly) {
          await _audioRecorder.stop();
        }

        final file = File(path);
        if (await file.exists() && _state == VoiceState.listening) {
          _processAudioCommand(path);
        } else if (_state == VoiceState.listening) {
          _fallbackToIdleSnooze();
        }
      } catch (e) {
        debugPrint('[VoiceHandshake] Record error: $e');
        _fallbackToIdleSnooze();
      }
    } else {
      micStatusMessage = "Mic permission denied for recording.";
      _fallbackToIdleSnooze();
    }
  }

  Future<void> _processTurn(TurnParsedResponse turn) async {
    turn = _ref.read(defaultMereBhaiProvider).applyToTurn(turn);
    lastTranscribedWords = turn.transcription.isNotEmpty
        ? turn.transcription
        : 'Processed command';
    _addLog('Transcription', lastTranscribedWords);

    // S17 — pending Bro Call ack (Haan Bhai) takes priority.
    final calls = _ref.read(broCallServiceProvider);
    if (calls.nextPending != null && calls.looksLikeAck(turn.transcription)) {
      final delivered = await calls.acknowledgeAndDeliver();
      if (delivered != null) {
        _addLog(
          'Bro Call',
          'Delivered ${delivered.id} from ${delivered.agentName}',
        );
        lastTranscribedWords = 'Bro Call: ${delivered.title}';
        // Payload spoken via BroCallService.onDeliverPayload; ensure TTS if unset.
        if (calls.onDeliverPayload == null) {
          await speak(
            delivered.speakText.isEmpty ? delivered.body : delivered.speakText,
          );
        }
        return;
      }
    }

    if (_isSessionRecapQuery(turn.transcription) && _session.isActive) {
      final recap = _session.summarize();
      _addLog('Session Recap', recap);
      await speak(recap);
      return;
    }

    if (await _tryAnswerCapabilities(turn.transcription)) return;

    await _dispatchTurn(turn);
  }

  void _processAudioCommand(String audioPath) async {
    if (_state != VoiceState.listening) return;
    updateState(VoiceState.processing);

    micStatusMessage = "Sending audio to LLM...";
    _addLog("Audio Recorded", "Single-call parseTurn (Arch v3.7)...");
    notifyListeners();

    try {
      final llmService = _ref.read(llmServiceProvider);
      final turn = await llmService.parseTurn(
        audioFilePath: audioPath,
        existingSpec: _session.isActive ? _session.appSpec : null,
        authorSessionActive:
            _session.isActive && _session.kind == SessionKind.author,
      );

      await _processTurn(turn);
    } finally {
      await _endSpeechTurn();
      updateState(VoiceState.idle);
    }
  }

  Future<void> processVoiceCommand(String command) async {
    if (command.trim().isEmpty) return;
    if (!await _beginSpeechTurn()) return;
    updateState(VoiceState.processing);

    try {
      final llmService = _ref.read(llmServiceProvider);
      final turn = await llmService.parseTurn(
        text: command.trim(),
        existingSpec: _session.isActive ? _session.appSpec : null,
        authorSessionActive:
            _session.isActive && _session.kind == SessionKind.author,
      );

      await _processTurn(turn);
    } finally {
      await _endSpeechTurn();
      updateState(VoiceState.idle);
    }
  }

  Future<void> triggerPluginAlert(String alertMessage) async {
    _handshakeTimer?.cancel();
    await speak(alertMessage);
    updateState(VoiceState.awaitingHandshake);
    _handshakeTimer = Timer(const Duration(seconds: 5), () {
      _fallbackToIdleSnooze();
    });
  }

  void _fallbackToIdleSnooze() {
    updateState(VoiceState.idle);
    micStatusMessage = "Ready. Tap for Haan Bhai · Hold to speak";
    notifyListeners();
  }

  @override
  void dispose() {
    _handshakeTimer?.cancel();
    _tts.stop();
    _audioPlayer.dispose();
    _audioRecorder.dispose();
    super.dispose();
  }
}

final voiceHandshakeProvider = Provider<VoiceHandshakeEngine>((ref) {
  final engine = VoiceHandshakeEngine(ref);
  ref.onDispose(() => engine.dispose());
  return engine;
});
