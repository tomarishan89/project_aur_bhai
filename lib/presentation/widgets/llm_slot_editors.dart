import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/byok_service.dart';
import '../../core/services/llm/llm_capability_catalog.dart';
import '../../core/services/llm/llm_provider_factory.dart';
import '../../core/services/llm/llm_slot.dart';
import 'llm_capability_knobs.dart';
import 'llm_model_picker.dart';
import 'llm_provider_capability_notice.dart';

/// Per-function slot cards (MS-LLM-MULTI-SLOT-UX1).
class LlmSlotEditors extends ConsumerStatefulWidget {
  const LlmSlotEditors({super.key});

  @override
  ConsumerState<LlmSlotEditors> createState() => _LlmSlotEditorsState();
}

class _LlmSlotEditorsState extends ConsumerState<LlmSlotEditors> {
  static const _editable = [
    LlmSlot.language,
    LlmSlot.author,
    LlmSlot.improve,
    LlmSlot.capabilityJudge,
  ];

  final Map<LlmSlot, TextEditingController> _keys = {};
  final Map<LlmSlot, TextEditingController> _models = {};
  final Map<LlmSlot, TextEditingController> _urls = {};
  final Map<LlmSlot, String> _providers = {};
  final Map<LlmSlot, String?> _thinking = {};
  final Map<LlmSlot, int?> _maxTok = {};

  @override
  void initState() {
    super.initState();
    final byok = ref.read(byokServiceProvider);
    final def = byok.configForSlot(LlmSlot.defaultSlot);
    for (final slot in _editable) {
      final dedicated = byok.dedicatedSlotOrNull(slot);
      final seed =
          dedicated ??
          ByokSlotConfig(
            provider: def.provider,
            apiKey: '',
            modelName: def.modelName,
            customUrl: def.customUrl,
            thinkingLevel: def.thinkingLevel,
            maxOutputTokens: def.maxOutputTokens,
          );
      _keys[slot] = TextEditingController(text: seed.apiKey);
      _models[slot] = TextEditingController(text: seed.modelName);
      _urls[slot] = TextEditingController(text: seed.customUrl);
      _providers[slot] = seed.provider;
      _thinking[slot] = seed.thinkingLevel;
      _maxTok[slot] = seed.maxOutputTokens;
    }
  }

  @override
  void dispose() {
    for (final c in _keys.values) {
      c.dispose();
    }
    for (final c in _models.values) {
      c.dispose();
    }
    for (final c in _urls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _saveSlot(LlmSlot slot) async {
    await ref
        .read(byokServiceProvider)
        .updateSlot(
          slot,
          ByokSlotConfig(
            provider: _providers[slot] ?? 'Google Gemini',
            apiKey: _keys[slot]!.text.trim(),
            modelName: _models[slot]!.text.trim(),
            customUrl: _urls[slot]!.text.trim(),
            thinkingLevel: _thinking[slot],
            maxOutputTokens: _maxTok[slot],
          ),
        );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${slot.label} slot saved')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Empty slot → Default. Missing key → error names the slot.',
          style: TextStyle(color: Colors.white38, fontSize: 11),
        ),
        const SizedBox(height: 8),
        for (final slot in _editable) _card(slot),
      ],
    );
  }

  Widget _card(LlmSlot slot) {
    final provider = _providers[slot] ?? 'Google Gemini';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        collapsedIconColor: Colors.white38,
        iconColor: Colors.greenAccent,
        title: Text(
          slot.label,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        subtitle: Text(
          _keys[slot]!.text.trim().isEmpty
              ? 'Empty → uses Default'
              : '$provider · ${_models[slot]!.text}',
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
        children: [
          DropdownButtonFormField<String>(
            initialValue: provider,
            dropdownColor: const Color(0xFF1E1E1E),
            style: const TextStyle(color: Colors.white, fontSize: 12),
            decoration: const InputDecoration(
              labelText: 'Provider',
              labelStyle: TextStyle(color: Colors.white54, fontSize: 11),
            ),
            items: LlmProviderFactory.providerIds
                .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                .toList(),
            onChanged: (v) {
              if (v == null) return;
              setState(() {
                _providers[slot] = v;
                _models[slot]!.text = LlmProviderFactory.defaultModelFor(v);
                _thinking[slot] = LlmCapabilityCatalog.clampThinking(
                  v,
                  _models[slot]!.text.trim(),
                  null,
                );
                _maxTok[slot] = LlmCapabilityCatalog.forModel(
                  v,
                  _models[slot]!.text.trim(),
                ).maxTokensDefault;
              });
            },
          ),
          if (slot == LlmSlot.language || slot == LlmSlot.defaultSlot)
            LlmProviderCapabilityNotice(providerId: provider, dense: true),
          TextField(
            controller: _keys[slot],
            obscureText: true,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            decoration: InputDecoration(
              labelText: 'API Key (optional)',
              helperText: LlmProviderFactory.apiKeyHint(provider),
              helperStyle: const TextStyle(color: Colors.white38, fontSize: 10),
              labelStyle: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
          LlmModelPicker(
            providerId: provider,
            controller: _models[slot]!,
            dense: true,
          ),
          LlmCapabilityKnobs(
            dense: true,
            providerId: provider,
            modelId: _models[slot]!.text.trim(),
            apiKey: _keys[slot]!.text.trim(),
            thinkingLevel: _thinking[slot],
            maxOutputTokens: _maxTok[slot],
            onChanged: ({thinkingLevel, maxOutputTokens}) {
              setState(() {
                if (thinkingLevel != null) _thinking[slot] = thinkingLevel;
                if (maxOutputTokens != null) _maxTok[slot] = maxOutputTokens;
              });
            },
          ),
          if (LlmProviderFactory.requiresCustomUrl(provider))
            TextField(
              controller: _urls[slot],
              style: const TextStyle(color: Colors.white, fontSize: 12),
              decoration: const InputDecoration(
                labelText: 'Endpoint URL (OpenAI-compatible / Sarvam-class)',
                labelStyle: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _saveSlot(slot),
              child: const Text('SAVE SLOT'),
            ),
          ),
        ],
      ),
    );
  }
}
