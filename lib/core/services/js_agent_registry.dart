import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agents/agent_base.dart';
import '../agents/js_agent_adapter.dart';
import '../pipeline/authoring_trace.dart';
import 'agent_service.dart';
import 'agent_verification_service.dart';
import 'bhai_code_origin.dart';
import 'js_bridge_service.dart';
import 'model_studio/bro_code_ml_meta.dart';
import 'telemetry_bus.dart';

/// Loads Javascript Bro Code from the sovereign vault and registers it.
class JsAgentRegistry {
  /// Canonical vault prefix for Bro Code units (legacy `agent:` still loaded).
  static const vaultPrefix = 'agent:';
  static const broVaultPrefix = 'bro:';

  final Ref _ref;

  JsAgentRegistry(this._ref);

  String vaultKeyFor(String name) => '$vaultPrefix$name';
  String schemaKeyFor(String name) => '$vaultPrefix$name:schema';
  String assetKeyFor(String name, String assetId) =>
      '$vaultPrefix$name:asset:$assetId';

  /// Lists related vault assets for an agent (`agent:<Name>:asset:<id>` → content).
  Future<Map<String, String>> readAgentAssets(String name) async {
    final telemetry = _ref.read(telemetryBusProvider);
    final prefix = '$vaultPrefix$name:asset:';
    final keys = await telemetry.listVaultKeys(prefix: prefix);
    final assets = <String, String>{};
    for (final key in keys) {
      if (!key.startsWith(prefix)) continue;
      final id = key.substring(prefix.length);
      if (id.isEmpty) continue;
      final entry = await telemetry.readVaultData(key);
      final value = entry?['value'];
      if (value != null) assets[id] = value;
    }
    return assets;
  }

  /// Scans `sovereign_vault` for `agent:<Name>` / `bro:<Name>` and registers.
  Future<int> loadAndRegisterAgents() async {
    final telemetry = _ref.read(telemetryBusProvider);
    final agentService = _ref.read(agentServiceProvider);
    var registered = 0;

    for (final prefix in [vaultPrefix, broVaultPrefix]) {
      final keys = await telemetry.listVaultKeys(prefix: prefix);

      for (final key in keys) {
        try {
          if (key.endsWith(':schema')) continue;
          // Skip version archives and related assets — not top-level scripts.
          if (RegExp(r':v\d+$').hasMatch(key)) continue;
          if (key.contains(':asset:')) continue;

          final vaultEntry = await telemetry.readVaultData(key);
          if (vaultEntry == null) continue;

          final agentName = key.substring(prefix.length);
          if (agentName.isEmpty || agentName.contains(':')) continue;
          if (_deprecatedLegacyAgents.contains(agentName)) continue;

          final schemaEntry = await telemetry.readVaultData('$key:schema');
          final schema = schemaEntry != null
              ? jsonDecode(schemaEntry['value']!) as Map<String, dynamic>
              : <String, dynamic>{};

          final displayName = schema['name'] as String? ?? agentName;
          final description =
              schema['description'] as String? ??
              'Bro Code loaded from vault ($key)';
          final createdAt = _parseDate(schema['createdAt'] as String?);
          final updatedAt = _parseDate(schema['updatedAt'] as String?);
          final assets = await readAgentAssets(displayName);
          final bhaiWordsRaw = schema['bhaiWords'] as List?;
          final bhaiWords = bhaiWordsRaw != null
              ? bhaiWordsRaw.map((e) => e.toString()).toList()
              : null;
          final invocationPrompt = schema['invocationPrompt'] as String?;

          agentService.registerAgent(
            JsAgentAdapter(
              ref: _ref,
              name: displayName,
              description: description,
              inputSchema: _parseInputSchema(schema['inputSchema']),
              script: vaultEntry['value']!,
              assets: assets,
              securityClass: AgentSecurityClassX.fromId(
                schema['securityClass'] as String?,
              ),
              source: BhaiCodeOrigin.normalize(schema['source'] as String?),
              diligencePassed: schema['diligencePassed'] as bool? ?? false,
              createdAt: createdAt,
              updatedAt: updatedAt,
              bhaiWords: bhaiWords,
              invocationPrompt: invocationPrompt,
            ),
          );
          registered++;
          debugPrint('[JsAgentRegistry] Registered Bro Code: $displayName');
        } catch (e, st) {
          debugPrint('[JsAgentRegistry] Error loading agent key "$key": $e\n$st');
        }
      }
    }

    return registered;
  }

