import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'byok_service.dart';
import 'agent_service.dart';
import '../agents/agent_base.dart';
import 'llm/llm_provider.dart';
import 'llm/llm_provider_factory.dart';
import 'llm/llm_slot.dart';
import 'author_prompts.dart';
import 'agent_bridge_spec.dart';
import 'app_spec.dart';
import 'script_edits.dart';
import 'js_bridge_service.dart';

/// Extracts JS source from author/refine model JSON.
///
/// Prefers `scriptBase64` (avoids truncation of large sources inside JSON strings);
/// falls back to legacy `script`. Prefer thin execute + assets over nested HTML.
String scriptFromDraftJson(Map<String, dynamic> decoded) {
  final b64 = decoded['scriptBase64'] as String?;
  if (b64 != null && b64.trim().isNotEmpty) {
    final cleaned = b64.replaceAll(RegExp(r'\s+'), '');
    try {
      return utf8.decode(base64Decode(cleaned));
    } on FormatException catch (e) {
      throw FormatException('Invalid scriptBase64: ${e.message}');
    }
  }
  final script = decoded['script'] as String?;
  if (script != null && script.isNotEmpty) return script;
  throw Exception('Model did not return a script (expected scriptBase64 or script).');
}

/// User-facing message when patch JSON cannot be parsed.
String authoredJsonParseFailureMessage(Object error, {String? rawSnippet}) {
  final msg = error.toString();
  final detail = error is FormatException
      ? error.message
      : msg.replaceFirst(RegExp(r'^Exception:\s*'), '');
  final snippet = (rawSnippet != null && rawSnippet.trim().isNotEmpty)
      ? ' Raw: ${truncateForLog(rawSnippet)}'
      : '';
  if (error is FormatException ||
      msg.contains('FormatException') ||
      msg.toLowerCase().contains('unterminated string') ||
      msg.toLowerCase().contains('unexpected end') ||
      msg.toLowerCase().contains('unexpected character')) {
    return '${AgentBridgeSpec.invalidPatchJsonUserMessage} ($detail)$snippet';
  }
  return '$detail$snippet';
}

/// A reviewable draft produced by LLM agent authoring (MS-USER-ECOSYSTEM-ENG1).
class AuthoredAgentDraft {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final String script;
  final String? notes;

  /// Optional side assets after surgical edits (`asset id` → full content).
  final Map<String, String> assetUpdates;

  AuthoredAgentDraft({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.script,
    this.notes,
    this.assetUpdates = const {},
  });

