import 'dart:convert';

/// Lifecycle of a single authoring slot (Arch v3.7 implicit-consent model).
enum SlotStatus { empty, proposed, confirmed }

/// How the value was obtained.
enum SlotConfidence { stated, inferred, unknown }

/// Ordered AUTHOR slots — conditional ones may be skipped when irrelevant.
enum AppSpecSlot {
  purpose,
  name,
  invocationPrompt,
  parameters,
  behaviorResponse,
  dataSources,
  outputs,
  triggersBeyondVoice,
  sensorsPermissions,
  externalKeys,
  exampleSuccess,
  edgeCases,
  externalIntegrations,
}

/// A variable parsed from the invocation prompt → agent inputSchema binding.
class ParameterBinding {
  final String name;
  final String type;
  final String description;
  final String? exampleInPrompt;

  const ParameterBinding({
    required this.name,
    required this.type,
    required this.description,
    this.exampleInPrompt,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'description': description,
    if (exampleInPrompt != null) 'exampleInPrompt': exampleInPrompt,
  };

  factory ParameterBinding.fromJson(Map<String, dynamic> json) {
    return ParameterBinding(
      name: (json['name'] as String?)?.trim() ?? '',
      type: (json['type'] as String?)?.trim() ?? 'string',
      description: (json['description'] as String?)?.trim() ?? '',
      exampleInPrompt: json['exampleInPrompt'] as String?,
    );
  }

  Map<String, dynamic> toInputSchemaField() => {
    'type': type,
    'description': description,
    'required': true,
  };
}

/// External platform action (X, Facebook, Instagram, YouTube, Threads, webhook).
class ExternalIntegration {
  final String platform;
  final String action;
  final String? constraints;
  final String? mediaType;
  final bool requiresByokKey;

  const ExternalIntegration({
    required this.platform,
    required this.action,
    this.constraints,
    this.mediaType,
    this.requiresByokKey = true,
  });

  Map<String, dynamic> toJson() => {
    'platform': platform,
    'action': action,
    if (constraints != null) 'constraints': constraints,
    if (mediaType != null) 'mediaType': mediaType,
    'requiresByokKey': requiresByokKey,
  };

  factory ExternalIntegration.fromJson(Map<String, dynamic> json) {
    return ExternalIntegration(
      platform: (json['platform'] as String?)?.trim() ?? '',
      action: (json['action'] as String?)?.trim() ?? '',
      constraints: json['constraints'] as String?,
      mediaType: json['mediaType'] as String?,
      requiresByokKey: json['requiresByokKey'] as bool? ?? true,
    );
  }
}

/// One scalar/list slot in the app spec.
class SpecField {
  final String? value;
  final SlotStatus status;
  final SlotConfidence confidence;

  const SpecField({
    this.value,
    this.status = SlotStatus.empty,
    this.confidence = SlotConfidence.unknown,
  });

  bool get hasValue => value != null && value!.trim().isNotEmpty;

  SpecField copyWith({
    String? value,
    SlotStatus? status,
    SlotConfidence? confidence,
  }) {
    return SpecField(
      value: value ?? this.value,
      status: status ?? this.status,
      confidence: confidence ?? this.confidence,
    );
  }

  Map<String, dynamic> toJson() => {
    'value': value,
    'status': status.name,
    'confidence': confidence.name,
  };

  factory SpecField.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const SpecField();
    return SpecField(
      value: json['value'] as String?,
      status: _statusFromString(json['status'] as String?),
      confidence: _confidenceFromString(json['confidence'] as String?),
    );
  }

  static SlotStatus _statusFromString(String? raw) {
    switch (raw?.toLowerCase()) {
      case 'proposed':
        return SlotStatus.proposed;
      case 'confirmed':
        return SlotStatus.confirmed;
      default:
        return SlotStatus.empty;
    }
  }