  /// Consumes `tool/.friend_install_queue.json` written by
  /// `dart run tool/install_issue_fixture.dart` (desktop / same machine).
  Future<void> consumeFriendInstallQueueIfPresent() async {
    if (kIsWeb) return;
    final candidates = <File>[
      File('tool/.friend_install_queue.json'),
      File(
        '${Directory.current.path}${Platform.pathSeparator}tool${Platform.pathSeparator}.friend_install_queue.json',
      ),
    ];
    File? queue;
    for (final f in candidates) {
      if (f.existsSync()) {
        queue = f;
        break;
      }
    }
    if (queue == null) return;

    try {
      final payload =
          jsonDecode(queue.readAsStringSync()) as Map<String, dynamic>;
      final name = payload['name'] as String? ?? '';
      final script = payload['script'] as String? ?? '';
      if (name.isEmpty || script.isEmpty) {
        debugPrint('[JsAgentRegistry] Friend install queue invalid; skipping');
        return;
      }
      final inputRaw = Map<String, dynamic>.from(
        payload['inputSchema'] as Map? ?? {},
      );
      final inputSchema = <String, AgentParameter>{};
      for (final e in inputRaw.entries) {
        final field = e.value is Map
            ? Map<String, dynamic>.from(e.value as Map)
            : <String, dynamic>{};
        inputSchema[e.key] = AgentParameter(
          type: field['type']?.toString() ?? 'string',
          description: field['description']?.toString() ?? '',
          required: field['required'] as bool? ?? false,
        );
      }
      await saveAndRegisterAgent(
        name: name,
        description: payload['description'] as String? ?? name,
        inputSchema: inputSchema,
        script: script,
        securityClass: AgentSecurityClass.c4Unverified,
      );
      final traceRaw = payload['authoringTrace'];
      if (traceRaw is Map) {
        final trace = AuthoringTrace.fromJson(
          Map<String, dynamic>.from(traceRaw),
        );
        await _ref
            .read(telemetryBusProvider)
            .writeVaultData(
              AuthoringTrace.vaultKeyFor(name),
              trace.toJsonString(),
              mimeType: 'application/json',
            );
      }
      final bak = File('${queue.path}.installed');
      queue.renameSync(bak.path);
      debugPrint(
        '[JsAgentRegistry] Installed friend fixture as $name (C4). '
        'Do not Publish unless intentional.',
      );
    } catch (e) {
      debugPrint('[JsAgentRegistry] Friend install failed: $e');
    }
  }

