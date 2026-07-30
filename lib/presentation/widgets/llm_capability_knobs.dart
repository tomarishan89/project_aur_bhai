import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services/llm/llm_capability_catalog.dart';
import '../../core/services/llm/llm_model_metadata_service.dart';

/// Thinking level + max output tokens for the active provider/model.
class LlmCapabilityKnobs extends StatefulWidget {
  const LlmCapabilityKnobs({
    super.key,
    required this.providerId,
    required this.modelId,
    required this.apiKey,
    required this.thinkingLevel,
    required this.maxOutputTokens,
    required this.onChanged,
    this.dense = false,
  });

  final String providerId;
  final String modelId;
  final String apiKey;
  final String? thinkingLevel;
  final int? maxOutputTokens;
  final void Function({String? thinkingLevel, int? maxOutputTokens}) onChanged;
  final bool dense;

  @override
  State<LlmCapabilityKnobs> createState() => _LlmCapabilityKnobsState();
}

class _LlmCapabilityKnobsState extends State<LlmCapabilityKnobs> {
  late TextEditingController _maxCtrl;
  int? _liveMax;
  bool _loadingLive = false;

  LlmModelCapabilities get _caps =>
      LlmCapabilityCatalog.forModel(widget.providerId, widget.modelId);

  @override
  void initState() {
    super.initState();
    _maxCtrl = TextEditingController(
      text: '${widget.maxOutputTokens ?? _caps.maxTokensDefault}',
    );
    _maybeLoadLive();
  }

  @override
  void didUpdateWidget(covariant LlmCapabilityKnobs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.providerId != widget.providerId ||
        oldWidget.modelId != widget.modelId) {
      _liveMax = null;
      final clamped = LlmCapabilityCatalog.clampMaxTokens(
        widget.providerId,
        widget.modelId,
        widget.maxOutputTokens ?? _caps.maxTokensDefault,
      );
      _maxCtrl.text = '$clamped';
      _maybeLoadLive();
    } else if (oldWidget.maxOutputTokens != widget.maxOutputTokens &&
        widget.maxOutputTokens != null) {
      final t = '${widget.maxOutputTokens}';
      if (_maxCtrl.text.trim() != t) _maxCtrl.text = t;
    }
  }

  @override
  void dispose() {
    _maxCtrl.dispose();
    super.dispose();
  }

  Future<void> _maybeLoadLive() async {
    if (LlmCapabilityCatalog.isKnownModel(widget.providerId, widget.modelId)) {
      return;
    }
    if (widget.apiKey.trim().isEmpty &&
        !widget.providerId.toLowerCase().contains('openrouter') &&
        widget.providerId != 'OpenRouter' &&
        widget.providerId != 'Perplexity' &&
        widget.providerId != 'Kimi' &&
        widget.providerId != 'DeepSeek') {
      // Gemini custom needs key; OpenRouter list is public.
    }
    setState(() => _loadingLive = true);
    final limit = await LlmModelMetadataService.instance.resolveOutputTokenLimit(
      providerId: widget.providerId,
      modelId: widget.modelId,
      apiKey: widget.apiKey,
    );
    if (!mounted) return;
    setState(() {
      _liveMax = limit;
      _loadingLive = false;
    });
    if (limit != null) {
      final clamped = LlmCapabilityCatalog.clampMaxTokens(
        widget.providerId,
        widget.modelId,
        int.tryParse(_maxCtrl.text.trim()) ?? _caps.maxTokensDefault,
        liveMax: limit,
      );
      if ('$clamped' != _maxCtrl.text.trim()) {
        _maxCtrl.text = '$clamped';
        widget.onChanged(maxOutputTokens: clamped);
      }
    }
  }

  TextStyle get _style => TextStyle(
    color: Colors.white,
    fontSize: widget.dense ? 12 : 13,
  );

  @override
  Widget build(BuildContext context) {
    final caps = _caps;
    final thinkingValue = LlmCapabilityCatalog.clampThinking(
      widget.providerId,
      widget.modelId,
      widget.thinkingLevel,
    );
    final maxCap = _liveMax != null && _liveMax! > 0
        ? (_liveMax! < caps.maxTokensMax ? _liveMax! : caps.maxTokensMax)
        : caps.maxTokensMax;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: widget.dense ? 8 : 12),
        if (caps.supportsThinking) ...[
          DropdownButtonFormField<String>(
            key: ValueKey('thinking-$thinkingValue-${widget.modelId}'),
            initialValue: thinkingValue,
            isExpanded: true,
            dropdownColor: const Color(0xFF1E1E1E),
            style: _style,
            decoration: InputDecoration(
              labelText: 'Thinking level',
              helperText:
                  'Default ${caps.defaultThinking}. Higher = slower, often smarter.',
              helperStyle: TextStyle(
                color: Colors.white38,
                fontSize: widget.dense ? 10 : 11,
              ),
              labelStyle: TextStyle(
                color: Colors.white54,
                fontSize: widget.dense ? 11 : 12,
              ),
            ),
            items: [
              for (final level in caps.thinkingLevels!)
                DropdownMenuItem(value: level, child: Text(level)),
            ],
            onChanged: (v) {
              if (v == null) return;
              widget.onChanged(thinkingLevel: v);
            },
          ),
        ] else ...[
          Text(
            'Thinking level: not used for this provider',
            style: TextStyle(
              color: Colors.white38,
              fontSize: widget.dense ? 10 : 11,
            ),
          ),
        ],
        SizedBox(height: widget.dense ? 8 : 12),
        TextField(
          controller: _maxCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: _style,
          decoration: InputDecoration(
            labelText: _loadingLive
                ? 'Max output tokens (checking model…)'
                : 'Max output tokens',
            helperText: 'Clamped 256–$maxCap'
                '${!caps.knownInCatalog ? ' · custom/unknown model' : ''}',
            helperStyle: TextStyle(
              color: Colors.white38,
              fontSize: widget.dense ? 10 : 11,
            ),
            labelStyle: TextStyle(
              color: Colors.white54,
              fontSize: widget.dense ? 11 : 12,
            ),
          ),
          onChanged: (raw) {
            final n = int.tryParse(raw.trim());
            if (n == null) return;
            final clamped = LlmCapabilityCatalog.clampMaxTokens(
              widget.providerId,
              widget.modelId,
              n,
              liveMax: _liveMax,
            );
            widget.onChanged(maxOutputTokens: clamped);
          },
          onSubmitted: (raw) {
            final n = int.tryParse(raw.trim()) ?? caps.maxTokensDefault;
            final clamped = LlmCapabilityCatalog.clampMaxTokens(
              widget.providerId,
              widget.modelId,
              n,
              liveMax: _liveMax,
            );
            _maxCtrl.text = '$clamped';
            widget.onChanged(maxOutputTokens: clamped);
          },
        ),
      ],
    );
  }
}