  static SlotConfidence _confidenceFromString(String? raw) {
    switch (raw?.toLowerCase()) {
      case 'stated':
        return SlotConfidence.stated;
      case 'inferred':
        return SlotConfidence.inferred;
      default:
        return SlotConfidence.unknown;
    }
  }
}

/// Full agent authoring specification (Arch v3.7).
class AppSpec {
  SpecField purpose;
  SpecField name;
  SpecField invocationPrompt;
  List<ParameterBinding> parameters;
  SpecField behaviorResponse;
  SpecField dataSources;
  SpecField outputs;
  SpecField triggersBeyondVoice;
  SpecField sensorsPermissions;
  SpecField externalKeys;
  SpecField exampleSuccess;
  SpecField edgeCases;
  List<ExternalIntegration> externalIntegrations;

  AppSpec({
    SpecField? purpose,
    SpecField? name,
    SpecField? invocationPrompt,
    List<ParameterBinding>? parameters,
    SpecField? behaviorResponse,
    SpecField? dataSources,
    SpecField? outputs,
    SpecField? triggersBeyondVoice,
    SpecField? sensorsPermissions,
    SpecField? externalKeys,
    SpecField? exampleSuccess,
    SpecField? edgeCases,
    List<ExternalIntegration>? externalIntegrations,
  }) : purpose = purpose ?? const SpecField(),
       name = name ?? const SpecField(),
       invocationPrompt = invocationPrompt ?? const SpecField(),
       parameters = parameters ?? [],
       behaviorResponse = behaviorResponse ?? const SpecField(),
       dataSources = dataSources ?? const SpecField(),
       outputs = outputs ?? const SpecField(),
       triggersBeyondVoice = triggersBeyondVoice ?? const SpecField(),
       sensorsPermissions = sensorsPermissions ?? const SpecField(),
       externalKeys = externalKeys ?? const SpecField(),
       exampleSuccess = exampleSuccess ?? const SpecField(),
       edgeCases = edgeCases ?? const SpecField(),
       externalIntegrations = externalIntegrations ?? [];

  SpecField fieldFor(AppSpecSlot slot) {
    switch (slot) {
      case AppSpecSlot.purpose:
        return purpose;
      case AppSpecSlot.name:
        return name;
      case AppSpecSlot.invocationPrompt:
        return invocationPrompt;
      case AppSpecSlot.behaviorResponse:
        return behaviorResponse;
      case AppSpecSlot.dataSources:
        return dataSources;
      case AppSpecSlot.outputs:
        return outputs;
      case AppSpecSlot.triggersBeyondVoice:
        return triggersBeyondVoice;
      case AppSpecSlot.sensorsPermissions:
        return sensorsPermissions;
      case AppSpecSlot.externalKeys:
        return externalKeys;
      case AppSpecSlot.exampleSuccess:
        return exampleSuccess;
      case AppSpecSlot.edgeCases:
        return edgeCases;
      case AppSpecSlot.parameters:
      case AppSpecSlot.externalIntegrations:
        throw ArgumentError('$slot is not a scalar field');
    }
  }

  void setField(AppSpecSlot slot, SpecField field) {
    switch (slot) {
      case AppSpecSlot.purpose:
        purpose = field;
      case AppSpecSlot.name:
        name = field;
      case AppSpecSlot.invocationPrompt:
        invocationPrompt = field;
      case AppSpecSlot.behaviorResponse:
        behaviorResponse = field;
      case AppSpecSlot.dataSources:
        dataSources = field;
      case AppSpecSlot.outputs:
        outputs = field;
      case AppSpecSlot.triggersBeyondVoice:
        triggersBeyondVoice = field;
      case AppSpecSlot.sensorsPermissions:
        sensorsPermissions = field;
      case AppSpecSlot.externalKeys:
        externalKeys = field;
      case AppSpecSlot.exampleSuccess:
        exampleSuccess = field;
      case AppSpecSlot.edgeCases:
        edgeCases = field;
      case AppSpecSlot.parameters:
      case AppSpecSlot.externalIntegrations:
        break;
    }
  }