  /// Persists a JS agent + metadata to the vault and registers it live.
  ///
  /// This is the shared sink for both LLM authoring (Path A) and manual
  /// import (Path B). Vault convention: `agent:<Name>` + `agent:<Name>:schema`.
  Future<JsAgentAdapter> saveAndRegisterAgent({
    required String name,
    required String description,
    required Map<String, AgentParameter> inputSchema,
    required String script,
    Map<String, String>? vaultAssets,
    AgentSecurityClass securityClass = AgentSecurityClass.c4Unverified,
    String? source,
    bool? diligencePassed,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<String>? bhaiWords,
    String? invocationPrompt,
    BroCodeMlMeta? mlMeta,
  }) async {
    final syntax = _ref
        .read(jsBridgeServiceProvider)
        .validateScriptSyntax(script);
    if (!syntax.ok) {
      throw Exception(
        'Script failed QuickJS syntax check: ${syntax.message ?? "unknown error"}',
      );
    }

    final telemetry = _ref.read(telemetryBusProvider);
    final agentService = _ref.read(agentServiceProvider);
    final now = DateTime.now().toIso8601String();

    // Preserve existing createdAt / source / diligence / bhaiWords when overwriting.
    String? existingCreatedAt;
    String? existingSource;
    bool? existingDiligence;
    List<String>? existingBhaiWords;
    String? existingInvocationPrompt;
    Map<String, dynamic>? priorMl;
    final priorSchema = await telemetry.readVaultData(schemaKeyFor(name));
    if (priorSchema != null) {
      try {
        final decoded =
            jsonDecode(priorSchema['value']!) as Map<String, dynamic>;
        existingCreatedAt = decoded['createdAt'] as String?;
        existingSource = decoded['source'] as String?;
        existingDiligence = decoded['diligencePassed'] as bool?;
        if (decoded['bhaiWords'] is List) {
          existingBhaiWords = (decoded['bhaiWords'] as List)
              .map((e) => e.toString())
              .toList();
        }
        existingInvocationPrompt = decoded['invocationPrompt'] as String?;
        if (decoded['ml'] is Map) {
          priorMl = Map<String, dynamic>.from(decoded['ml'] as Map);
        }
      } catch (_) {}
    }

    final created = createdAt?.toIso8601String() ?? existingCreatedAt ?? now;
    final updated = updatedAt?.toIso8601String() ?? now;
    final resolvedSource = BhaiCodeOrigin.normalize(
      source ?? existingSource ?? BhaiCodeOrigin.self,
    );
    
    // Automatically run due diligence scan if not explicitly given
    final scan = _ref.read(agentVerificationProvider).scanScript(script);
    final resolvedDiligence = diligencePassed ?? existingDiligence ?? !scan.flagged;
    final resolvedBhaiWords = bhaiWords ?? existingBhaiWords;
    final resolvedInvocation = invocationPrompt ?? existingInvocationPrompt;

    await telemetry.writeVaultData(
      vaultKeyFor(name),
      script,
      mimeType: 'application/javascript',
    );
    if (vaultAssets != null && vaultAssets.isNotEmpty) {
      for (final entry in vaultAssets.entries) {
        final mime = entry.key.endsWith('.html') ? 'text/html' : 'text/plain';
        // Write under scoped key so readAgentAssets() can find it on reload.
        await telemetry.writeVaultData(
          '${vaultKeyFor(name)}:asset:${entry.key}',
          entry.value,
          mimeType: mime,
        );
        // Also write the bare key so scripts that do writeVault('telemeter.html', ...)
        // via System.writeVault still work and the local server can serve them.
        await telemetry.writeVaultData(entry.key, entry.value, mimeType: mime);
      }
    }
    var schemaMap = <String, dynamic>{
      'name': name,
      'description': description,
      'securityClass': securityClass.id,
      'source': resolvedSource,
      'diligencePassed': resolvedDiligence,
      'createdAt': created,
      'updatedAt': updated,
      'inputSchema': inputSchema.map(
        (key, param) => MapEntry(key, param.toJson()),
      ),
    };
    if (resolvedBhaiWords != null) {
      schemaMap['bhaiWords'] = resolvedBhaiWords;
    }
    if (resolvedInvocation != null) {
      schemaMap['invocationPrompt'] = resolvedInvocation;
    }
    if (vaultAssets != null && vaultAssets.isNotEmpty) {
      schemaMap['vaultAssets'] = vaultAssets;
    }
    if (mlMeta != null) {
      schemaMap = BroCodeMlMeta.mergeIntoSchema(schemaMap, mlMeta);
    } else if (priorMl != null) {
      schemaMap['ml'] = priorMl;
    }
    await telemetry.writeVaultData(
      schemaKeyFor(name),
      jsonEncode(schemaMap),
      mimeType: 'application/json',
    );

    final assets = await readAgentAssets(name);
    final adapter = JsAgentAdapter(
      ref: _ref,
      name: name,
      description: description,
      inputSchema: inputSchema,
      script: script,
      assets: assets,
      securityClass: securityClass,
      source: resolvedSource,
      diligencePassed: resolvedDiligence,
      createdAt: DateTime.tryParse(created),
      updatedAt: DateTime.tryParse(updated),
      bhaiWords: resolvedBhaiWords,
      invocationPrompt: resolvedInvocation,
    );
    agentService.registerAgent(adapter);
    debugPrint(
      '[JsAgentRegistry] Saved & registered agent: $name (${securityClass.id}, diligence: $resolvedDiligence)',
    );
    return adapter;
  }