  Map<String, AgentParameter> toAgentParameters() {
    return inputSchema.map((key, value) {
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
}

/// Verb-first intent the Core routes on (MS-CORE-INTENT).
enum AgentIntent {
  execute,
  feed,
  author,
  refine,
  direct,
}

AgentIntent _intentFromString(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'execute':
      return AgentIntent.execute;
    case 'feed':
      return AgentIntent.feed;
    case 'author':
      return AgentIntent.author;
    case 'refine':
      return AgentIntent.refine;
    default:
      return AgentIntent.direct;
  }
}

class ClarifyingQuestion {
  final String question;
  final String forField;
  final int priority;

  const ClarifyingQuestion({
    required this.question,
    required this.forField,
    this.priority = 1,
  });

  factory ClarifyingQuestion.fromJson(Map<String, dynamic> json) {
    return ClarifyingQuestion(
      question: (json['question'] as String?)?.trim() ?? '',
      forField: (json['forField'] as String?)?.trim() ?? '',
      priority: json['priority'] as int? ?? 1,
    );
  }
}

/// Single-call turn response (Arch v3.7).
class TurnParsedResponse {
  final AgentIntent intent;
  final String? targetAgent;
  final Map<String, dynamic>? parameters;
  final String? payload;
  final String transcription;
  final AppSpec? spec;
  final List<String> assumptions;
  final List<ClarifyingQuestion> clarifyingQuestions;
  final bool readyToBuild;
  final String confirmation;
  final String? directResponse;
  final String? reasoning;
  final bool userObjected;
  final String? objectedField;

  TurnParsedResponse({
    required this.intent,
    this.targetAgent,
    this.parameters,
    this.payload,
    required this.transcription,
    this.spec,
    this.assumptions = const [],
    this.clarifyingQuestions = const [],
    this.readyToBuild = false,
    required this.confirmation,
    this.directResponse,
    this.reasoning,
    this.userObjected = false,
    this.objectedField,
  });

  LlmParsedResponse toLegacy() => LlmParsedResponse(
        intent: intent,
        targetAgent: targetAgent,
        parameters: parameters,
        payload: payload,
        directResponse: directResponse,
        transcription: transcription,
        reasoning: reasoning,
      );

  factory TurnParsedResponse.fallback(String message) => TurnParsedResponse(
        intent: AgentIntent.direct,
        transcription: message,
        confirmation: message,
        directResponse: message,
      );
}

class LlmParsedResponse {
  final AgentIntent intent;
  final String? targetAgent;
  final Map<String, dynamic>? parameters;
  final String? payload;
  final String? directResponse;
  final String? transcription;
  final String? reasoning;

  LlmParsedResponse({
    required this.intent,
    this.targetAgent,
    this.parameters,
    this.payload,
    this.directResponse,
    this.transcription,
    this.reasoning,
  });

  bool get isPluginCommand => intent == AgentIntent.execute && targetAgent != null;
  String? get pluginName => targetAgent;

  factory LlmParsedResponse.fallback(String phrase) {
    return LlmParsedResponse(intent: AgentIntent.direct, directResponse: phrase);
  }
}

class LlmService {
  final Ref _ref;
  LlmService(this._ref);

  LlmProvider _provider({LlmSlot slot = LlmSlot.defaultSlot}) =>
      LlmProviderFactory.forConfig(
        _ref.read(byokServiceProvider),
        slot: slot,
      );

  Future<bool> generateAndSaveResponseAudio(
    String responseWord,
    String language,
    String gender,
  ) async {
    final byok = _ref.read(byokServiceProvider);

    if (!byok.hasKeyForSlot(LlmSlot.tts)) {
      debugPrint('No API key for TTS slot.');
      return false;
    }

    final provider = _provider(slot: LlmSlot.tts);
    debugPrint('[LlmService] TTS slot=${LlmSlot.tts.id} provider=${provider.id}');
    if (!provider.supportsTts) {
      debugPrint('TTS not natively supported for ${provider.id}.');
      return false;
    }

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final path = '${docsDir.path}/custom_response.m4a';
      final file = File(path);

      final voice = gender.toLowerCase() == 'female' ? 'nova' : 'onyx';
      final bytes = await provider.synthesizeSpeech(
        text: responseWord,
        voice: voice,
      );
      await file.writeAsBytes(bytes);
      return true;
    } catch (e) {
      debugPrint('TTS Gen Error: $e');
      return false;
    }
  }

  /// Arch v3.7 — single LLM call per turn (text path).
  Future<TurnParsedResponse> parseTurn({
    String? text,
    String? audioFilePath,
    AppSpec? existingSpec,
    bool authorSessionActive = false,
  }) async {
    final byok = _ref.read(byokServiceProvider);
    final slot =
        audioFilePath != null ? LlmSlot.language : LlmSlot.intent;

    if (!byok.hasKeyForSlot(slot)) {
      return TurnParsedResponse.fallback(
        'Please configure your API Key (${slot.label}) in Settings to enable AI.',
      );
    }

    final prompt = _buildTurnPrompt(
      existingSpec: existingSpec,
      authorSessionActive: authorSessionActive,
      isAudio: audioFilePath != null,
      userText: text,
    );

    try {
      final provider = _provider(slot: slot);
      debugPrint(
        '[LlmService parseTurn] slot=${slot.id} provider=${provider.id}',
      );
      String responseBody;

      if (audioFilePath != null) {
        final file = File(audioFilePath);
        if (!await file.exists()) {
          return TurnParsedResponse.fallback('Audio recording failed.');
        }
        if (!provider.supportsAudioInput) {
          return TurnParsedResponse.fallback(
            '${provider.id} does not support direct audio. Please use Gemini or OpenAI.',
          );
        }
        if (provider.prefersAudioDirect) {
          responseBody = await provider.completeWithAudio(
            prompt: prompt,
            audio: file,
            jsonMode: true,
            timeout: const Duration(seconds: 20),
          );
        } else {
          final transcript = await provider.transcribe(file);
          if (transcript.trim().isEmpty) {
            return TurnParsedResponse.fallback("I didn't hear anything.");
          }
          return parseTurn(
            text: transcript,
            existingSpec: existingSpec,
            authorSessionActive: authorSessionActive,
          );
        }
      } else {
        responseBody = await provider.complete(
          prompt: prompt,
          jsonMode: true,
          timeout: const Duration(seconds: 15),
        );
      }

      final decoded =
          jsonDecode(_cleanJsonString(responseBody)) as Map<String, dynamic>;
      return _turnFromDecoded(decoded);
    } catch (e) {
      debugPrint('[LlmService parseTurn] Error: $e');
      return TurnParsedResponse.fallback(
        'I had trouble communicating with the AI. Check connection and keys.',
      );
    }
  }

  /// Back-compat text parse — delegates to [parseTurn].
  Future<LlmParsedResponse> parsePrompt(String userPrompt) async {
    final turn = await parseTurn(text: userPrompt);
    return turn.toLegacy();
  }

  /// Back-compat audio parse — delegates to [parseTurn].
  Future<LlmParsedResponse> parseAudioPrompt(
    String audioFilePath, {
    AppSpec? existingSpec,
    bool authorSessionActive = false,
  }) async {
    final turn = await parseTurn(
      audioFilePath: audioFilePath,
      existingSpec: existingSpec,
      authorSessionActive: authorSessionActive,
    );
    return turn.toLegacy();
  }

  String _intentRouterPreamble() => '''
You are the central AI intent router for 'Project Aur Bhai', a Mobile Agentic OS.
Respond in English only.
Classify the user's utterance into EXACTLY ONE intent:
- "execute": user wants an existing registered agent to run. Cue: "Ask <agent> to ...", or a direct request matching a registered agent.
- "feed": user pushes runtime data into an agent. Cue: "Tell <agent> that ...".
- "author": user wants to CREATE a new agent/app/tool/dashboard/bot. Cue (treat ALL of these as author, even if details are sparse):
  "Build / Make / Create / Get me / I want / I need … an agent / app / tool / dashboard / bot",
  "Build me a telemetry dashboard", "I want to build an agent that…", "Make an app that…".
  Prefer "author" over "direct" whenever the user expresses intent to create software on this device.
- "refine": user wants to change an EXISTING agent. Cue: "Fix / Improve / Update <agent>".
- "direct": anything else (chit-chat, capability questions, silence).
If audio/prompt is empty or noise, use intent "direct" with confirmation "I didn't hear anything."''';

  String _appSpecTemplateInstructions() => '''
When intent is "author" OR an authoring session is active, fill the App Spec template.
Each scalar field uses: {"value": string|null, "status": "empty"|"proposed"|"confirmed", "confidence": "stated"|"inferred"|"unknown"}.
Slot sequence (ask next missing in order; skip conditional slots when irrelevant):
1. purpose — what outcome the user wants
2. name — suggest a short name (status proposed until user agrees)
3. invocationPrompt — exact phrase user will speak to run the agent
4. parameters — array of {name, type, description, exampleInPrompt} parsed from invocation phrase
5. behaviorResponse — what agent does + suggested spoken response (propose sample response)
6. dataSources — telemetry SQL via System.querySQL, vault, sensors, HTTP, feed inbox
7. outputs — spoken summary, HTML dashboard via System.writeVault, vault file, external post
8. triggersBeyondVoice — only if background/schedule/sensor implied
9. sensorsPermissions — only if GPS/accel/telemetry/sensors implied
10. externalKeys — only if external integrations need BYOK keys
11. exampleSuccess — "when I say X → reply Y"
12. edgeCases — offline/empty/error behavior (optional)
13. externalIntegrations — array of {platform, action, constraints, mediaType, requiresByokKey} when user wants Twitter/X, Facebook, Instagram, YouTube, Threads, or webhook posts. Note platform limits (e.g. 280 chars for X).

${AgentBridgeSpec.slotFillingHint}

Rules:
- Fill everything inferable; never block on unknowns.
- Merge with existing spec; do not overwrite confirmed slots unless user explicitly corrects.
- Set userObjected true if user disagrees with a proposed value; set objectedField to the slot name.
- confirmation: short English recap of consolidated spec + the single highest-priority next question. Never push "proceed" or rush the user.
- readyToBuild: true only when all relevant slots are filled and status confirmed or strongly stated.''';

  String _turnJsonContract() => '''
Respond ONLY in RAW JSON (no markdown fences):
{
  "transcription": "exact user text heard or typed",
  "intent": "execute" | "feed" | "author" | "refine" | "direct",
  "targetAgent": string or null,
  "parameters": object or null,
  "payload": string or null,
  "spec": {
    "purpose": {"value": null, "status": "empty", "confidence": "unknown"},
    "name": {"value": null, "status": "empty", "confidence": "unknown"},
    "invocationPrompt": {"value": null, "status": "empty", "confidence": "unknown"},
    "parameters": [],
    "behaviorResponse": {"value": null, "status": "empty", "confidence": "unknown"},
    "dataSources": {"value": null, "status": "empty", "confidence": "unknown"},
    "outputs": {"value": null, "status": "empty", "confidence": "unknown"},
    "triggersBeyondVoice": {"value": null, "status": "empty", "confidence": "unknown"},
    "sensorsPermissions": {"value": null, "status": "empty", "confidence": "unknown"},
    "externalKeys": {"value": null, "status": "empty", "confidence": "unknown"},
    "exampleSuccess": {"value": null, "status": "empty", "confidence": "unknown"},
    "edgeCases": {"value": null, "status": "empty", "confidence": "unknown"},
    "externalIntegrations": []
  },
  "assumptions": ["inferred X because..."],
  "clarifyingQuestions": [{"question": "...", "forField": "purpose", "priority": 1}],
  "readyToBuild": false,
  "confirmation": "spoken English recap + next question",
  "directResponse": string or null,
  "userObjected": false,
  "objectedField": string or null,
  "reasoning": string or null
}''';

  Map<String, dynamic> _buildAgentSchemas() {
    final agentService = _ref.read(agentServiceProvider);
    final Map<String, dynamic> agentSchemas = {};
    for (var a in agentService.agents) {
      final Map<String, dynamic> paramsJson = {};
      a.inputSchema.forEach((key, param) {
        paramsJson[key] = {
          'type': param.type,
          'description': param.description,
          'required': param.required,
        };
      });
      agentSchemas[a.name] = {
        'description': a.description,
        'parameters': paramsJson,
      };
    }
    return agentSchemas;
  }

  String _buildTurnPrompt({
    AppSpec? existingSpec,
    bool authorSessionActive = false,
    bool isAudio = false,
    String? userText,
  }) {
    final existingJson = existingSpec != null
        ? existingSpec.toJsonString()
        : '{}';
    final inputLine = isAudio
        ? 'Listen to the attached audio.'
        : 'User prompt: "${userText ?? ''}"';

    return '''
${_intentRouterPreamble()}

${_appSpecTemplateInstructions()}

Telemetry SQLite schema:
  telemetry(id TEXT, timestamp TEXT, latitude REAL, longitude REAL, accelerometerZ REAL, compassDirection REAL)

Active Ecosystem Agents:
${jsonEncode(_buildAgentSchemas())}

Authoring session active: $authorSessionActive
Current partial spec (merge, do not drop confirmed fields):
$existingJson

$inputLine

${_turnJsonContract()}
''';
  }

  TurnParsedResponse _turnFromDecoded(Map<String, dynamic> decoded) {
    AppSpec? spec;
    if (decoded['spec'] is Map) {
      spec = AppSpec.fromJson(
          Map<String, dynamic>.from(decoded['spec'] as Map));
    }

    final questions = <ClarifyingQuestion>[];
    if (decoded['clarifyingQuestions'] is List) {
      for (final q in decoded['clarifyingQuestions'] as List) {
        if (q is Map) {
          questions.add(
              ClarifyingQuestion.fromJson(Map<String, dynamic>.from(q)));
        }
      }
    }

    final assumptions = <String>[];
    if (decoded['assumptions'] is List) {
      for (final a in decoded['assumptions'] as List) {
        if (a is String && a.trim().isNotEmpty) assumptions.add(a.trim());
      }
    }

    final transcription = (decoded['transcription'] as String?)?.trim() ?? '';
    final confirmation = (decoded['confirmation'] as String?)?.trim();
    final directResponse = decoded['directResponse'] as String?;

    return TurnParsedResponse(
      intent: _intentFromString(decoded['intent'] as String?),
      targetAgent: decoded['targetAgent'] as String?,
      parameters: decoded['parameters'] != null
          ? Map<String, dynamic>.from(decoded['parameters'] as Map)
          : null,
      payload: decoded['payload'] as String?,
      transcription: transcription,
      spec: spec,
      assumptions: assumptions,
      clarifyingQuestions: questions,
      readyToBuild: decoded['readyToBuild'] as bool? ?? false,
      confirmation: confirmation?.isNotEmpty == true
          ? confirmation!
          : (directResponse ?? "I didn't quite catch that."),
      directResponse: directResponse,
      reasoning: decoded['reasoning'] as String?,
      userObjected: decoded['userObjected'] as bool? ?? false,
      objectedField: decoded['objectedField'] as String?,
    );
  }

  Future<AuthoredAgentDraft> authorAgent(String userRequest) async {
    final byok = _ref.read(byokServiceProvider);
    if (!byok.hasKeyForSlot(LlmSlot.author)) {
      throw Exception(
        'Configure your API Key (author slot or default) in Settings to author agents.',
      );
    }

    final systemPrompt = '''
You are the Agent Authoring compiler for 'Project Aur Bhai', a mobile agentic OS.
Respond in English only.
The user will describe an agent they want. You MUST output a single JavaScript agent.

${AgentBridgeSpec.bridgeSpecForLlm}

${AgentBridgeSpec.authorOutputTransport}

User request: "$userRequest"

Respond ONLY in RAW JSON (no markdown fences):
{
  "name": "PascalCaseAgentName",
  "description": "one sentence describing what the agent does",
  "inputSchema": { "paramName": { "type": "string|number|boolean", "description": "...", "required": true|false } },
  "scriptBase64": "BASE64 of the thin execute() javascript UTF-8 source",
  "assets": { "OptionalDashboard.html": "large HTML/PWA sources preferred as assets" },
  "notes": "one short sentence on how to invoke it"
}
''';

    final authorProvider = _provider(slot: LlmSlot.author);
    debugPrint(
      '[LlmService authorAgent] slot=${LlmSlot.author.id} '
      'provider=${authorProvider.id}',
    );
    final raw = await authorProvider.complete(
      prompt: systemPrompt,
      jsonMode: true,
      timeout: const Duration(seconds: 40),
      maxTokens: 12288,
    );
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(_cleanJsonString(raw)) as Map<String, dynamic>;
    } on FormatException catch (e) {
      throw Exception(authoredJsonParseFailureMessage(e));
    }

    final name = (decoded['name'] as String?)?.trim();
    if (name == null || name.isEmpty) {
      throw Exception('Model did not return a valid agent (missing name).');
    }
    final script = scriptFromDraftJson(decoded);

    return AuthoredAgentDraft(
      name: name,
      description: (decoded['description'] as String?)?.trim() ??
          'AI-authored agent.',
      inputSchema: decoded['inputSchema'] is Map
          ? Map<String, dynamic>.from(decoded['inputSchema'] as Map)
          : <String, dynamic>{},
      script: script,
      notes: decoded['notes'] as String?,
    );
  }