  /// Slots that must be filled for a minimal agent.
  static const List<AppSpecSlot> coreSequence = [
    AppSpecSlot.purpose,
    AppSpecSlot.name,
    AppSpecSlot.invocationPrompt,
    AppSpecSlot.parameters,
    AppSpecSlot.behaviorResponse,
    AppSpecSlot.dataSources,
    AppSpecSlot.outputs,
    AppSpecSlot.triggersBeyondVoice,
    AppSpecSlot.sensorsPermissions,
    AppSpecSlot.externalKeys,
    AppSpecSlot.exampleSuccess,
    AppSpecSlot.edgeCases,
    AppSpecSlot.externalIntegrations,
  ];

  /// Whether a conditional slot is relevant given current spec content.
  bool isSlotRelevant(AppSpecSlot slot) {
    switch (slot) {
      case AppSpecSlot.purpose:
      case AppSpecSlot.name:
      case AppSpecSlot.invocationPrompt:
      case AppSpecSlot.behaviorResponse:
      case AppSpecSlot.dataSources:
      case AppSpecSlot.outputs:
      case AppSpecSlot.exampleSuccess:
        return true;
      case AppSpecSlot.parameters:
        return invocationPrompt.hasValue;
      case AppSpecSlot.triggersBeyondVoice:
        return _impliesBackground();
      case AppSpecSlot.sensorsPermissions:
        return _impliesSensors();
      case AppSpecSlot.externalKeys:
        return externalIntegrations.isNotEmpty;
      case AppSpecSlot.edgeCases:
        return _impliesEdgeCases();
      case AppSpecSlot.externalIntegrations:
        return _impliesExternalPost();
    }
  }

  bool _impliesBackground() {
    final blob = _textBlob();
    return blob.contains('schedule') ||
        blob.contains('periodic') ||
        blob.contains('continuous') ||
        blob.contains('background') ||
        blob.contains('every ') ||
        blob.contains('sensor') ||
        blob.contains('telemetry');
  }

  bool _impliesSensors() {
    final blob = _textBlob();
    return blob.contains('gps') ||
        blob.contains('location') ||
        blob.contains('accelerometer') ||
        blob.contains('compass') ||
        blob.contains('sensor') ||
        blob.contains('telemetry') ||
        blob.contains('mic');
  }

  bool _impliesEdgeCases() {
    final blob = _textBlob();
    return blob.contains('offline') ||
        blob.contains('error') ||
        blob.contains('empty') ||
        blob.contains('fail');
  }

  bool _impliesExternalPost() {
    final blob = _textBlob();
    const platforms = [
      'twitter',
      'tweet',
      ' x ',
      'facebook',
      'fb ',
      'instagram',
      'insta',
      'youtube',
      'threads',
      'post to',
      'social',
      'webhook',
    ];
    for (final p in platforms) {
      if (blob.contains(p)) return true;
    }
    return externalIntegrations.isNotEmpty;
  }

  String _textBlob() {
    return [
      purpose.value,
      name.value,
      invocationPrompt.value,
      behaviorResponse.value,
      dataSources.value,
      outputs.value,
    ].whereType<String>().join(' ').toLowerCase();
  }

  bool isSlotSatisfied(AppSpecSlot slot) {
    if (!isSlotRelevant(slot)) return true;
    switch (slot) {
      case AppSpecSlot.parameters:
        return invocationPrompt.status == SlotStatus.confirmed ||
            parameters.isNotEmpty;
      case AppSpecSlot.externalIntegrations:
        return externalIntegrations.isNotEmpty || !_impliesExternalPost();
      default:
        return fieldFor(slot).status == SlotStatus.confirmed &&
            fieldFor(slot).hasValue;
    }
  }

  /// First relevant slot that is not yet confirmed.
  AppSpecSlot? nextOpenSlot() {
    for (final slot in coreSequence) {
      if (!isSlotRelevant(slot)) continue;
      if (!isSlotSatisfied(slot)) return slot;
    }
    return null;
  }