  /// Persist / update Path L ML metadata on Bro Code schema (MS-MODEL-META).
  Future<bool> updateMlMeta(String name, BroCodeMlMeta meta) async {
    final telemetry = _ref.read(telemetryBusProvider);
    final schemaEntry = await telemetry.readVaultData(schemaKeyFor(name));
    if (schemaEntry == null) return false;
    try {
      final schema = jsonDecode(schemaEntry['value']!) as Map<String, dynamic>;
      final next = BroCodeMlMeta.mergeIntoSchema(schema, meta);
      next['updatedAt'] = DateTime.now().toIso8601String();
      await telemetry.writeVaultData(
        schemaKeyFor(name),
        jsonEncode(next),
        mimeType: 'application/json',
      );
      return true;
    } catch (e) {
      debugPrint('[JsAgentRegistry] updateMlMeta failed: $e');
      return false;
    }
  }

  Future<BroCodeMlMeta?> readMlMeta(String name) async {
    final telemetry = _ref.read(telemetryBusProvider);
    final schemaEntry = await telemetry.readVaultData(schemaKeyFor(name));
    return BroCodeMlMeta.fromSchemaJson(schemaEntry?['value']);
  }

  /// Removes an agent from the vault and the live registry.
  Future<void> deleteAgent(String name) async {
    final telemetry = _ref.read(telemetryBusProvider);
    final agentService = _ref.read(agentServiceProvider);
    await telemetry.deleteVaultData(vaultKeyFor(name));
    await telemetry.deleteVaultData(schemaKeyFor(name));
    agentService.removeAgent(name);
  }

  /// Names of all JS agents currently persisted in the vault.
  Future<List<String>> listJsAgentNames() async {
    final telemetry = _ref.read(telemetryBusProvider);
    final keys = await telemetry.listVaultKeys(prefix: vaultPrefix);
    return keys
        .where((k) => !k.endsWith(':schema'))
        .map((k) => k.substring(vaultPrefix.length))
        .toList();
  }

  /// Updates the persisted security class and refreshes the live adapter.
  Future<bool> updateSecurityClass(
    String name,
    AgentSecurityClass securityClass,
  ) async {
    final telemetry = _ref.read(telemetryBusProvider);
    final schemaEntry = await telemetry.readVaultData(schemaKeyFor(name));
    if (schemaEntry == null) return false;

    final schema = jsonDecode(schemaEntry['value']!) as Map<String, dynamic>;
    schema['securityClass'] = securityClass.id;
    await telemetry.writeVaultData(
      schemaKeyFor(name),
      jsonEncode(schema),
      mimeType: 'application/json',
    );

    final agentService = _ref.read(agentServiceProvider);
    final existing = agentService.findAgent(name);
    if (existing is JsAgentAdapter) {
      agentService.registerAgent(
        JsAgentAdapter(
          ref: _ref,
          name: existing.name,
          description: existing.description,
          inputSchema: existing.inputSchema,
          script: existing.script,
          assets: existing.assets,
          securityClass: securityClass,
          source: existing.source,
          diligencePassed: existing.diligencePassed,
          createdAt: existing.createdAt,
          updatedAt: existing.updatedAt,
        ),
      );
    }
    debugPrint(
      '[JsAgentRegistry] Updated $name security class to ${securityClass.id}',
    );
    return true;
  }

  /// Persist on-demand diligence result (does not change security class).
  Future<bool> setDiligencePassed(String name, bool passed) async {
    final telemetry = _ref.read(telemetryBusProvider);
    final schemaEntry = await telemetry.readVaultData(schemaKeyFor(name));
    if (schemaEntry == null) return false;

    final schema = jsonDecode(schemaEntry['value']!) as Map<String, dynamic>;
    schema['diligencePassed'] = passed;
    await telemetry.writeVaultData(
      schemaKeyFor(name),
      jsonEncode(schema),
      mimeType: 'application/json',
    );

    final agentService = _ref.read(agentServiceProvider);
    final existing = agentService.findAgent(name);
    if (existing is JsAgentAdapter) {
      agentService.registerAgent(
        JsAgentAdapter(
          ref: _ref,
          name: existing.name,
          description: existing.description,
          inputSchema: existing.inputSchema,
          script: existing.script,
          assets: existing.assets,
          securityClass: existing.securityClass,
          source: existing.source,
          diligencePassed: passed,
          createdAt: existing.createdAt,
          updatedAt: existing.updatedAt,
        ),
      );
    }
    return true;
  }