  Future<String> describeCapabilities() async {
    final byok = _ref.read(byokServiceProvider);
    if (!byok.hasKeyForSlot(LlmSlot.intent)) {
      return AuthorPrompts.capabilitiesBlurb;
    }

    const prompt = '''
Explain what sandboxed agents can do on Project Aur Bhai (mobile agentic OS).
Respond in English only.
Cover: read-only SQL telemetry queries, writing vault dashboards/files, local HTTP calls,
external platform posts when user configures keys, and spoken results.
Keep it to 2-3 short spoken sentences. No markdown.
Respond ONLY in RAW JSON: {"answer": "..."}
''';

    try {
      final raw = await _provider(slot: LlmSlot.intent).complete(
        prompt: prompt,
        jsonMode: true,
        timeout: const Duration(seconds: 10),
      );
      final decoded = jsonDecode(_cleanJsonString(raw)) as Map<String, dynamic>;
      final answer = (decoded['answer'] as String?)?.trim();
      if (answer != null && answer.isNotEmpty) return answer;
    } catch (_) {
      // fall through
    }
    return AuthorPrompts.capabilitiesBlurb;
  }

  Future<AuthoredAgentDraft> rewriteBroCodeScript({
    required String broCodeName,
    required String currentScript,
    required String changeRequest,
    String? currentDescription,
    Map<String, dynamic>? currentInputSchema,
    String? lastRunError,
    List<String> dueDiligenceFindings = const [],
    void Function(String message)? onProgress,
  }) async {
    final byok = _ref.read(byokServiceProvider);
    if (!byok.hasKeyForSlot(LlmSlot.improve)) {
      throw Exception(
        'Configure your API Key (improve slot or default) in Settings.',
      );
    }

    void progress(String message) => onProgress?.call(message);
    final bridge = _ref.read(jsBridgeServiceProvider);
    final schemaJson =
        currentInputSchema != null ? jsonEncode(currentInputSchema) : '{}';

    final contextBlocks = StringBuffer();
    if (lastRunError != null && lastRunError.trim().isNotEmpty) {
      contextBlocks.writeln('LAST RUN ERROR:\n$lastRunError\n');
    }
    if (dueDiligenceFindings.isNotEmpty) {
      contextBlocks.writeln(
        'DUE DILIGENCE FINDINGS (policy scan — does not execute):',
      );
      for (final f in dueDiligenceFindings) {
        contextBlocks.writeln('• $f');
      }
      contextBlocks.writeln();
    }

    progress('Coder Agent: refining Bro Code (prefer thin execute + assets)…');
    final improveProvider = _provider(slot: LlmSlot.improve);
    progress(
      'IMPROVE slot=${LlmSlot.improve.id} provider=${improveProvider.id}',
    );

    final prompt = '''
You are the Coder Agent for Project Aur Bhai.
Update the Bro Code (Javascript) to satisfy the change request.
Respond in English only. Prefer thin execute() + System.assets for HTML/PWA;
do NOT nest large dashboard HTML inside the JS template string.

Bro Code name: $broCodeName
Current description: ${currentDescription ?? 'n/a'}
Current input schema: $schemaJson

${AgentBridgeSpec.bridgeSpecForLlm}

${AgentBridgeSpec.refineOutputTransport}

$contextBlocks
CURRENT SCRIPT:
$currentScript

USER CHANGE REQUEST:
"$changeRequest"

Respond ONLY in RAW JSON: thin scriptBase64 and/or assets / edits — not HTML-in-JS monoliths.
''';

    Object? lastFailure;
    String? lastRaw;
    final messages = <LlmChatMessage>[
      LlmChatMessage(role: 'user', content: prompt),
    ];

    for (var turn = 1; turn <= kMaxRefineModelTurns; turn++) {
      progress('Coder Agent turn $turn/$kMaxRefineModelTurns…');
      String raw;
      try {
        raw = await improveProvider.completeChat(
          messages: messages,
          jsonMode: true,
          timeout: const Duration(seconds: 60),
          maxTokens: 12288,
        );
      } on TimeoutException {
        lastFailure = TimeoutException(
          'Coder Agent timed out. Tap Retry.',
          const Duration(seconds: 60),
        );
        break;
      }

      lastRaw = raw;
      progress('Received (${raw.length} chars)');
      messages.add(LlmChatMessage(role: 'model', content: raw));

      Map<String, dynamic> decoded;
      try {
        decoded = jsonDecode(_cleanJsonString(raw)) as Map<String, dynamic>;
      } on FormatException catch (e) {
        lastFailure = e;
        progress('Parse error: ${e.message}');
        if (turn >= kMaxRefineModelTurns) break;
        messages.add(LlmChatMessage(
          role: 'user',
          content:
              'Invalid JSON (${e.message}). Return ONLY valid JSON with thin scriptBase64 and/or assets.',
        ));
        continue;
      }

      late final String script;
      try {
        script = scriptFromDraftJson(decoded);
      } catch (e) {
        lastFailure = e;
        progress('Missing scriptBase64: $e');
        if (turn >= kMaxRefineModelTurns) break;
        messages.add(const LlmChatMessage(
          role: 'user',
          content:
              'Missing scriptBase64. Return thin execute() as scriptBase64; put large HTML in assets.',
        ));
        continue;
      }

      final syntax = bridge.validateScriptSyntax(script);
      if (!syntax.ok) {
        lastFailure = Exception(syntax.message ?? 'QuickJS syntax check failed');
        progress('Syntax check failed: ${syntax.message}');
        if (turn >= kMaxRefineModelTurns) break;
        messages.add(LlmChatMessage(
          role: 'user',
          content:
              'QuickJS rejected the script: ${syntax.message}. Return corrected scriptBase64.',
        ));
        continue;
      }

      progress('Coder Agent: QuickJS syntax OK');
      return AuthoredAgentDraft(
        name: broCodeName,
        description: (decoded['description'] as String?)?.trim() ??
            currentDescription ??
            'Refined Bro Code.',
        inputSchema: decoded['inputSchema'] is Map
            ? Map<String, dynamic>.from(decoded['inputSchema'] as Map)
            : currentInputSchema ?? <String, dynamic>{},
        script: script,
        notes: decoded['notes'] as String? ?? 'Full rewrite by Coder Agent.',
      );
    }

    throw Exception(
      authoredJsonParseFailureMessage(
        lastFailure ??
            Exception(
              'Coder Agent exhausted $kMaxRefineModelTurns turns. Tap Retry.',
            ),
        rawSnippet: lastRaw,
      ),
    );
  }