  bool get allRelevantConfirmed {
    for (final slot in coreSequence) {
      if (!isSlotRelevant(slot)) continue;
      if (!isSlotSatisfied(slot)) return false;
    }
    return purpose.hasValue && name.hasValue && behaviorResponse.hasValue;
  }

  /// Safe registry key from display name.
  String normalizedRegistryName({String fallbackPrefix = 'Agent'}) {
    final raw = name.value?.trim() ?? '';
    if (raw.isEmpty) {
      return '$fallbackPrefix${DateTime.now().millisecondsSinceEpoch % 100000}';
    }
    final words = raw
        .split(RegExp(r'[^a-zA-Z0-9]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) {
      return '$fallbackPrefix${DateTime.now().millisecondsSinceEpoch % 100000}';
    }
    return words
        .map((w) => '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
        .join();
  }

  Map<String, dynamic> toInputSchema() {
    final schema = <String, dynamic>{};
    for (final p in parameters) {
      if (p.name.isNotEmpty) {
        schema[p.name] = p.toInputSchemaField();
      }
    }
    return schema;
  }

  /// Natural-language compiler request for authorAgent().
  String toAuthorRequest() {
    final parts = <String>[];
    if (purpose.hasValue) parts.add('Purpose: ${purpose.value}');
    if (name.hasValue) {
      parts.add(
        'Display name: ${name.value} (registry key: ${normalizedRegistryName()})',
      );
    }
    if (invocationPrompt.hasValue) {
      parts.add('User invocation phrase: ${invocationPrompt.value}');
    }
    if (parameters.isNotEmpty) {
      parts.add(
        'Parameters to extract from invocation: ${parameters.map((p) => '${p.name} (${p.type}): ${p.description}').join('; ')}',
      );
    }
    if (behaviorResponse.hasValue) {
      parts.add('Behavior and spoken response: ${behaviorResponse.value}');
    }
    if (dataSources.hasValue) parts.add('Data sources: ${dataSources.value}');
    if (outputs.hasValue) parts.add('Outputs: ${outputs.value}');
    if (triggersBeyondVoice.hasValue) {
      parts.add('Triggers: ${triggersBeyondVoice.value}');
    }
    if (sensorsPermissions.hasValue) {
      parts.add('Sensors/permissions: ${sensorsPermissions.value}');
    }
    if (externalIntegrations.isNotEmpty) {
      parts.add(
        'External integrations: ${externalIntegrations.map((e) => '${e.platform}: ${e.action}${e.constraints != null ? ' (${e.constraints})' : ''}').join('; ')}',
      );
    }
    if (exampleSuccess.hasValue) {
      parts.add('Success example: ${exampleSuccess.value}');
    }
    if (edgeCases.hasValue) parts.add('Edge cases: ${edgeCases.value}');
    return parts.join('. ');
  }

  String consolidationSummary() {
    final parts = <String>['Here is what we have so far.'];
    if (purpose.hasValue) parts.add('Purpose: ${purpose.value}.');
    if (name.hasValue) parts.add('Name: ${name.value}.');
    if (invocationPrompt.hasValue) {
      parts.add('You will say: ${invocationPrompt.value}.');
    }
    if (parameters.isNotEmpty) {
      parts.add('Parameters: ${parameters.map((p) => p.name).join(', ')}.');
    }
    if (behaviorResponse.hasValue) {
      parts.add('It will respond: ${behaviorResponse.value}.');
    }
    if (dataSources.hasValue) parts.add('Data: ${dataSources.value}.');
    if (outputs.hasValue) parts.add('Outputs: ${outputs.value}.');
    if (externalIntegrations.isNotEmpty) {
      parts.add(
        'External: ${externalIntegrations.map((e) => e.platform).join(', ')}.',
      );
    }
    return parts.join(' ');
  }

  /// Short spoken echo for only the slots just updated this turn.
  String echoForSlots(Iterable<AppSpecSlot> slots) {
    final lines = <String>[];
    for (final slot in slots) {
      switch (slot) {
        case AppSpecSlot.parameters:
          if (parameters.isNotEmpty) {
            lines.add(
              'Got parameters: ${parameters.map((p) => p.name).join(', ')}.',
            );
          }
        case AppSpecSlot.externalIntegrations:
          if (externalIntegrations.isNotEmpty) {
            lines.add(
              'Got integrations: ${externalIntegrations.map((e) => e.platform).join(', ')}.',
            );
          }
        default:
          final f = fieldFor(slot);
          if (f.hasValue) {
            lines.add('Got ${_slotLabel(slot)}: ${f.value}.');
          }
      }
    }
    return lines.join(' ');
  }

  static String _slotLabel(AppSpecSlot slot) {
    switch (slot) {
      case AppSpecSlot.purpose:
        return 'purpose';
      case AppSpecSlot.name:
        return 'name';
      case AppSpecSlot.invocationPrompt:
        return 'invocation phrase';
      case AppSpecSlot.parameters:
        return 'parameters';
      case AppSpecSlot.behaviorResponse:
        return 'behavior';
      case AppSpecSlot.dataSources:
        return 'data sources';
      case AppSpecSlot.outputs:
        return 'outputs';
      case AppSpecSlot.triggersBeyondVoice:
        return 'triggers';
      case AppSpecSlot.sensorsPermissions:
        return 'sensors';
      case AppSpecSlot.externalKeys:
        return 'external keys';
      case AppSpecSlot.exampleSuccess:
        return 'success example';
      case AppSpecSlot.edgeCases:
        return 'edge cases';
      case AppSpecSlot.externalIntegrations:
        return 'external integrations';
    }
  }

  /// Update a scalar slot value and mark it confirmed (UI edit path).
  void updateSlotValue(AppSpecSlot slot, String value) {
    final trimmed = value.trim();
    if (slot == AppSpecSlot.parameters ||
        slot == AppSpecSlot.externalIntegrations) {
      return;
    }
    setField(
      slot,
      SpecField(
        value: trimmed.isEmpty ? null : trimmed,
        status: trimmed.isEmpty ? SlotStatus.empty : SlotStatus.confirmed,
        confidence: SlotConfidence.stated,
      ),
    );
  }

  /// Relevant slots in sequence order (for numbered authoring panel).
  List<AppSpecSlot> relevantSlots() {
    return coreSequence.where(isSlotRelevant).toList();
  }

  /// Explicit slot-by-slot recap for authoring turns (Arch v3.7 UX).
  ///
  /// Lists every captured value with human-readable labels. Scalar slots tagged
  /// `(suggested)` when still [SlotStatus.proposed].
  String capturedSlotsRecap() {
    final lines = <String>[];

    void addScalar(String label, SpecField field) {
      if (!field.hasValue) return;
      final suffix = field.status == SlotStatus.proposed ? ' (suggested)' : '';
      lines.add('$label: ${field.value}$suffix.');
    }

    addScalar('Purpose', purpose);
    addScalar('Name', name);
    addScalar('Invocation phrase', invocationPrompt);
    if (parameters.isNotEmpty) {
      lines.add(
        'Parameters: ${parameters.map((p) => '${p.name} (${p.type})').join(', ')}.',
      );
    }
    addScalar('Behavior and response', behaviorResponse);
    addScalar('Data sources', dataSources);
    addScalar('Outputs', outputs);
    addScalar('Triggers beyond voice', triggersBeyondVoice);
    addScalar('Sensors and permissions', sensorsPermissions);
    addScalar('External API keys', externalKeys);
    addScalar('Success example', exampleSuccess);
    addScalar('Edge cases', edgeCases);
    if (externalIntegrations.isNotEmpty) {
      lines.add(
        'External integrations: ${externalIntegrations.map((e) => '${e.platform} (${e.action})').join(', ')}.',
      );
    }

    if (lines.isEmpty) return '';
    return 'Here is what I have so far. ${lines.join(' ')}';
  }

  Map<String, dynamic> toJson() => {
    'purpose': purpose.toJson(),
    'name': name.toJson(),
    'invocationPrompt': invocationPrompt.toJson(),
    'parameters': parameters.map((p) => p.toJson()).toList(),
    'behaviorResponse': behaviorResponse.toJson(),
    'dataSources': dataSources.toJson(),
    'outputs': outputs.toJson(),
    'triggersBeyondVoice': triggersBeyondVoice.toJson(),
    'sensorsPermissions': sensorsPermissions.toJson(),
    'externalKeys': externalKeys.toJson(),
    'exampleSuccess': exampleSuccess.toJson(),
    'edgeCases': edgeCases.toJson(),
    'externalIntegrations': externalIntegrations
        .map((e) => e.toJson())
        .toList(),
  };

  factory AppSpec.fromJson(Map<String, dynamic> json) {
    final params = <ParameterBinding>[];
    if (json['parameters'] is List) {
      for (final item in json['parameters'] as List) {
        if (item is Map) {
          params.add(
            ParameterBinding.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    final integrations = <ExternalIntegration>[];
    if (json['externalIntegrations'] is List) {
      for (final item in json['externalIntegrations'] as List) {
        if (item is Map) {
          integrations.add(
            ExternalIntegration.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    return AppSpec(
      purpose: SpecField.fromJson(
        json['purpose'] is Map
            ? Map<String, dynamic>.from(json['purpose'] as Map)
            : null,
      ),
      name: SpecField.fromJson(
        json['name'] is Map
            ? Map<String, dynamic>.from(json['name'] as Map)
            : null,
      ),
      invocationPrompt: SpecField.fromJson(
        json['invocationPrompt'] is Map
            ? Map<String, dynamic>.from(json['invocationPrompt'] as Map)
            : null,
      ),
      parameters: params,
      behaviorResponse: SpecField.fromJson(
        json['behaviorResponse'] is Map
            ? Map<String, dynamic>.from(json['behaviorResponse'] as Map)
            : null,
      ),
      dataSources: SpecField.fromJson(
        json['dataSources'] is Map
            ? Map<String, dynamic>.from(json['dataSources'] as Map)
            : null,
      ),
      outputs: SpecField.fromJson(
        json['outputs'] is Map
            ? Map<String, dynamic>.from(json['outputs'] as Map)
            : null,
      ),
      triggersBeyondVoice: SpecField.fromJson(
        json['triggersBeyondVoice'] is Map
            ? Map<String, dynamic>.from(json['triggersBeyondVoice'] as Map)
            : null,
      ),
      sensorsPermissions: SpecField.fromJson(
        json['sensorsPermissions'] is Map
            ? Map<String, dynamic>.from(json['sensorsPermissions'] as Map)
            : null,
      ),
      externalKeys: SpecField.fromJson(
        json['externalKeys'] is Map
            ? Map<String, dynamic>.from(json['externalKeys'] as Map)
            : null,
      ),
      exampleSuccess: SpecField.fromJson(
        json['exampleSuccess'] is Map
            ? Map<String, dynamic>.from(json['exampleSuccess'] as Map)
            : null,
      ),
      edgeCases: SpecField.fromJson(
        json['edgeCases'] is Map
            ? Map<String, dynamic>.from(json['edgeCases'] as Map)
            : null,
      ),
      externalIntegrations: integrations,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  /// Merge LLM-returned spec; preserve confirmed slots unless LLM explicitly replaces.
  void mergeFrom(AppSpec incoming, {bool allowOverwriteConfirmed = false}) {
    void mergeField(AppSpecSlot slot) {
      final inc = incoming.fieldFor(slot);
      final cur = fieldFor(slot);
      if (!inc.hasValue) return;
      if (cur.status == SlotStatus.confirmed && !allowOverwriteConfirmed) {
        return;
      }
      setField(slot, inc);
    }

    for (final slot in AppSpecSlot.values) {
      if (slot == AppSpecSlot.parameters ||
          slot == AppSpecSlot.externalIntegrations) {
        continue;
      }
      mergeField(slot);
    }
    if (incoming.parameters.isNotEmpty) {
      parameters = incoming.parameters;
    }
    if (incoming.externalIntegrations.isNotEmpty) {
      externalIntegrations = incoming.externalIntegrations;
    }
  }

  /// Promote proposed slots that were echoed last turn to confirmed (implicit consent).
  void confirmEchoedSlots(Iterable<AppSpecSlot> slots) {
    for (final slot in slots) {
      if (slot == AppSpecSlot.parameters) {
        if (parameters.isNotEmpty) continue;
      } else if (slot == AppSpecSlot.externalIntegrations) {
        if (externalIntegrations.isNotEmpty) continue;
      } else {
        final f = fieldFor(slot);
        if (f.status == SlotStatus.proposed && f.hasValue) {
          setField(slot, f.copyWith(status: SlotStatus.confirmed));
        }
      }
    }
  }

  /// Re-open a slot after user objection.
  void reopenSlot(AppSpecSlot slot) {
    if (slot == AppSpecSlot.parameters) {
      parameters = [];
      return;
    }
    if (slot == AppSpecSlot.externalIntegrations) {
      externalIntegrations = [];
      return;
    }
    final f = fieldFor(slot);
    if (f.hasValue) {
      setField(slot, f.copyWith(status: SlotStatus.proposed));
    }
  }
}

/// Back-compat alias for tests migrating from AuthorSlot.
typedef AuthorSlot = AppSpecSlot;

/// Back-compat thin wrapper — maps old 3-field API to AppSpec.
class AuthoringSpec {
  final AppSpec _inner;

  AuthoringSpec({String? purpose, String? triggers, String? name})
    : _inner = AppSpec(
        purpose: purpose != null
            ? SpecField(
                value: purpose,
                status: SlotStatus.confirmed,
                confidence: SlotConfidence.stated,
              )
            : const SpecField(),
        invocationPrompt: triggers != null
            ? SpecField(
                value: triggers,
                status: SlotStatus.confirmed,
                confidence: SlotConfidence.stated,
              )
            : const SpecField(),
        name: name != null
            ? SpecField(
                value: name,
                status: SlotStatus.confirmed,
                confidence: SlotConfidence.stated,
              )
            : const SpecField(),
      );

  AppSpec get asAppSpec => _inner;

  String? get purpose => _inner.purpose.value;
  String? get triggers => _inner.invocationPrompt.value;
  String? get name => _inner.name.value;

  bool get hasPurpose => _inner.purpose.hasValue;
  bool get hasTriggers => _inner.invocationPrompt.hasValue;
  bool get hasName => _inner.name.hasValue;
  bool get isComplete => hasPurpose && hasTriggers && hasName;

  AppSpecSlot? get nextMissingSlot => _inner.nextOpenSlot();

  AuthoringSpec copyWith({String? purpose, String? triggers, String? name}) {
    return AuthoringSpec(
      purpose: purpose ?? this.purpose,
      triggers: triggers ?? this.triggers,
      name: name ?? this.name,
    );
  }

  String normalizedRegistryName({String fallbackPrefix = 'Agent'}) =>
      _inner.normalizedRegistryName(fallbackPrefix: fallbackPrefix);

  String toAuthorRequest() => _inner.toAuthorRequest();

  String scopeSummary(String localeId) {
    final parts = <String>['Here is the full scope.'];
    if (hasPurpose) parts.add('It will: $purpose.');
    if (hasTriggers) parts.add('You will invoke it by: $triggers.');
    if (hasName) parts.add('We will call it: $name.');
    parts.add('Say yes to build, or tell me what to change.');
    return parts.join(' ');
  }
}