  /// Reads script + schema from vault without requiring a live registration.
  Future<Map<String, dynamic>?> readAgentBundle(String name) async {
    final telemetry = _ref.read(telemetryBusProvider);
    final scriptEntry = await telemetry.readVaultData(vaultKeyFor(name));
    if (scriptEntry == null) return null;
    final schemaEntry = await telemetry.readVaultData(schemaKeyFor(name));
    final schema = schemaEntry != null
        ? jsonDecode(schemaEntry['value']!) as Map<String, dynamic>
        : <String, dynamic>{};
    return {
      'script': scriptEntry['value'],
      'schema': schema,
      'description': schema['description'] as String? ?? '',
    };
  }

  /// Saves a prior version then writes patched source. Material change → C4 (MS-AGENT-REFINE-AGT1).
  Future<JsAgentAdapter> refineAndReregister({
    required String name,
    required String script,
    String? description,
    Map<String, AgentParameter>? inputSchema,
    Map<String, String> assetUpdates = const {},
  }) async {
    final telemetry = _ref.read(telemetryBusProvider);
    final existingScript = await telemetry.readVaultData(vaultKeyFor(name));
    if (existingScript != null) {
      final versionKeys = await telemetry.listVaultKeys(
        prefix: '${vaultKeyFor(name)}:v',
      );
      final nextVersion = versionKeys.length + 1;
      await telemetry.writeVaultData(
        '${vaultKeyFor(name)}:v$nextVersion',
        existingScript['value']!,
        mimeType: 'application/javascript',
      );
      debugPrint('[JsAgentRegistry] Archived $name as v$nextVersion');
    }

    for (final entry in assetUpdates.entries) {
      final lower = entry.key.toLowerCase();
      final mime = lower.endsWith('.html') || lower.endsWith('.htm')
          ? 'text/html'
          : lower.endsWith('.webmanifest') || lower.endsWith('manifest.json')
          ? 'application/manifest+json'
          : lower.endsWith('.js')
          ? 'application/javascript'
          : 'text/plain';
      await telemetry.writeVaultData(
        assetKeyFor(name, entry.key),
        entry.value,
        mimeType: mime,
      );
      debugPrint('[JsAgentRegistry] Updated asset ${entry.key} for $name');
    }

    final bundle = await readAgentBundle(name);
    final schema = bundle?['schema'] as Map<String, dynamic>? ?? {};
    final desc =
        description ?? schema['description'] as String? ?? 'Refined agent.';
    final schemaParams =
        inputSchema ?? _parseInputSchema(schema['inputSchema']);

    return saveAndRegisterAgent(
      name: name,
      description: desc,
      inputSchema: schemaParams,
      script: script,
      securityClass: AgentSecurityClass.c4Unverified,
    );
  }

  /// Exports a vault agent bundle (script + schema) for laptop portability.
  Future<Map<String, dynamic>?> exportAgentBundle(String name) async {
    final telemetry = _ref.read(telemetryBusProvider);
    final script = await telemetry.readVaultData(vaultKeyFor(name));
    if (script == null) return null;
    final schema = await telemetry.readVaultData(schemaKeyFor(name));
    return {
      'name': name,
      'script': script['value'],
      'schema': schema != null ? jsonDecode(schema['value']!) : null,
    };
  }

  static const Set<String> _deprecatedLegacyAgents = {
    'CallDemo',
    'DrivingCoach',
    'FacebookPoster',
    'TelemetryCounter',
    'Xter',
    'HelloCounter',
    'TipJar',
    'XterAgent',
    'DrivingCoachAgent',
  };

  /// Prunes deprecated historical demo agents and invalid sub-resource keys from the vault.
  Future<void> pruneDeprecatedLegacyAgents() async {
    final telemetry = _ref.read(telemetryBusProvider);
    final agentService = _ref.read(agentServiceProvider);

    for (final prefix in [vaultPrefix, broVaultPrefix]) {
      final keys = await telemetry.listVaultKeys(prefix: prefix);
      for (final key in keys) {
        if (key.endsWith(':schema')) continue;
        final rawName = key.substring(prefix.length);

        final isSubResource = rawName.contains(':');
        final isDeprecated = _deprecatedLegacyAgents.contains(rawName);

        if (isSubResource || isDeprecated) {
          debugPrint(
            '[JsAgentRegistry] Pruning deprecated/invalid vault agent: $rawName',
          );
          await telemetry.deleteVaultData(key);
          await telemetry.deleteVaultData('$key:schema');
          final assetKeys = await telemetry.listVaultKeys(
            prefix: '$prefix$rawName:asset:',
          );
          for (final ak in assetKeys) {
            await telemetry.deleteVaultData(ak);
          }
          agentService.remove(rawName);
        }
      }
    }
  }