  /// @Deprecated Prefer [rewriteBroCodeScript] / [BroCodePipeline.refineAndTest].
  ///
  /// Kept for Improve UI fallback; tries Coder rewrite first, then surgical edits.
  Future<AuthoredAgentDraft> refineAgentScript({
    required String agentName,
    required String currentScript,
    required String changeRequest,
    String? currentDescription,
    Map<String, dynamic>? currentInputSchema,
    String? lastRunError,
    List<String> dueDiligenceFindings = const [],
    Map<String, String> currentAssets = const {},
    void Function(String message)? onProgress,
    List<LlmChatMessage>? chatSeed,
  }) async {
    void progress(String message) => onProgress?.call(message);

    // --- Local-first SyntaxError fix (no LLM) ---
    final bridge = _ref.read(jsBridgeServiceProvider);
    final localCandidates =
        localSyntaxFixCandidates(currentScript, lastRunError);
    if (localCandidates.isNotEmpty) {
      progress('Trying local SyntaxError fix…');
      for (final candidate in localCandidates) {
        final check = bridge.validateScriptSyntax(candidate.script);
        if (check.ok) {
          progress('Verified: QuickJS syntax OK (local fix)');
          return AuthoredAgentDraft(
            name: agentName,
            description: currentDescription ?? 'Refined Bro Code.',
            inputSchema: currentInputSchema ?? <String, dynamic>{},
            script: candidate.script,
            notes: candidate.notes,
          );
        }
      }
      progress('Local fix failed — Coder Agent…');
    }

    // Primary path: full rewrite (avoids brittle Base64 patches).
    try {
      return await rewriteBroCodeScript(
        broCodeName: agentName,
        currentScript: currentScript,
        changeRequest: changeRequest,
        currentDescription: currentDescription,
        currentInputSchema: currentInputSchema,
        lastRunError: lastRunError,
        dueDiligenceFindings: dueDiligenceFindings,
        onProgress: onProgress,
      );
    } catch (e) {
      progress('Coder rewrite failed ($e) — falling back to surgical edits…');
    }

    return _refineWithSurgicalEdits(
      agentName: agentName,
      currentScript: currentScript,
      changeRequest: changeRequest,
      currentDescription: currentDescription,
      currentInputSchema: currentInputSchema,
      lastRunError: lastRunError,
      dueDiligenceFindings: dueDiligenceFindings,
      currentAssets: currentAssets,
      onProgress: onProgress,
      chatSeed: chatSeed,
    );
  }

