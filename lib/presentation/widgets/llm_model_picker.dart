import 'package:flutter/material.dart';

import '../../core/services/llm/llm_model_catalog.dart';
import '../../core/services/llm/openrouter_model_service.dart';

/// Model dropdown + optional Custom text field for BYOK Settings.
class LlmModelPicker extends StatefulWidget {
  const LlmModelPicker({
    super.key,
    required this.providerId,
    required this.controller,
    this.dense = false,
  });

  final String providerId;
  final TextEditingController controller;
  final bool dense;

  @override
  State<LlmModelPicker> createState() => _LlmModelPickerState();
}

class _LlmModelPickerState extends State<LlmModelPicker> {
  late List<LlmModelOption> _options;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _options = LlmModelCatalog.usesLiveOpenRouterList(widget.providerId)
        ? const [LlmModelCatalog.customOption]
        : LlmModelCatalog.staticOptionsFor(widget.providerId);
    _applyDeprecatedMigration();
    widget.controller.addListener(_onControllerChanged);
    if (LlmModelCatalog.usesLiveOpenRouterList(widget.providerId)) {
      _reloadOptions();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LlmModelPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    if (oldWidget.providerId != widget.providerId) {
      _applyDeprecatedMigration();
      _reloadOptions();
    }
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _applyDeprecatedMigration() {
    final migrated = LlmModelCatalog.migrateDeprecated(
      widget.providerId,
      widget.controller.text.trim(),
    );
    if (migrated != null && migrated != widget.controller.text.trim()) {
      widget.controller.text = migrated;
    }
  }

  Future<void> _reloadOptions() async {
    final provider = widget.providerId;
    if (!LlmModelCatalog.usesLiveOpenRouterList(provider)) {
      if (!mounted) return;
      setState(() {
        _options = LlmModelCatalog.staticOptionsFor(provider);
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    final prefix = LlmModelCatalog.vendorPrefixFor(provider);
    final list = await OpenRouterModelService.instance.models(
      vendorPrefix: prefix,
    );
    if (!mounted) return;
    setState(() {
      _options = list;
      _loading = false;
    });
  }

  String get _selection {
    final current = widget.controller.text.trim();
    for (final o in _options) {
      if (o.id == current) return o.id;
    }
    return kLlmModelCustomId;
  }

  bool get _showCustom => _selection == kLlmModelCustomId;

  TextStyle get _fieldStyle => TextStyle(
    color: Colors.white,
    fontSize: widget.dense ? 12 : 13,
  );

  @override
  Widget build(BuildContext context) {
    final items = <DropdownMenuItem<String>>[
      for (final o in _options)
        DropdownMenuItem<String>(
          value: o.id,
          child: Text(
            o.label,
            overflow: TextOverflow.ellipsis,
            style: _fieldStyle,
          ),
        ),
    ];
    if (!items.any((i) => i.value == kLlmModelCustomId)) {
      items.add(
        DropdownMenuItem(
          value: kLlmModelCustomId,
          child: Text('Custom…', style: _fieldStyle),
        ),
      );
    }

    final value = items.any((i) => i.value == _selection)
        ? _selection
        : kLlmModelCustomId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          // Remount when selection changes so initialValue tracks the controller
          // (FormField.initialValue alone stays stuck on first mount).
          key: ValueKey('llm-model-${widget.providerId}-$value'),
          initialValue: value,
          isExpanded: true,
          dropdownColor: const Color(0xFF1E1E1E),
          style: _fieldStyle,
          decoration: InputDecoration(
            labelText: _loading ? 'Model (loading…)' : 'Model',
            labelStyle: TextStyle(
              color: Colors.white54,
              fontSize: widget.dense ? 11 : 12,
            ),
          ),
          items: items,
          onChanged: _loading
              ? null
              : (v) {
                  if (v == null) return;
                  if (v == kLlmModelCustomId) {
                    final cur = widget.controller.text.trim();
                    final wasPreset = _options.any(
                      (o) => o.id == cur && o.id != kLlmModelCustomId,
                    );
                    if (wasPreset || cur.isEmpty) {
                      widget.controller.text = '';
                    }
                  } else {
                    widget.controller.text = v;
                  }
                },
        ),
        if (_showCustom) ...[
          SizedBox(height: widget.dense ? 8 : 12),
          TextField(
            controller: widget.controller,
            style: _fieldStyle,
            decoration: InputDecoration(
              labelText: 'Custom model id',
              labelStyle: TextStyle(
                color: Colors.white54,
                fontSize: widget.dense ? 11 : 12,
              ),
              hintText: LlmModelCatalog.usesLiveOpenRouterList(widget.providerId)
                  ? 'e.g. google/gemini-3.5-flash'
                  : 'e.g. gemini-3.5-flash',
              hintStyle: const TextStyle(color: Colors.white24, fontSize: 11),
            ),
          ),
        ],
      ],
    );
  }
}