  /// Completely cleans up legacy C4 unpicked auto-installs and resets catalog state to pristine:
  /// Calculator in C2 (Mere Bhai), and clean Sandbox.
  Future<void> resetVaultToPristineCatalog() async {
    final telemetry = _ref.read(telemetryBusProvider);
    final agentService = _ref.read(agentServiceProvider);

    await pruneDeprecatedLegacyAgents();

    // Remove any C4 seed-catalog agents that were auto-installed into Sandbox
    for (final prefix in [vaultPrefix, broVaultPrefix]) {
      final keys = await telemetry.listVaultKeys(prefix: prefix);
      for (final key in keys) {
        if (key.endsWith(':schema')) continue;
        final name = key.substring(prefix.length);
        if (name.isEmpty || name.contains(':')) continue;

        final schemaEntry = await telemetry.readVaultData('$key:schema');
        if (schemaEntry != null) {
          try {
            final schema =
                jsonDecode(schemaEntry['value']!) as Map<String, dynamic>;
            final secClass = schema['securityClass']?.toString();
            final source = schema['source']?.toString();
            if (secClass == 'C4' &&
                (source == 'pool' || source == 'catalog' || source == null)) {
              await telemetry.deleteVaultData(key);
              await telemetry.deleteVaultData('$key:schema');
              final assetKeys = await telemetry.listVaultKeys(
                prefix: '$prefix$name:asset:',
              );
              for (final ak in assetKeys) {
                await telemetry.deleteVaultData(ak);
              }
              agentService.remove(name);
              debugPrint(
                '[JsAgentRegistry] Cleared legacy C4 sandbox seed: $name',
              );
            }
          } catch (_) {}
        }
      }
    }

    // Ensure Calculator is C2
    await seedCoreAgentsIfMissing();
  }

  /// Seeds the minimal core agent (Calculator) into the vault as
  /// a refinable JS agent pre-verified at C2 (MS-CORE-JS-MIGRATION).
  ///
  /// Guarded by "if missing" so user refinements are never overwritten on boot.
  Future<void> seedCoreAgentsIfMissing() async {
    final telemetry = _ref.read(telemetryBusProvider);
    final calcSchema = await telemetry.readVaultData(schemaKeyFor('Calculator'));
    if (calcSchema != null) {
      try {
        final decoded =
            jsonDecode(calcSchema['value']!) as Map<String, dynamic>;
        if (decoded['securityClass'] != AgentSecurityClass.c2Verified.id) {
          await updateSecurityClass('Calculator', AgentSecurityClass.c2Verified);
        }
      } catch (_) {}
    }
    await _seedAgentIfMissing(
      name: 'Calculator',
      description:
          'Evaluates standard arithmetic expressions including powers (e.g., 2+2, 12 * 12, (50 - 10) / 2, 2^3).',
      script: _calculatorScript,
      inputSchema: {
        'expression': {
          'type': 'string',
          'description':
              'The standard mathematical expression to solve. Supports + - * / ^ and parentheses, e.g. "2+2" or "2^3".',
          'required': true,
        },
      },
      bhaiWords: const ['calculate', 'what is', 'how much is'],
      invocationPrompt: 'Calculate 15 * 84',
    );
  }