  Future<AuthoredAgentDraft> _refineWithSurgicalEdits({
    required String agentName,
    required String currentScript,
    required String changeRequest,
    String? currentDescription,
    Map<String, dynamic>? currentInputSchema,
    String? lastRunError,
    List<String> dueDiligenceFindings = const [],
    Map<String, String> currentAssets = const {},
    void Function(String message)? onProgress,
    List<LlmChatMessage>? chatSeed,
  }) async {
    final byok = _ref.read(byokServiceProvider);
    if (!byok.hasKeyForSlot(LlmSlot.improve)) {
      throw Exception(
        'Configure your API Key (improve slot or default) in Settings.',
      );
    }

    void progress(String message) => onProgress?.call(message);
    final bridge = _ref.read(jsBridgeServiceProvider);
    final improveProvider = _provider(slot: LlmSlot.improve);

    progress('Loaded vault script (${currentScript.length} chars)');
    progress(
      'IMPROVE slot=${LlmSlot.improve.id} provider=${improveProvider.id}',
    );

    final schemaJson = currentInputSchema != null
        ? jsonEncode(currentInputSchema)
        : '{}';

    final contextBlocks = StringBuffer();
    if (lastRunError != null && lastRunError.trim().isNotEmpty) {
      contextBlocks.writeln('LAST RUN ERROR:\n$lastRunError\n');
    }
    if (dueDiligenceFindings.isNotEmpty) {
      contextBlocks.writeln('DUE DILIGENCE FINDINGS (policy scan — does not execute):');
      for (final f in dueDiligenceFindings) {
        contextBlocks.writeln('• $f');
      }
      contextBlocks.writeln();
    }

    final assetsBlock = StringBuffer();
    if (currentAssets.isNotEmpty) {
      assetsBlock.writeln('RELATED ASSETS (edit with "asset": "<id>"):');
      currentAssets.forEach((id, content) {
        assetsBlock.writeln('--- asset:$id ---');
        assetsBlock.writeln(content);
        assetsBlock.writeln('--- end asset:$id ---');
      });
      assetsBlock.writeln();
    }

    final errorLoc = parseScriptErrorLocation(lastRunError);
    final useExcerpt = errorLoc != null &&
        (lastRunError?.toLowerCase().contains('syntax') ?? false);
    final scriptBlock = useExcerpt
        ? '''
${buildScriptExcerpt(currentScript, location: errorLoc)}

(Full script is ${currentScript.length} chars. Apply edits against the FULL source;
oldStringBase64 must still match the full file exactly — copy from the excerpt lines.)
'''
        : '''
CURRENT SCRIPT:
$currentScript
''';

    final initialUserPrompt = '''
You are applying a surgical patch to Bro Code for Project Aur Bhai.
Prefer edits on listed assets for HTML/PWA; thin scriptBase64 only when execute() must change. Respond in English only.
Bro Code name: $agentName
Current description: ${currentDescription ?? 'n/a'}
Current input schema: $schemaJson

${AgentBridgeSpec.bridgeSpecForLlm}

$contextBlocks
$assetsBlock
$scriptBlock
USER CHANGE REQUEST:
"$changeRequest"

Respond ONLY in RAW JSON with either scriptBase64 OR edits[] (Base64 snippets).
''';

    final messages = <LlmChatMessage>[
      LlmChatMessage(role: 'user', content: initialUserPrompt),
    ];
    if (chatSeed != null && chatSeed.isNotEmpty) {
      messages.add(const LlmChatMessage(
        role: 'model',
        content:
            '{"notes":"previous attempt did not produce a valid verified patch"}',
      ));
      messages.addAll(chatSeed);
    }

    Object? lastFailure;
    String? lastRaw;

    for (var turn = 1; turn <= kMaxRefineModelTurns; turn++) {
      progress(
        turn == 1
            ? 'Surgical fallback turn $turn/$kMaxRefineModelTurns…'
            : 'Repair turn $turn/$kMaxRefineModelTurns…',
      );

      String raw;
      try {
        raw = await improveProvider.completeChat(
          messages: messages,
          jsonMode: true,
          timeout: const Duration(seconds: 60),
          maxTokens: 12288,
        );
      } on TimeoutException {
        lastFailure = TimeoutException(
          'Patch generation timed out. Tap Retry.',
          const Duration(seconds: 60),
        );
        progress('Model timed out on turn $turn');
        break;
      }

      lastRaw = raw;
      progress('Received response (${raw.length} chars)');
      messages.add(LlmChatMessage(role: 'model', content: raw));

      Map<String, dynamic> decoded;
      try {
        decoded = jsonDecode(_cleanJsonString(raw)) as Map<String, dynamic>;
      } on FormatException catch (e) {
        lastFailure = e;
        progress(
          'Parse error: ${e.message}. Raw: ${truncateForLog(raw)}',
        );
        if (turn >= kMaxRefineModelTurns) break;
        messages.add(LlmChatMessage(
          role: 'user',
          content: '''
Your previous reply was invalid JSON (${e.message}).
Return scriptBase64 of the FULL Bro Code, or edits with oldStringBase64/newStringBase64.
''',
        ));
        continue;
      }

      late final String script;
      var assetUpdates = <String, String>{};
      try {
        if (decoded.containsKey('scriptBase64') ||
            decoded.containsKey('script')) {
          progress('Applying full scriptBase64 rewrite…');
          script = scriptFromDraftJson(decoded);
        } else {
          final edits = parseScriptEdits(decoded);
          if (edits == null) {
            throw const FormatException(
              'Expected scriptBase64 or edits[].',
            );
          }
          final grouped = groupEditsByAsset(edits);
          final mainEdits = grouped[null] ?? const <ScriptEdit>[];
          progress('Applying ${edits.length} edit(s) locally…');
          script = mainEdits.isEmpty
              ? currentScript
              : applyScriptEdits(currentScript, mainEdits);

          for (final entry in grouped.entries) {
            final assetId = entry.key;
            if (assetId == null) continue;
            final existing = currentAssets[assetId];
            if (existing == null) {
              throw FormatException(
                'Edit targets unknown asset "$assetId".',
              );
            }
            assetUpdates[assetId] = applyScriptEdits(existing, entry.value);
          }
        }
      } catch (e) {
        lastFailure = e;
        progress('Apply failed: ${scriptEditFailureMessage(e)}');
        if (turn >= kMaxRefineModelTurns) break;
        messages.add(LlmChatMessage(
          role: 'user',
          content: '''
Apply failed: ${scriptEditFailureMessage(e)}
Return scriptBase64 of the complete Bro Code (preferred).
''',
        ));
        continue;
      }

      progress('QuickJS syntax check…');
      final syntax = bridge.validateScriptSyntax(script);
      if (!syntax.ok) {
        lastFailure = Exception(syntax.message ?? 'QuickJS syntax check failed');
        progress('Syntax check failed: ${syntax.message}');
        if (turn >= kMaxRefineModelTurns) break;
        messages.add(LlmChatMessage(
          role: 'user',
          content: '''
QuickJS rejected the script: ${syntax.message}
Return corrected scriptBase64 for the full Bro Code.
''',
        ));
        continue;
      }

      progress('Verified: QuickJS syntax OK — Bro Code ready');
      return AuthoredAgentDraft(
        name: agentName,
        description: (decoded['description'] as String?)?.trim() ??
            currentDescription ??
            'Refined Bro Code.',
        inputSchema: decoded['inputSchema'] is Map
            ? Map<String, dynamic>.from(decoded['inputSchema'] as Map)
            : currentInputSchema ?? <String, dynamic>{},
        script: script,
        notes: decoded['notes'] as String?,
        assetUpdates: assetUpdates,
      );
    }

    throw Exception(
      authoredJsonParseFailureMessage(
        lastFailure ??
            Exception(
              'Repair loop exhausted after $kMaxRefineModelTurns turns. Tap Retry.',
            ),
        rawSnippet: lastRaw,
      ),
    );
  }

  String _cleanJsonString(String response) {
    var clean = response.trim();
    if (clean.startsWith('```json')) {
      clean = clean.substring(7);
    } else if (clean.startsWith('```')) {
      clean = clean.substring(3);
    }
    if (clean.endsWith('```')) {
      clean = clean.substring(0, clean.length - 3);
    }
    return clean.trim();
  }
}

final llmServiceProvider = Provider<LlmService>((ref) {
  return LlmService(ref);
});