  /// Writes a C2 core JS agent to the vault if it does not already exist.
  Future<void> _seedAgentIfMissing({
    required String name,
    required String description,
    required String script,
    required Map<String, dynamic> inputSchema,
    List<String>? bhaiWords,
    String? invocationPrompt,
  }) async {
    final telemetry = _ref.read(telemetryBusProvider);
    if (await telemetry.readVaultData(vaultKeyFor(name)) != null) return;

    final now = DateTime.now().toIso8601String();
    await telemetry.writeVaultData(
      vaultKeyFor(name),
      script,
      mimeType: 'application/javascript',
    );
    await telemetry.writeVaultData(
      schemaKeyFor(name),
      jsonEncode({
        'name': name,
        'description': description,
        'securityClass': AgentSecurityClass.c2Verified.id,
        'createdAt': now,
        'updatedAt': now,
        'inputSchema': inputSchema,
        if (bhaiWords != null) 'bhaiWords': bhaiWords,
        if (invocationPrompt != null) 'invocationPrompt': invocationPrompt,
      }),
      mimeType: 'application/json',
    );
    debugPrint('[JsAgentRegistry] Seeded core agent: $name (C2)');
  }

  Map<String, AgentParameter> _parseInputSchema(dynamic raw) {
    if (raw is! Map) return const {};

    return raw.map((key, value) {
      final field = value is Map ? value : <String, dynamic>{};
      return MapEntry(
        key.toString(),
        AgentParameter(
          type: field['type']?.toString() ?? 'string',
          description: field['description']?.toString() ?? '',
          required: field['required'] as bool? ?? true,
        ),
      );
    });
  }

  DateTime? _parseDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    return DateTime.tryParse(raw.trim());
  }
}

/// Calculator as a refinable JS vault agent (MS-CORE-JS-MIGRATION).
/// Recursive-descent evaluator supporting + - * / ^ and parentheses.
const _calculatorScript = r'''
async function execute(params) {
  var raw = (params.expression == null) ? '' : String(params.expression);
  var expr = raw
    .replace(/[a-zA-Z]/g, '')
    .replace(/\u00F7/g, '/')
    .trim();
  if (!expr) return 'No valid mathematical expression was provided.';

  var i = 0;
  function skip() { while (i < expr.length && /\s/.test(expr[i])) i++; }

  function parseExpression() {
    var left = parseTerm();
    while (true) {
      skip();
      var op = expr[i];
      if (op === '+' || op === '-') {
        i++;
        var r = parseTerm();
        left = (op === '+') ? left + r : left - r;
      } else break;
    }
    return left;
  }

  function parseTerm() {
    var left = parseFactor();
    while (true) {
      skip();
      var op = expr[i];
      if (op === '*' || op === '/') {
        i++;
        var r = parseFactor();
        if (op === '/') {
          if (r === 0) throw new Error('Division by zero');
          left = left / r;
        } else {
          left = left * r;
        }
      } else break;
    }
    return left;
  }

  function parseFactor() {
    skip();
    var c = expr[i];
    if (c === '+') { i++; return parseFactor(); }
    if (c === '-') { i++; return -parseFactor(); }
    return parsePower();
  }

  function parsePower() {
    var base = parseAtom();
    skip();
    if (expr[i] === '^') {
      i++;
      var exponent = parseFactor();
      return Math.pow(base, exponent);
    }
    return base;
  }

  function parseAtom() {
    skip();
    if (i >= expr.length) throw new Error('Unexpected end of expression');
    if (expr[i] === '(') {
      i++;
      var v = parseExpression();
      skip();
      if (expr[i] !== ')') throw new Error("Unbalanced parenthesis: missing ')'");
      i++;
      return v;
    }
    var start = i;
    var hasDot = false;
    while (i < expr.length) {
      var ch = expr[i];
      if (ch >= '0' && ch <= '9') {
        i++;
      } else if (ch === '.') {
        if (hasDot) throw new Error('Multiple decimal points in a single number');
        hasDot = true;
        i++;
      } else break;
    }
    if (start === i) throw new Error("Unexpected character '" + expr[i] + "'");
    return parseFloat(expr.substring(start, i));
  }

  try {
    var result = parseExpression();
    skip();
    if (i < expr.length) throw new Error("Unexpected character '" + expr[i] + "'");
    var out = (result === Math.floor(result))
      ? String(result)
      : String(Math.round(result * 10000) / 10000);
    System.log('Calculator evaluated: ' + expr + ' = ' + out);
    return 'Calculator agent says, the answer is ' + out + '.';
  } catch (e) {
    return 'Calculator agent encountered an error: ' + (e && e.message ? e.message : e);
  }
}
''';

final jsAgentRegistryProvider = Provider<JsAgentRegistry>((ref) {
  return JsAgentRegistry(ref);
});
